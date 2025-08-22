//
//  Busyo_SingleFile_FollowFix_StableList.swift
//  CITY_CODE=25 / 제스처 종료 후 1회 호출 / Arrivals→BusLoc / 클러스터링
//  + 버스=파랑, 정류장=빨강 / API 카운터 / 내 위치 버튼
//  + [FIX] 선택해도 다른 버스 안 사라짐(가시성 제거 → 데이터 기준 제거)
//  + [FIX] 선택 상태에서도 좌표 갱신/애니메이션 반영(KVO)
//  + [ADD] 말풍선에 “다음 정류장 · ETA분”
//  + [ADD] Dead-reckoning 예측, EMA 스무딩, 정류장 스냅(히스테리시스), 점프 제거
//

import SwiftUI
import MapKit
import CoreLocation
import Foundation

// MARK: - App
@main
struct BusyoApp: App {
    var body: some Scene { WindowGroup { BusMapScreen() } }
}

fileprivate struct GeoUtil {
    static func metersPerDegLat(at lat: Double) -> Double { 111_320 }
    static func metersPerDegLon(at lat: Double) -> Double { 111_320 * cos(lat * .pi/180) }

    // 위경도 → 로컬 평면(m) 근사 변환
    static func deltaMeters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> (dx: Double, dy: Double, dist: Double) {
        let mLat = metersPerDegLat(at: (a.latitude + b.latitude)/2)
        let mLon = metersPerDegLon(at: (a.latitude + b.latitude)/2)
        let dy = (b.latitude  - a.latitude ) * mLat   // N(+)
        let dx = (b.longitude - a.longitude) * mLon   // E(+)
        return (dx, dy, hypot(dx, dy))
    }
}

// MARK: - Const & Utils
private let CITY_CODE = 25
private let MIN_RELOAD_DIST: CLLocationDistance = 250
private let MIN_ZOOM_RATIO: CGFloat = 0.10
private let REGION_COOLDOWN_SEC: Double = 6.0
private let BUS_REFRESH_SEC: UInt64 = 5
private let SHOW_DEBUG = false

fileprivate extension String {
    var encodedForServiceKey: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self }
}
fileprivate func maskKey(_ k: String) -> String { k.count > 12 ? "\(k.prefix(6))...\(k.suffix(6))" : "****" }

// MARK: - Models
struct BusStop: Identifiable, Hashable { let id: String, name: String, lat: Double, lon: Double, cityCode: Int }
struct BusLive: Identifiable, Hashable {
    let id: String
    let routeNo: String
    var lat: Double
    var lon: Double
    var etaMinutes: Int?
    var nextStopName: String?
}
struct ArrivalInfo: Identifiable, Hashable { let id = UUID(); let routeId: String; let routeNo: String; let etaMinutes: Int }
enum APIError: Error { case invalidURL, http(Int), decode(Error) }

// MARK: - Flex decoders
struct FlexString: Decodable {
    let value: String
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let x = try? c.decode(Double.self) { value = String(x) }
        else { throw DecodingError.typeMismatch(String.self, .init(codingPath: d.codingPath, debugDescription: "not string/int/double")) }
    }
}
struct FlexInt: Decodable {
    let value: Int?
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let s = try? c.decode(String.self) { value = Int(s) }
        else { value = nil }
    }
}
struct FlexDouble: Decodable {
    let value: Double
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let v = try? c.decode(Double.self) { value = v }
        else if let s = try? c.decode(String.self), let v = Double(s.replacingOccurrences(of: ",", with: "")) { value = v }
        else { throw DecodingError.typeMismatch(Double.self, .init(codingPath: d.codingPath, debugDescription: "not double/string")) }
    }
}

// MARK: - API Counter (thread-safe)
actor APICounter {
    static let shared = APICounter()
    private var total: Int = 0
    private var per: [String: Int] = [:]
    func bump(_ tag: String) {
        total += 1; per[tag, default: 0] += 1
        let parts = per.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "  ")
        print("🧮🟨 [API COUNT] total=\(total)  \(parts)")
    }
}

// MARK: - API
final class BusAPI: NSObject, URLSessionDelegate {
    private let serviceKeyRaw = "FVUZJTrP1WLAsFAKcXy8lh2Qy1DWNw5Ul2+vSY01E3cUJlO/9P+CodODXPIyzppQCPswXvc1WeblEAh6X41ClA=="

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = true
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    private func urlWithEncodedKey(base: String, items: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(string: base) else { throw APIError.invalidURL }
        comps.queryItems = items
        let tail = comps.percentEncodedQuery ?? ""
        comps.percentEncodedQuery = "serviceKey=\(serviceKeyRaw.encodedForServiceKey)" + (tail.isEmpty ? "" : "&\(tail)")
        guard let url = comps.url else { throw APIError.invalidURL }
        return url
    }

    private func send(_ name: String, url: URL) async throws -> (Data, HTTPURLResponse) {
        let safe = url.absoluteString.replacingOccurrences(of: serviceKeyRaw.encodedForServiceKey,
                                                           with: maskKey(serviceKeyRaw.encodedForServiceKey))
        print("➡️ [REQ \(name)] \(safe)")
        await APICounter.shared.bump(name)
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1) }
        print("⬅️ [RES \(name)] \(http.statusCode) \(data.count)b")
        return (data, http)
    }

    private func isLikelyXML(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return false }
        for ch in s { if ch == "<" { return true }; if ch.isWhitespace { continue }; break }
        return false
    }

    private final class XMLItemsParser: NSObject, XMLParserDelegate {
        var items: [[String:String]] = []; private var cur: [String:String]?; private var key: String?; private var buf = ""
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
            let k = name.lowercased(); if k == "item" { cur = [:] } else if cur != nil { key = k; buf = "" }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { buf += s }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            let k = name.lowercased()
            if k == "item" { if let c = cur { items.append(c) }; cur = nil }
            else if let kk = key, cur != nil {
                let v = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { cur?[kk] = v }
                key = nil; buf = ""
            }
        }
    }
    private func parseXMLItems(_ data: Data) throws -> [[String:String]] {
        let p = XMLItemsParser()
        let xp = XMLParser(data: data); xp.delegate = p
        guard xp.parse() else { throw APIError.decode(xp.parserError ?? NSError(domain: "XML", code: -1)) }
        return p.items
    }

    private func toDouble(_ s: String?) -> Double? { s.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) } }
    private func toInt(_ s: String?) -> Int? { s.flatMap { Int($0.replacingOccurrences(of: ",", with: "")) } }

    // 1) 근처 정류장
    func fetchStops(lat: Double, lon: Double) async throws -> [BusStop] {
        let url = try urlWithEncodedKey(
            base: "https://apis.data.go.kr/1613000/BusSttnInfoInqireService/getCrdntPrxmtSttnList",
            items: [
                .init(name: "pageNo", value: "1"),
                .init(name: "numOfRows", value: "200"),
                .init(name: "_type", value: "json"),
                .init(name: "type", value: "json"),
                .init(name: "gpsLati", value: "\(lat)"),
                .init(name: "gpsLong", value: "\(lon)")
            ])

        struct Root: Decodable {
            struct Resp: Decodable { let body: Body? }
            struct Body: Decodable { let items: Items? }
            struct Items: Decodable { let item: [Item]? }
            struct Item: Decodable {
                let nodeid: String
                let nodenm: String
                let citycode: Int
                let gpsLati: FlexDouble?
                let gpsLong: FlexDouble?
                enum CodingKeys: String, CodingKey { case nodeid, nodenm, citycode, gpsLati, gpsLong, gpslati, gpslong }
                init(from d: Decoder) throws {
                    let c = try d.container(keyedBy: CodingKeys.self)
                    nodeid = try c.decode(String.self, forKey: .nodeid)
                    nodenm = try c.decode(String.self, forKey: .nodenm)
                    citycode = try c.decode(Int.self, forKey: .citycode)
                    gpsLati = (try? c.decode(FlexDouble.self, forKey: .gpsLati))
                           ?? (try? c.decode(FlexDouble.self, forKey: .gpslati))
                    gpsLong = (try? c.decode(FlexDouble.self, forKey: .gpsLong))
                           ?? (try? c.decode(FlexDouble.self, forKey: .gpslong))
                }
            }
            let response: Resp?
        }

        let (data, _) = try await send("Stops", url: url)
        if isLikelyXML(data) {
            let arr = try parseXMLItems(data)
            return arr.compactMap { d in
                guard let id = d["nodeid"], let name = d["nodenm"],
                      let city = toInt(d["citycode"]),
                      let la = toDouble(d["gpslati"]) ?? toDouble(d["gpsLati"]),
                      let lo = toDouble(d["gpslong"]) ?? toDouble(d["gpsLong"]) else { return nil }
                return .init(id: id, name: name, lat: la, lon: lo, cityCode: city)
            }.filter { $0.cityCode == CITY_CODE }
        } else {
            let r = try JSONDecoder().decode(Root.self, from: data)
            return (r.response?.body?.items?.item ?? [])
                .filter { $0.citycode == CITY_CODE }
                .compactMap {
                    guard let la = $0.gpsLati?.value, let lo = $0.gpsLong?.value else { return nil }
                    return .init(id: $0.nodeid, name: $0.nodenm, lat: la, lon: lo, cityCode: $0.citycode)
                }
        }
    }

    // 2) 정류장 ETA
    func fetchArrivalsDetailed(cityCode: Int, nodeId: String) async throws -> [ArrivalInfo] {
        let url = try urlWithEncodedKey(
            base: "https://apis.data.go.kr/1613000/ArvlInfoInqireService/getSttnAcctoArvlPrearngeInfoList",
            items: [
                .init(name: "pageNo", value: "1"),
                .init(name: "numOfRows", value: "300"),
                .init(name: "_type", value: "json"),
                .init(name: "type", value: "json"),
                .init(name: "cityCode", value: String(cityCode)),
                .init(name: "nodeId", value: nodeId)
            ])

        struct Root: Decodable {
            struct Resp: Decodable { let body: Body? }
            struct Body: Decodable { let items: Items? }
            struct Items: Decodable { let item: [Item]? }
            struct Item: Decodable { let routeid: String?; let routeno: FlexString?; let arrtime: FlexInt? }
            let response: Resp?
        }

        let (data, _) = try await send("Arrivals", url: url)
        if isLikelyXML(data) {
            let arr = try parseXMLItems(data)
            return arr.compactMap { d in
                guard let rid = d["routeid"], let rno = d["routeno"], let sec = toInt(d["arrtime"]) else { return nil }
                return .init(routeId: rid, routeNo: rno, etaMinutes: max(0, sec/60))
            }
        } else {
            let r = try JSONDecoder().decode(Root.self, from: data)
            let items = r.response?.body?.items?.item ?? []
            return items.compactMap { i in
                guard let rid = i.routeid, let sec = i.arrtime?.value else { return nil }
                return .init(routeId: rid, routeNo: i.routeno?.value ?? "?", etaMinutes: max(0, sec/60))
            }
        }
    }

    // 3) 노선별 버스 위치
    func fetchBusLocations(cityCode: Int, routeId: String) async throws -> [BusLive] {
        let url = try urlWithEncodedKey(
            base: "https://apis.data.go.kr/1613000/BusLcInfoInqireService/getRouteAcctoBusLcList",
            items: [
                .init(name: "pageNo", value: "1"),
                .init(name: "numOfRows", value: "200"),
                .init(name: "_type", value: "json"),
                .init(name: "type", value: "json"),
                .init(name: "cityCode", value: String(cityCode)),
                .init(name: "routeId", value: routeId)
            ])

        struct Root: Decodable {
            struct Resp: Decodable { let body: Body? }
            struct Body: Decodable { let items: Items? }
            struct Items: Decodable { let item: [Item]? }
            struct Item: Decodable {
                let vehicleno: String
                let routenm: FlexString?
                let routeno: FlexString?
                let gpsLati: FlexDouble?
                let gpsLong: FlexDouble?
                let nodenm: FlexString?
                enum CodingKeys: String, CodingKey { case vehicleno, routenm, routeno, gpsLati, gpsLong, gpslati, gpslong, nodenm }
                init(from d: Decoder) throws {
                    let c = try d.container(keyedBy: CodingKeys.self)
                    vehicleno = try c.decode(String.self, forKey: .vehicleno)
                    routenm   = try? c.decode(FlexString.self, forKey: .routenm)
                    routeno   = try? c.decode(FlexString.self, forKey: .routeno)
                    gpsLati   = (try? c.decode(FlexDouble.self, forKey: .gpsLati))
                              ?? (try? c.decode(FlexDouble.self, forKey: .gpslati))
                    gpsLong   = (try? c.decode(FlexDouble.self, forKey: .gpsLong))
                              ?? (try? c.decode(FlexDouble.self, forKey: .gpslong))
                    nodenm    = try? c.decode(FlexString.self, forKey: .nodenm)
                }
            }
            let response: Resp?
        }

        let (data, _) = try await send("BusLoc", url: url)
        if isLikelyXML(data) {
            let arr = try parseXMLItems(data)
            return arr.compactMap { d in
                guard let veh = d["vehicleno"],
                      let r = d["routenm"] ?? d["routeno"],
                      let la = toDouble(d["gpslati"]) ?? toDouble(d["gpsLati"]),
                      let lo = toDouble(d["gpslong"]) ?? toDouble(d["gpsLong"]) else { return nil }
                return BusLive(id: veh, routeNo: r, lat: la, lon: lo, etaMinutes: nil, nextStopName: d["nodenm"])
            }
        } else {
            let r = try JSONDecoder().decode(Root.self, from: data)
            return (r.response?.body?.items?.item ?? []).compactMap {
                guard let la = $0.gpsLati?.value, let lo = $0.gpsLong?.value else { return nil }
                return BusLive(
                    id: $0.vehicleno,
                    routeNo: $0.routenm?.value ?? $0.routeno?.value ?? "?",
                    lat: la, lon: lo,
                    etaMinutes: nil,
                    nextStopName: $0.nodenm?.value
                )
            }
        }
    }
}

// MARK: - Annotations
final class BusStopAnnotation: NSObject, MKAnnotation {
    let stop: BusStop
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { stop.name }
    init(_ s: BusStop) { self.stop = s; self.coordinate = .init(latitude: s.lat, longitude: s.lon) }
}

final class BusAnnotation: NSObject, MKAnnotation {
    let id: String
    let routeNo: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { routeNo }
    var subtitle: String?

    init(bus: BusLive) {
        id = bus.id; routeNo = bus.routeNo
        coordinate = .init(latitude: bus.lat, longitude: bus.lon)
        subtitle = Self.makeSubtitle(eta: bus.etaMinutes, next: bus.nextStopName)
    }
    private static func makeSubtitle(eta: Int?, next: String?) -> String? {
        switch (eta, next) {
        case let (.some(e), .some(n)): return "다음 \(n) · 약 \(e)분"
        case let (.none, .some(n)):    return "다음 \(n)"
        case let (.some(e), .none):    return "약 \(e)분"
        default:                       return nil
        }
    }
    func update(to b: BusLive) {
        subtitle = Self.makeSubtitle(eta: b.etaMinutes, next: b.nextStopName)
        let newC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0) // 0.35 → 1.0: 자연스러움 향상
        self.coordinate = newC
        CATransaction.commit()
    }
}

final class BusMarkerView: MKMarkerAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        glyphImage = UIImage(systemName: "bus.fill")
        titleVisibility = .visible
        subtitleVisibility = .visible
        animatesWhenAdded = true
        markerTintColor = .systemBlue
        glyphTintColor = .white
        centerOffset = CGPoint(x: 0, y: -10) // 시각 기준점 보정(정류장 핀 위에 얹히는 느낌)
        collisionMode = .circle
        displayPriority = .defaultHigh
    }
    required init?(coder: NSCoder) { fatalError() }
    override func prepareForDisplay() {
        super.prepareForDisplay()
        if let b = annotation as? BusAnnotation { glyphText = b.routeNo }
    }
}

// 정류장=빨강 / 버스=파랑 클러스터
final class ClusterView: MKAnnotationView {
    private let countLabel = UILabel()
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        layer.cornerRadius = 17
        countLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        countLabel.textColor = .white
        countLabel.textAlignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: topAnchor),
            countLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func prepareForDisplay() {
        super.prepareForDisplay()
        if let cluster = annotation as? MKClusterAnnotation {
            countLabel.text = "\(cluster.memberAnnotations.count)"
            let isStopCluster = cluster.memberAnnotations.contains { $0 is BusStopAnnotation }
            backgroundColor = (isStopCluster ? UIColor.systemRed : UIColor.systemBlue).withAlphaComponent(0.9)
        }
    }
}

// MARK: - Tracking helpers
private struct BusTrack {
    var prevLoc: CLLocationCoordinate2D?
    var prevAt: Date?
    var lastLoc: CLLocationCoordinate2D
    var lastAt: Date
    // ⬇️ 추가
      var speedMps: Double = 0      // 최근 샘플로 추정된 속도
      var dirUnit: (x: Double, y: Double)? = nil  // 진행방향 단위 벡터 (E, N)
    
    // 샘플 없이도 감쇠된 속도로 앞으로 굴리기
       func coastPredict(at t: Date, decay: Double, minSpeed: Double) -> CLLocationCoordinate2D {
           guard let p = prevLoc, let pa = prevAt else { return lastLoc }
           let base = GeoUtil.deltaMeters(from: p, to: lastLoc)
           let baseDt = max(0.01, lastAt.timeIntervalSince(pa))
           let baseV  = base.dist / baseDt
           let dt = max(0, t.timeIntervalSince(lastAt))

           // 감쇠 속도
           let v = max(minSpeed, baseV * pow(decay, dt))
           if v < minSpeed { return lastLoc }

           let ux = base.dx / max(0.001, base.dist)
           let uy = base.dy / max(0.001, base.dist)
           let forward = v * dt

           let mLat = GeoUtil.metersPerDegLat(at: lastLoc.latitude)
           let mLon = GeoUtil.metersPerDegLon(at: lastLoc.latitude)
           let dLat = (forward * uy) / mLat
           let dLon = (forward * ux) / mLon
           return .init(latitude: lastLoc.latitude + dLat,
                        longitude: lastLoc.longitude + dLon)
       }
    
    mutating func updateKinematics() {
            guard let p = prevLoc, let _ = prevAt else { speedMps = 0; dirUnit = nil; return }
            let v = GeoUtil.deltaMeters(from: p, to: lastLoc)
            let dt = max(0.01, lastAt.timeIntervalSince(prevAt!))
            speedMps = v.dist / dt
            if v.dist > 0.5 {
                dirUnit = (x: v.dx / v.dist, y: v.dy / v.dist)
            } else {
                dirUnit = nil
            }
        }

        // Dead-reckoning
        func predicted(at t: Date) -> CLLocationCoordinate2D {
            guard let p = prevLoc, let pa = prevAt else { return lastLoc }
            let dt = max(0, lastAt.timeIntervalSince(pa))
            let nowDt = max(0, t.timeIntervalSince(lastAt))
            let step = GeoUtil.deltaMeters(from: p, to: lastLoc).dist
            if dt < 0.5 || step < 0.5 { return lastLoc }

            let mLat = GeoUtil.metersPerDegLat(at: lastLoc.latitude)
            let mLon = GeoUtil.metersPerDegLon(at: lastLoc.latitude)
            let speed = step / dt
            let fwd = speed * nowDt

            // 진행방향: 바로 이전 두 점으로
            let v = GeoUtil.deltaMeters(from: p, to: lastLoc)
            let ux = v.dx / max(0.001, v.dist)
            let uy = v.dy / max(0.001, v.dist)

            let dLat = (fwd * uy) / mLat
            let dLon = (fwd * ux) / mLon
            return .init(latitude: lastLoc.latitude + dLat,
                         longitude: lastLoc.longitude + dLon)
        }
    // Dead-reckoning: 단순 선형 예측
//    func predicted(at t: Date) -> CLLocationCoordinate2D {
//        guard let p = prevLoc, let pa = prevAt else { return lastLoc }
//        let dt = max(0, lastAt.timeIntervalSince(pa))
//        let nowDt = max(0, t.timeIntervalSince(lastAt))
//        let a = CLLocation(latitude: p.latitude, longitude: p.longitude)
//        let b = CLLocation(latitude: lastLoc.latitude, longitude: lastLoc.longitude)
//        let dist = b.distance(from: a)
//        if dt < 0.5 || dist < 0.5 { return lastLoc }
//
//        // 방향 벡터
//        let dLat = lastLoc.latitude - p.latitude
//        let dLon = lastLoc.longitude - p.longitude
//        let bearing = atan2(dLon, dLat)
//
//        let metersPerDegLat: Double = 111_320
//        let metersPerDegLon: Double = 111_320 * cos(lastLoc.latitude * .pi/180)
//        let speed = dist / dt                      // m/s
//        let forward = speed * nowDt
//
//        let ddLat = (forward * cos(bearing)) / metersPerDegLat
//        let ddLon = (forward * sin(bearing)) / metersPerDegLon
//        return .init(latitude: lastLoc.latitude + ddLat,
//                     longitude: lastLoc.longitude + ddLon)
//    }
}

// MARK: - ViewModel
@MainActor
final class MapVM: ObservableObject {
    @Published var stops: [BusStop] = []
    @Published var buses: [BusLive] = []
    @Published var followBusId: String?
    // 유령(ghost) 유지/감쇠 파라미터
    private let STALE_GRACE_SEC: TimeInterval = 45   // 샘플 끊겨도 최대 45초 유지
    private let COAST_MIN_SPEED: Double = 0.3        // m/s 아래면 거의 정지 취급
    private let COAST_DECAY_PER_SEC: Double = 0.92   // 초당 속도 감쇠(예: 0.92^dt)
    private var routeNoById: [String: String] = [:]  // 유령 합성 시 routeNo 복구용
    private var tickTask: Task<Void, Never>?         // 팔로우용 미세 갱신


    private let api = BusAPI()
    private var lastRegion: MKCoordinateRegion?
    private var lastReloadAt: Date = .distantPast
    private var regionTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var latestTopArrivals: [ArrivalInfo] = []
    private var isRefreshing = false

    // Tracking & smoothing params
    private var tracks: [String: BusTrack] = [:]                 // id -> track
    private let maxStepMeters: CLLocationDistance = 300          // 비정상 점프 제거
    private let emaAlpha: Double = 0.35                          // 저역통과(EMA) 가중치
    private let snapRadius: CLLocationDistance = 18              // 정류장 스냅 반경
    private let dwellSec: TimeInterval = 15                      // 스냅 유지 시간(히스테리시스)
    private var dwellUntil: [String: Date] = [:]                 // id -> 고정 유지 만료 시각

    deinit { autoTask?.cancel(); regionTask?.cancel() }

    // follow 중인데 새 결과에 그 id가 없으면, 유령 샘플을 합성해 넣어준다
    private func ensureFollowGhost(_ mergedById: inout [String: BusLive]) {
        guard let fid = followBusId, mergedById[fid] == nil, let tr = tracks[fid] else { return }
        let age = Date().timeIntervalSince(tr.lastAt)
        guard age < STALE_GRACE_SEC else {
            // 오래 끊겼으면 팔로우 해제(원하면 유지도 가능)
            followBusId = nil
            return
        }
        let pred = tr.coastPredict(at: Date().addingTimeInterval(0.6),
                                   decay: COAST_DECAY_PER_SEC,
                                   minSpeed: COAST_MIN_SPEED)
        var ghost = mergedById.values.first { $0.id == fid } // (보통 nil)
            ?? BusLive(id: fid,
                       routeNo: routeNoById[fid] ?? "?",
                       lat: pred.latitude, lon: pred.longitude,
                       etaMinutes: nil, nextStopName: nil)
        ghost.lat = pred.latitude
        ghost.lon = pred.longitude
        // 다음 정류장/ETA도 로컬 추정으로 업데이트
        if let trc = tracks[fid] {
            let (ns, eta) = nextStopAndETA(for: pred, track: trc, fallbackByName: ghost.nextStopName)
            if let s = ns { ghost.nextStopName = s.name }
            if let e = eta { ghost.etaMinutes = e }
        }
        mergedById[fid] = ghost
    }

    private func shouldReload(for region: MKCoordinateRegion) -> Bool {
        if let prev = lastRegion {
            let a = CLLocation(latitude: prev.center.latitude, longitude: prev.center.longitude)
            let b = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
            let dist = a.distance(from: b)
            let zoomDelta = abs(region.span.latitudeDelta - prev.span.latitudeDelta) / max(prev.span.latitudeDelta, 0.0001)
            if dist < MIN_RELOAD_DIST && zoomDelta < MIN_ZOOM_RATIO { return false }
        }
        if Date().timeIntervalSince(lastReloadAt) < REGION_COOLDOWN_SEC { return false }
        return true
    }
    // 진행방향 앞쪽 정류장 선택 + 로컬 ETA 계산
    private func nextStopAndETA(for coord: CLLocationCoordinate2D,
                                track: BusTrack,
                                fallbackByName: String?) -> (BusStop?, Int?) {

        // 1) 후보: 반경 300m 내
        let here = coord
        let nearby = stops
            .map { stop -> (BusStop, Double, Double, Double) in
                let v = GeoUtil.deltaMeters(from: here, to: .init(latitude: stop.lat, longitude: stop.lon))
                return (stop, v.dx, v.dy, v.dist)
            }
            .filter { $0.3 < 300 } // dist < 300m

        // 2) 진행방향 단위벡터
        let dir = track.dirUnit

        // 3) 진행방향 앞(+proj) & 측면 오프셋 작은 순으로 정렬
        let ranked: [(BusStop, Double, Double, Double)]
        if let d = dir {
            ranked = nearby
                .map { (s, dx, dy, dist) -> (BusStop, Double, Double, Double) in
                    let proj = dx*d.x + dy*d.y        // 진행방향 투영 거리(+ = 앞)
                    let lateral = abs(-dy*d.x + dx*d.y) // 측면 거리
                    return (s, proj, lateral, dist)
                }
                .sorted {
                    // 앞쪽 우선, 그 다음 측면 작은 순, 마지막으로 실제 거리
                    if ($0.1 >= 0) != ($1.1 >= 0) { return $0.1 >= 0 }
                    if abs($0.2 - $1.2) > 3 { return $0.2 < $1.2 }
                    return $0.3 < $1.3
                }
        } else {
            // 정지/방향 불명: 가장 가까운 순
            ranked = nearby.sorted { $0.3 < $1.3 }
        }

        // 4) 선택 로직
        var chosen: BusStop?
        var forwardMeters: Double?
        if let first = ranked.first {
            if dir != nil {
                // 진행방향 앞이면 그대로, 아니면 이름 fallback
                if first.1 >= -15 { // 약간 음수는 허용(스냅 직후)
                    chosen = first.0
                    forwardMeters = max(0, first.1)
                }
            }
        }
        if chosen == nil, let name = fallbackByName {
            chosen = stops.first { name.contains($0.name) || $0.name.contains(name) }
            if let c = chosen {
                let v = GeoUtil.deltaMeters(from: here, to: .init(latitude: c.lat, longitude: c.lon))
                forwardMeters = v.dist
            }
        }
        if chosen == nil, let near = nearby.sorted(by: { $0.3 < $1.3 }).first {
            chosen = near.0
            forwardMeters = near.3
        }
        guard let stop = chosen else { return (nil, nil) }

        // 5) ETA 추정: 속도 기반(느리면 0~1분 처리)
        let v = max(0.1, track.speedMps) // m/s
        let dist = max(0, forwardMeters ?? 0)
        var etaSec = Int(dist / v)
        if v < 1.2 && dist < 25 { etaSec = 0 } // 거의 도착
        let etaMin = max(0, Int( (Double(etaSec) / 60.0).rounded(.toNearestOrEven) ))
        return (stop, etaMin)
    }

    func onRegionCommitted(_ region: MKCoordinateRegion) {
        regionTask?.cancel()
        regionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self else { return }
            guard self.shouldReload(for: region) else { return }
            self.lastRegion = region
            self.lastReloadAt = Date()
            await self.reload(center: region.center)
        }
    }

    func reload(center: CLLocationCoordinate2D) async {
        do {
            let stops = try await api.fetchStops(lat: center.latitude, lon: center.longitude)
            self.stops = stops
            guard let focus = stops.first else { return }

            var arrivals = try await api.fetchArrivalsDetailed(cityCode: CITY_CODE, nodeId: focus.id)
            arrivals.sort { $0.etaMinutes < $1.etaMinutes }
            let top = Array(arrivals.prefix(5))
            self.latestTopArrivals = top

            let etaByRoute = Dictionary(uniqueKeysWithValues: top.map { ($0.routeNo, $0.etaMinutes) })

            // ✅ 스트리밍 반영 + 필터(예측/스냅/스무딩)
            var mergedById: [String: BusLive] = [:]
            try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in top {
                    group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) }
                }
                while let arr = try await group.next() {
                    let enriched = arr.map { b -> BusLive in
                        var m = b; m.etaMinutes = etaByRoute[m.routeNo]; return m
                    }
                    let filtered = self.mergeAndFilter(enriched)
                    // routeNo 캐시
                    for b in filtered { routeNoById[b.id] = b.routeNo; mergedById[b.id] = b }
                    // ⬇️ 마지막에 유령 보강
                    self.ensureFollowGhost(&mergedById)
                    self.buses = Array(mergedById.values)
                }
            }

            startAutoRefresh()
        } catch {
            print("❌ reload error: \(error)")
        }
    }

    private func startAutoRefresh() {
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BUS_REFRESH_SEC * 1_000_000_000)
                await self.refreshBusesOnly()
            }
        }
    }

    private func refreshBusesOnly() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let top = latestTopArrivals
        guard !top.isEmpty else { return }

        do {
            let etaByRoute = Dictionary(uniqueKeysWithValues: top.map { ($0.routeNo, $0.etaMinutes) })
            var mergedById: [String: BusLive] = Dictionary(uniqueKeysWithValues: self.buses.map { ($0.id, $0) })

            try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in top {
                    group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) }
                }
                while let arr = try await group.next() {
                    let enriched = arr.map { b -> BusLive in
                        var m = b; m.etaMinutes = etaByRoute[m.routeNo]; return m
                    }
                    let filtered = self.mergeAndFilter(enriched)
                    for b in filtered { routeNoById[b.id] = b.routeNo; mergedById[b.id] = b }
                    // ⬇️ 마지막에 유령 보강
                    self.ensureFollowGhost(&mergedById)
                    self.buses = Array(mergedById.values) // 부분 결과 즉시 반영
                }
            }
        } catch {
            // 일시 오류 무시
        }
    }

    // MARK: - Filtering & snapping
    private func mergeAndFilter(_ incoming: [BusLive]) -> [BusLive] {
        var out: [BusLive] = []
        for var b in incoming {
            let now = Date()
            let rawC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)

            if var tr = tracks[b.id] {
                // 점프 제거
                let step = CLLocation(latitude: tr.lastLoc.latitude, longitude: tr.lastLoc.longitude)
                    .distance(from: CLLocation(latitude: rawC.latitude, longitude: rawC.longitude))
                if step > maxStepMeters { continue }

                // EMA 스무딩
                let lat = tr.lastLoc.latitude  * (1 - emaAlpha) + rawC.latitude  * emaAlpha
                let lon = tr.lastLoc.longitude * (1 - emaAlpha) + rawC.longitude * emaAlpha
                let smooth = CLLocationCoordinate2D(latitude: lat, longitude: lon)

                tr.prevLoc = tr.lastLoc
                tr.prevAt  = tr.lastAt
                tr.lastLoc = smooth
                tr.lastAt  = now
                tr.updateKinematics()                 // ⬅️ 속도/방향 갱신
                tracks[b.id] = tr

                // 약간 앞좌표로 보정
                let pred = tr.predicted(at: now.addingTimeInterval(0.6))
                b.lat = pred.latitude
                b.lon = pred.longitude

                // ▶︎ 다음 정류장 & ETA 재판정 (이름 fallback은 API nodenm)
                let (nextStop, etaMin) = nextStopAndETA(for: pred, track: tr, fallbackByName: b.nextStopName)
                if let s = nextStop {
                    b.nextStopName = s.name
                }
                if let e = etaMin {
                    b.etaMinutes = e           // ⬅️ 항상 최신값으로 갱신
                }
            } else {
                // 첫 샘플
                tracks[b.id] = BusTrack(prevLoc: nil, prevAt: nil, lastLoc: rawC, lastAt: now)
            }

            // 스냅 & 히스테리시스 (이제 b.nextStopName은 위에서 갱신됨)
            maybeSnapToStop(&b)

            out.append(b)
        }
        return out
    }


    private func maybeSnapToStop(_ b: inout BusLive) {
        // 후보: 이름이 있으면 이름 우선, 없으면 가까운 정류장
        let here = CLLocation(latitude: b.lat, longitude: b.lon)

        func nearest(to name: String?) -> (BusStop, CLLocationDistance)? {
            if let n = name {
                let cands = stops.filter { $0.name.contains(n) || n.contains($0.name) }
                if let best = cands.min(by: {
                    here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon)) <
                    here.distance(from: CLLocation(latitude: $1.lat, longitude: $1.lon))
                }) {
                    let d = here.distance(from: CLLocation(latitude: best.lat, longitude: best.lon))
                    return (best, d)
                }
            }
            if let best = stops.min(by: {
                here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon)) <
                here.distance(from: CLLocation(latitude: $1.lat, longitude: $1.lon))
            }) {
                let d = here.distance(from: CLLocation(latitude: best.lat, longitude: best.lon))
                return (best, d)
            }
            return nil
        }

        guard let (stop, d) = nearest(to: b.nextStopName) else {
            if let until = dwellUntil[b.id], until < Date() { dwellUntil.removeValue(forKey: b.id) }
            return
        }

        // 스냅 반경 안이면 스냅 유지, 아니면 조건에 따라 해제
        if d < snapRadius {
            let until = dwellUntil[b.id] ?? .distantPast
            if until < Date() {
                b.lat = stop.lat; b.lon = stop.lon
                b.nextStopName = stop.name
                dwellUntil[b.id] = Date().addingTimeInterval(dwellSec)
            } else {
                b.lat = stop.lat; b.lon = stop.lon
                b.nextStopName = stop.name
            }
            // 도착이면 ETA=0 처리
            b.etaMinutes = 0
        } else {
            // 최근 샘플이 오래되었으면 스냅 유지 금지
                let recentOk: Bool = {
                    if let tr = tracks[b.id] { return Date().timeIntervalSince(tr.lastAt) < 2 * TimeInterval(BUS_REFRESH_SEC) }
                    return false
                }()
            if let until = dwellUntil[b.id], until < Date() {
                dwellUntil.removeValue(forKey: b.id)
            }
        }
    }

}

// MARK: - Map helpers
private extension MKMapView {
    var isRegionChangeFromUserInteraction: Bool {
        guard let grs = subviews.first?.gestureRecognizers else { return false }
        return grs.contains { $0.state == .began || $0.state == .ended || $0.state == .changed }
    }
}

// MARK: - Map View
struct ClusteredMapView: UIViewRepresentable {
    @ObservedObject var vm: MapVM
    @Binding var recenterRequest: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.region = .init(center: .init(latitude: 36.351, longitude: 127.385),
                           span: .init(latitudeDelta: 0.045, longitudeDelta: 0.045))
        map.pointOfInterestFilter = .includingAll
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "stop")
        map.register(BusMarkerView.self, forAnnotationViewWithReuseIdentifier: "bus")
        map.register(ClusterView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // 내 위치 버튼 처리(기존 그대로)
        if recenterRequest {
            defer { DispatchQueue.main.async { self.recenterRequest = false } }
            let status = CLLocationManager.authorizationStatus()
            guard status == .authorizedWhenInUse || status == .authorizedAlways else {
                print("📍 recenter skipped (auth=\(status))"); return
            }
            if let loc = uiView.userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(loc) {
                context.coordinator.centerOn(loc, mapView: uiView, animated: true)
            } else {
                print("📍 user location not ready – skip")
            }
        }

        // === 1) 현재 맵 상태 스냅샷 ===
        let currentStops = uiView.annotations.compactMap { $0 as? BusStopAnnotation }
        let currentBuses = uiView.annotations.compactMap { $0 as? BusAnnotation }
        let currentStopIds = Set(currentStops.map { $0.stop.id })
        let currentBusIds  = Set(currentBuses.map { $0.id })

        // === 2) 원하는 상태 계산 ===
        let desiredStops = vm.stops
        let desiredBuses = vm.buses

        let desiredStopIds = Set(desiredStops.map { $0.id })
        let desiredBusIds  = Set(desiredBuses.map { $0.id })

        // add/remove 계산
        let stopsToAdd   = desiredStops.filter { !currentStopIds.contains($0.id) }.map { BusStopAnnotation($0) }
        let stopsToRemove = currentStops.filter { !desiredStopIds.contains($0.stop.id) }

        var busAnnoById = Dictionary(uniqueKeysWithValues: currentBuses.map { ($0.id, $0) })
        var busesToAdd: [BusAnnotation] = []
        var busesToRemove: [BusAnnotation] = []
        var busUpdates: [(BusAnnotation, BusLive)] = []

        // 추가 또는 업데이트
        for b in desiredBuses {
            if let anno = busAnnoById.removeValue(forKey: b.id) {
                // 업데이트만 별도로 모아두기
                busUpdates.append((anno, b))
            } else {
                busesToAdd.append(BusAnnotation(bus: b))
            }
        }
        // 남은 것은 제거 대상(단, 팔로우 중이면 유지)
        for leftover in busAnnoById.values {
            if let sel = vm.followBusId, sel == leftover.id { continue }
            busesToRemove.append(leftover)
        }

        // === 3) 배치 적용(다음 런루프에서 remove→add→update) ===
        context.coordinator.applyAnnotationDiff(
            on: uiView,
            stopsToAdd: stopsToAdd,
            stopsToRemove: stopsToRemove,
            busesToAdd: busesToAdd,
            busesToRemove: busesToRemove,
            busUpdates: busUpdates
        )

        // === 4) 선택 버스 팔로우 (배치 후 살짝 지연 호출)
        if let followId = vm.followBusId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let anno = uiView.annotations.first(where: { ($0 as? BusAnnotation)?.id == followId }) as? BusAnnotation {
                    context.coordinator.follow(anno, on: uiView)
                }
            }
        }
    }


    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, MKMapViewDelegate {
        let parent: ClusteredMapView
        private let deb = Debouncer()
        private var isAutoRecentering = false
        private var isApplyingDiff = false   // ✅ 재진입 방지

        init(_ p: ClusteredMapView) { parent = p }
        // ✅ MKMapView annotation diff를 다음 런루프에서 일괄 적용
                func applyAnnotationDiff(
                    on mapView: MKMapView,
                    stopsToAdd: [MKAnnotation],
                    stopsToRemove: [MKAnnotation],
                    busesToAdd: [MKAnnotation],
                    busesToRemove: [MKAnnotation],
                    busUpdates: [(BusAnnotation, BusLive)]
                ) {
                    if isApplyingDiff { return }
                    isApplyingDiff = true
                    DispatchQueue.main.async { [weak self, weak mapView] in
                        guard let self, let mapView else { return }
                        CATransaction.begin()
                        CATransaction.setDisableActions(true) // add/remove는 애니메이션 없이
                        // 1) remove 먼저
                        let removes = stopsToRemove + busesToRemove
                        if !removes.isEmpty { mapView.removeAnnotations(removes) }
                        // 2) add
                        let adds = stopsToAdd + busesToAdd
                        if !adds.isEmpty { mapView.addAnnotations(adds) }
                        CATransaction.commit()

                        // 3) update(좌표 변경): 별도 트랜잭션으로 수행
                        if !busUpdates.isEmpty {
                            CATransaction.begin()
                            CATransaction.setAnimationDuration(1.0)
                            for (anno, live) in busUpdates {
                                anno.update(to: live)
                            }
                            CATransaction.commit()
                        }
                        self.isApplyingDiff = false
                    }
                }

        func centerOn(_ center: CLLocationCoordinate2D, mapView: MKMapView, animated: Bool) {
            isAutoRecentering = true
            mapView.setCenter(center, animated: animated)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.isAutoRecentering = false }
        }
        func follow(_ anno: BusAnnotation, on mapView: MKMapView) {
            guard CLLocationCoordinate2DIsValid(anno.coordinate) else { return }
            let center = mapView.centerCoordinate
            let a = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let b = CLLocation(latitude: anno.coordinate.latitude, longitude: anno.coordinate.longitude)
            if a.distance(from: b) > 30 {
                centerOn(anno.coordinate, mapView: mapView, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            deb.call(after: 0.5) {
                if self.isAutoRecentering { return }
                if mapView.isRegionChangeFromUserInteraction {
                    self.parent.vm.onRegionCommitted(mapView.region)
                } else if let followId = self.parent.vm.followBusId,
                          let anno = mapView.annotations.first(where: { ($0 as? BusAnnotation)?.id == followId }) as? BusAnnotation {
                    self.follow(anno, on: mapView)
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let s = annotation as? BusStopAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "stop", for: s) as! MKMarkerAnnotationView
                v.clusteringIdentifier = "stop"
                v.glyphText = "🚏"
                v.markerTintColor = .systemRed
                v.displayPriority = .defaultHigh
                v.titleVisibility = .adaptive
                return v
            } else if let b = annotation as? BusAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "bus", for: b) as! BusMarkerView
                v.clusteringIdentifier = "bus"
                return v
            } else if annotation is MKClusterAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: annotation)
            }
            return nil
        }

        // 선택 시 커지고 팔로우 시작
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let bus = view.annotation as? BusAnnotation {
                UIView.animate(withDuration: 0.2) {
                    view.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
                }
                parent.vm.followBusId = bus.id
                follow(bus, on: mapView)
            }
        }
        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if view is BusMarkerView {
                UIView.animate(withDuration: 0.2) { view.transform = .identity }
            }
            // 선택 해제 후에도 계속 따라가길 원치 않으면 아래 활성화
            // parent.vm.followBusId = nil
        }
    }
}

final class Debouncer {
    private var work: DispatchWorkItem?
    func call(after sec: Double, _ block: @escaping () -> Void) {
        work?.cancel(); let w = DispatchWorkItem(block: block); work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: w)
    }
}

// MARK: - Location
final class LocationAuth: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    override init() { super.init(); mgr.delegate = self }
    func requestWhenInUse() { mgr.requestWhenInUseAuthorization() }
}

// MARK: - Screen
struct BusMapScreen: View {
    @StateObject private var vm = MapVM()
    @StateObject private var loc = LocationAuth()
    @State private var recenterRequest = false

    var body: some View {
        ZStack {
            ClusteredMapView(vm: vm, recenterRequest: $recenterRequest)
                .ignoresSafeArea()
                .task {
                    loc.requestWhenInUse()
                    await vm.reload(center: .init(latitude: 36.351, longitude: 127.385))
                }

            if SHOW_DEBUG, let e = Optional<String>(nil) {
                VStack {
                    Text("⚠️ \(e)").font(.caption2)
                        .padding(6).background(.ultraThinMaterial).cornerRadius(8)
                    Spacer()
                }.padding().frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Button {
                loc.requestWhenInUse()
                recenterRequest = true
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 18, weight: .bold))
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .shadow(radius: 3)
            }
            .padding(.bottom, 24)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}


////
////  Busyo_SingleFile_FollowFix_StableList.swift
////  CITY_CODE=25 / 제스처 종료 후 1회 호출 / Arrivals→BusLoc / 클러스터링
////  + 버스=파랑, 정류장=빨강 / API 카운터 / 내 위치 버튼
////  + [FIX] 선택해도 다른 버스 안 사라짐(가시성 제거 → 데이터 기준 제거)
////  + [FIX] 선택 상태에서도 좌표 갱신/애니메이션 반영(KVO)
////  + [ADD] 말풍선에 “다음 정류장 · ETA분”
////
//
//import SwiftUI
//import MapKit
//import CoreLocation
//import Foundation
//
//// MARK: - App
//@main
//struct BusyoApp: App {
//    var body: some Scene { WindowGroup { BusMapScreen() } }
//}
//
//// MARK: - Const & Utils
//private let CITY_CODE = 25
//private let MIN_RELOAD_DIST: CLLocationDistance = 250
//private let MIN_ZOOM_RATIO: CGFloat = 0.10
//private let REGION_COOLDOWN_SEC: Double = 6.0
//private let BUS_REFRESH_SEC: UInt64 = 5
//private let SHOW_DEBUG = false
//
//fileprivate extension String {
//    var encodedForServiceKey: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self }
//}
//fileprivate func maskKey(_ k: String) -> String { k.count > 12 ? "\(k.prefix(6))...\(k.suffix(6))" : "****" }
//
//// MARK: - Models
//struct BusStop: Identifiable, Hashable { let id: String, name: String, lat: Double, lon: Double, cityCode: Int }
//struct BusLive: Identifiable, Hashable {
//    let id: String
//    let routeNo: String
//    var lat: Double
//    var lon: Double
//    var etaMinutes: Int?
//    var nextStopName: String?
//}
//struct ArrivalInfo: Identifiable, Hashable { let id = UUID(); let routeId: String; let routeNo: String; let etaMinutes: Int }
//enum APIError: Error { case invalidURL, http(Int), decode(Error) }
//
//// MARK: - Flex decoders
//struct FlexString: Decodable {
//    let value: String
//    init(from d: Decoder) throws {
//        let c = try d.singleValueContainer()
//        if let s = try? c.decode(String.self) { value = s }
//        else if let i = try? c.decode(Int.self) { value = String(i) }
//        else if let x = try? c.decode(Double.self) { value = String(x) }
//        else { throw DecodingError.typeMismatch(String.self, .init(codingPath: d.codingPath, debugDescription: "not string/int/double")) }
//    }
//}
//struct FlexInt: Decodable {
//    let value: Int?
//    init(from d: Decoder) throws {
//        let c = try d.singleValueContainer()
//        if let i = try? c.decode(Int.self) { value = i }
//        else if let s = try? c.decode(String.self) { value = Int(s) }
//        else { value = nil }
//    }
//}
//struct FlexDouble: Decodable {
//    let value: Double
//    init(from d: Decoder) throws {
//        let c = try d.singleValueContainer()
//        if let v = try? c.decode(Double.self) { value = v }
//        else if let s = try? c.decode(String.self), let v = Double(s.replacingOccurrences(of: ",", with: "")) { value = v }
//        else { throw DecodingError.typeMismatch(Double.self, .init(codingPath: d.codingPath, debugDescription: "not double/string")) }
//    }
//}
//
//// MARK: - API Counter (thread-safe)
//actor APICounter {
//    static let shared = APICounter()
//    private var total: Int = 0
//    private var per: [String: Int] = [:]
//    func bump(_ tag: String) {
//        total += 1; per[tag, default: 0] += 1
//        let parts = per.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "  ")
//        print("🧮🟨 [API COUNT] total=\(total)  \(parts)")
//    }
//}
//
//// MARK: - API
//final class BusAPI: NSObject, URLSessionDelegate {
//    private let serviceKeyRaw = "FVUZJTrP1WLAsFAKcXy8lh2Qy1DWNw5Ul2+vSY01E3cUJlO/9P+CodODXPIyzppQCPswXvc1WeblEAh6X41ClA=="
//
//    private lazy var session: URLSession = {
//        let c = URLSessionConfiguration.default
//        c.timeoutIntervalForRequest = 15
//        c.waitsForConnectivity = true
//        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
//    }()
//    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
//                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
//        completionHandler(.performDefaultHandling, nil)
//    }
//
//    private func urlWithEncodedKey(base: String, items: [URLQueryItem]) throws -> URL {
//        guard var comps = URLComponents(string: base) else { throw APIError.invalidURL }
//        comps.queryItems = items
//        let tail = comps.percentEncodedQuery ?? ""
//        comps.percentEncodedQuery = "serviceKey=\(serviceKeyRaw.encodedForServiceKey)" + (tail.isEmpty ? "" : "&\(tail)")
//        guard let url = comps.url else { throw APIError.invalidURL }
//        return url
//    }
//
//    private func send(_ name: String, url: URL) async throws -> (Data, HTTPURLResponse) {
//        let safe = url.absoluteString.replacingOccurrences(of: serviceKeyRaw.encodedForServiceKey,
//                                                           with: maskKey(serviceKeyRaw.encodedForServiceKey))
//        print("➡️ [REQ \(name)] \(safe)")
//        await APICounter.shared.bump(name)
//        let (data, resp) = try await session.data(from: url)
//        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1) }
//        print("⬅️ [RES \(name)] \(http.statusCode) \(data.count)b")
//        return (data, http)
//    }
//
//    private func isLikelyXML(_ data: Data) -> Bool {
//        guard let s = String(data: data, encoding: .utf8) else { return false }
//        for ch in s { if ch == "<" { return true }; if ch.isWhitespace { continue }; break }
//        return false
//    }
//
//    private final class XMLItemsParser: NSObject, XMLParserDelegate {
//        var items: [[String:String]] = []; private var cur: [String:String]?; private var key: String?; private var buf = ""
//        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
//            let k = name.lowercased(); if k == "item" { cur = [:] } else if cur != nil { key = k; buf = "" }
//        }
//        func parser(_ p: XMLParser, foundCharacters s: String) { buf += s }
//        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
//            let k = name.lowercased()
//            if k == "item" { if let c = cur { items.append(c) }; cur = nil }
//            else if let kk = key, cur != nil {
//                let v = buf.trimmingCharacters(in: .whitespacesAndNewlines)
//                if !v.isEmpty { cur?[kk] = v }
//                key = nil; buf = ""
//            }
//        }
//    }
//    private func parseXMLItems(_ data: Data) throws -> [[String:String]] {
//        let p = XMLItemsParser()
//        let xp = XMLParser(data: data); xp.delegate = p
//        guard xp.parse() else { throw APIError.decode(xp.parserError ?? NSError(domain: "XML", code: -1)) }
//        return p.items
//    }
//
//    private func toDouble(_ s: String?) -> Double? { s.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) } }
//    private func toInt(_ s: String?) -> Int? { s.flatMap { Int($0.replacingOccurrences(of: ",", with: "")) } }
//
//    // 1) 근처 정류장
//    func fetchStops(lat: Double, lon: Double) async throws -> [BusStop] {
//        let url = try urlWithEncodedKey(
//            base: "https://apis.data.go.kr/1613000/BusSttnInfoInqireService/getCrdntPrxmtSttnList",
//            items: [
//                .init(name: "pageNo", value: "1"),
//                .init(name: "numOfRows", value: "200"),
//                .init(name: "_type", value: "json"),
//                .init(name: "type", value: "json"),
//                .init(name: "gpsLati", value: "\(lat)"),
//                .init(name: "gpsLong", value: "\(lon)")
//            ])
//
//        struct Root: Decodable {
//            struct Resp: Decodable { let body: Body? }
//            struct Body: Decodable { let items: Items? }
//            struct Items: Decodable { let item: [Item]? }
//            struct Item: Decodable {
//                let nodeid: String
//                let nodenm: String
//                let citycode: Int
//                let gpsLati: FlexDouble?
//                let gpsLong: FlexDouble?
//                enum CodingKeys: String, CodingKey { case nodeid, nodenm, citycode, gpsLati, gpsLong, gpslati, gpslong }
//                init(from d: Decoder) throws {
//                    let c = try d.container(keyedBy: CodingKeys.self)
//                    nodeid = try c.decode(String.self, forKey: .nodeid)
//                    nodenm = try c.decode(String.self, forKey: .nodenm)
//                    citycode = try c.decode(Int.self, forKey: .citycode)
//                    gpsLati = (try? c.decode(FlexDouble.self, forKey: .gpsLati))
//                           ?? (try? c.decode(FlexDouble.self, forKey: .gpslati))
//                    gpsLong = (try? c.decode(FlexDouble.self, forKey: .gpsLong))
//                           ?? (try? c.decode(FlexDouble.self, forKey: .gpslong))
//                }
//            }
//            let response: Resp?
//        }
//
//        let (data, _) = try await send("Stops", url: url)
//        if isLikelyXML(data) {
//            let arr = try parseXMLItems(data)
//            return arr.compactMap { d in
//                guard let id = d["nodeid"], let name = d["nodenm"],
//                      let city = toInt(d["citycode"]),
//                      let la = toDouble(d["gpslati"]) ?? toDouble(d["gpsLati"]),
//                      let lo = toDouble(d["gpslong"]) ?? toDouble(d["gpsLong"]) else { return nil }
//                return .init(id: id, name: name, lat: la, lon: lo, cityCode: city)
//            }.filter { $0.cityCode == CITY_CODE }
//        } else {
//            let r = try JSONDecoder().decode(Root.self, from: data)
//            return (r.response?.body?.items?.item ?? [])
//                .filter { $0.citycode == CITY_CODE }
//                .compactMap {
//                    guard let la = $0.gpsLati?.value, let lo = $0.gpsLong?.value else { return nil }
//                    return .init(id: $0.nodeid, name: $0.nodenm, lat: la, lon: lo, cityCode: $0.citycode)
//                }
//        }
//    }
//
//    // 2) 정류장 ETA
//    func fetchArrivalsDetailed(cityCode: Int, nodeId: String) async throws -> [ArrivalInfo] {
//        let url = try urlWithEncodedKey(
//            base: "https://apis.data.go.kr/1613000/ArvlInfoInqireService/getSttnAcctoArvlPrearngeInfoList",
//            items: [
//                .init(name: "pageNo", value: "1"),
//                .init(name: "numOfRows", value: "300"),
//                .init(name: "_type", value: "json"),
//                .init(name: "type", value: "json"),
//                .init(name: "cityCode", value: String(cityCode)),
//                .init(name: "nodeId", value: nodeId)
//            ])
//
//        struct Root: Decodable {
//            struct Resp: Decodable { let body: Body? }
//            struct Body: Decodable { let items: Items? }
//            struct Items: Decodable { let item: [Item]? }
//            struct Item: Decodable { let routeid: String?; let routeno: FlexString?; let arrtime: FlexInt? }
//            let response: Resp?
//        }
//
//        let (data, _) = try await send("Arrivals", url: url)
//        if isLikelyXML(data) {
//            let arr = try parseXMLItems(data)
//            return arr.compactMap { d in
//                guard let rid = d["routeid"], let rno = d["routeno"], let sec = toInt(d["arrtime"]) else { return nil }
//                return .init(routeId: rid, routeNo: rno, etaMinutes: max(0, sec/60))
//            }
//        } else {
//            let r = try JSONDecoder().decode(Root.self, from: data)
//            let items = r.response?.body?.items?.item ?? []
//            return items.compactMap { i in
//                guard let rid = i.routeid, let sec = i.arrtime?.value else { return nil }
//                return .init(routeId: rid, routeNo: i.routeno?.value ?? "?", etaMinutes: max(0, sec/60))
//            }
//        }
//    }
//
//    // 3) 노선별 버스 위치
//    func fetchBusLocations(cityCode: Int, routeId: String) async throws -> [BusLive] {
//        let url = try urlWithEncodedKey(
//            base: "https://apis.data.go.kr/1613000/BusLcInfoInqireService/getRouteAcctoBusLcList",
//            items: [
//                .init(name: "pageNo", value: "1"),
//                .init(name: "numOfRows", value: "200"),
//                .init(name: "_type", value: "json"),
//                .init(name: "type", value: "json"),
//                .init(name: "cityCode", value: String(cityCode)),
//                .init(name: "routeId", value: routeId)
//            ])
//
//        struct Root: Decodable {
//            struct Resp: Decodable { let body: Body? }
//            struct Body: Decodable { let items: Items? }
//            struct Items: Decodable { let item: [Item]? }
//            struct Item: Decodable {
//                let vehicleno: String
//                let routenm: FlexString?
//                let routeno: FlexString?
//                let gpsLati: FlexDouble?
//                let gpsLong: FlexDouble?
//                let nodenm: FlexString?
//                enum CodingKeys: String, CodingKey { case vehicleno, routenm, routeno, gpsLati, gpsLong, gpslati, gpslong, nodenm }
//                init(from d: Decoder) throws {
//                    let c = try d.container(keyedBy: CodingKeys.self)
//                    vehicleno = try c.decode(String.self, forKey: .vehicleno)
//                    routenm   = try? c.decode(FlexString.self, forKey: .routenm)
//                    routeno   = try? c.decode(FlexString.self, forKey: .routeno)
//                    gpsLati   = (try? c.decode(FlexDouble.self, forKey: .gpsLati))
//                              ?? (try? c.decode(FlexDouble.self, forKey: .gpslati))
//                    gpsLong   = (try? c.decode(FlexDouble.self, forKey: .gpsLong))
//                              ?? (try? c.decode(FlexDouble.self, forKey: .gpslong))
//                    nodenm    = try? c.decode(FlexString.self, forKey: .nodenm)
//                }
//            }
//            let response: Resp?
//        }
//
//        let (data, _) = try await send("BusLoc", url: url)
//        if isLikelyXML(data) {
//            let arr = try parseXMLItems(data)
//            return arr.compactMap { d in
//                guard let veh = d["vehicleno"],
//                      let r = d["routenm"] ?? d["routeno"],
//                      let la = toDouble(d["gpslati"]) ?? toDouble(d["gpsLati"]),
//                      let lo = toDouble(d["gpslong"]) ?? toDouble(d["gpsLong"]) else { return nil }
//                return BusLive(id: veh, routeNo: r, lat: la, lon: lo, etaMinutes: nil, nextStopName: d["nodenm"])
//            }
//        } else {
//            let r = try JSONDecoder().decode(Root.self, from: data)
//            return (r.response?.body?.items?.item ?? []).compactMap {
//                guard let la = $0.gpsLati?.value, let lo = $0.gpsLong?.value else { return nil }
//                return BusLive(
//                    id: $0.vehicleno,
//                    routeNo: $0.routenm?.value ?? $0.routeno?.value ?? "?",
//                    lat: la, lon: lo,
//                    etaMinutes: nil,
//                    nextStopName: $0.nodenm?.value
//                )
//            }
//        }
//    }
//}
//
//// MARK: - Annotations
//final class BusStopAnnotation: NSObject, MKAnnotation {
//    let stop: BusStop
//    @objc dynamic var coordinate: CLLocationCoordinate2D
//    var title: String? { stop.name }
//    init(_ s: BusStop) { self.stop = s; self.coordinate = .init(latitude: s.lat, longitude: s.lon) }
//}
//
//final class BusAnnotation: NSObject, MKAnnotation {
//    let id: String
//    let routeNo: String
//    @objc dynamic var coordinate: CLLocationCoordinate2D
//    var title: String? { routeNo }
//    var subtitle: String?
//
//    init(bus: BusLive) {
//        id = bus.id; routeNo = bus.routeNo
//        coordinate = .init(latitude: bus.lat, longitude: bus.lon)
//        subtitle = Self.makeSubtitle(eta: bus.etaMinutes, next: bus.nextStopName)
//    }
//    private static func makeSubtitle(eta: Int?, next: String?) -> String? {
//        switch (eta, next) {
//        case let (.some(e), .some(n)): return "다음 \(n) · 약 \(e)분"
//        case let (.none, .some(n)):    return "다음 \(n)"
//        case let (.some(e), .none):    return "약 \(e)분"
//        default:                       return nil
//        }
//    }
//    // ✅ 수동 KVO 제거, CATransaction으로만 애니메이션
//        func update(to b: BusLive) {
//            subtitle = Self.makeSubtitle(eta: b.etaMinutes, next: b.nextStopName)
//            let newC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
//
//            CATransaction.begin()
//            CATransaction.setAnimationDuration(0.35)
//            self.coordinate = newC
//            CATransaction.commit()
//        }
//}
//
//final class BusMarkerView: MKMarkerAnnotationView {
//    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
//        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
//        glyphImage = UIImage(systemName: "bus.fill")
//        titleVisibility = .visible
//        subtitleVisibility = .visible
//        animatesWhenAdded = true
//        markerTintColor = .systemBlue
//        glyphTintColor = .white
//    }
//    required init?(coder: NSCoder) { fatalError() }
//    override func prepareForDisplay() {
//        super.prepareForDisplay()
//        if let b = annotation as? BusAnnotation { glyphText = b.routeNo }
//    }
//}
//
//// 정류장=빨강 / 버스=파랑 클러스터
//final class ClusterView: MKAnnotationView {
//    private let countLabel = UILabel()
//    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
//        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
//        frame = CGRect(x: 0, y: 0, width: 34, height: 34)
//        layer.cornerRadius = 17
//        countLabel.font = .systemFont(ofSize: 14, weight: .semibold)
//        countLabel.textColor = .white
//        countLabel.textAlignment = .center
//        countLabel.translatesAutoresizingMaskIntoConstraints = false
//        addSubview(countLabel)
//        NSLayoutConstraint.activate([
//            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
//            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
//            countLabel.topAnchor.constraint(equalTo: topAnchor),
//            countLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
//        ])
//    }
//    required init?(coder: NSCoder) { fatalError() }
//    override func prepareForDisplay() {
//        super.prepareForDisplay()
//        if let cluster = annotation as? MKClusterAnnotation {
//            countLabel.text = "\(cluster.memberAnnotations.count)"
//            let isStopCluster = cluster.memberAnnotations.contains { $0 is BusStopAnnotation }
//            backgroundColor = (isStopCluster ? UIColor.systemRed : UIColor.systemBlue).withAlphaComponent(0.9)
//        }
//    }
//}
//
//// MARK: - ViewModel
//@MainActor
//final class MapVM: ObservableObject {
//    @Published var stops: [BusStop] = []
//    @Published var buses: [BusLive] = []
//    @Published var followBusId: String?
//
//    private let api = BusAPI()
//    private var lastRegion: MKCoordinateRegion?
//    private var lastReloadAt: Date = .distantPast
//    private var regionTask: Task<Void, Never>?
//    private var autoTask: Task<Void, Never>?
//    private var latestTopArrivals: [ArrivalInfo] = []
//    private var isRefreshing = false
//
//    deinit { autoTask?.cancel(); regionTask?.cancel() }
//
//    private func shouldReload(for region: MKCoordinateRegion) -> Bool {
//        if let prev = lastRegion {
//            let a = CLLocation(latitude: prev.center.latitude, longitude: prev.center.longitude)
//            let b = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
//            let dist = a.distance(from: b)
//            let zoomDelta = abs(region.span.latitudeDelta - prev.span.latitudeDelta) / max(prev.span.latitudeDelta, 0.0001)
//            if dist < MIN_RELOAD_DIST && zoomDelta < MIN_ZOOM_RATIO { return false }
//        }
//        if Date().timeIntervalSince(lastReloadAt) < REGION_COOLDOWN_SEC { return false }
//        return true
//    }
//
//    func onRegionCommitted(_ region: MKCoordinateRegion) {
//        regionTask?.cancel()
//        regionTask = Task { [weak self] in
//            try? await Task.sleep(nanoseconds: 500_000_000)
//            guard let self else { return }
//            guard self.shouldReload(for: region) else { return }
//            self.lastRegion = region
//            self.lastReloadAt = Date()
//            await self.reload(center: region.center)
//        }
//    }
//
//    func reload(center: CLLocationCoordinate2D) async {
//        do {
//            let stops = try await api.fetchStops(lat: center.latitude, lon: center.longitude)
//            self.stops = stops
//            guard let focus = stops.first else { return }
//
//            var arrivals = try await api.fetchArrivalsDetailed(cityCode: CITY_CODE, nodeId: focus.id)
//            arrivals.sort { $0.etaMinutes < $1.etaMinutes }
//            let top = Array(arrivals.prefix(5))
//            self.latestTopArrivals = top
//
//            let etaByRoute = Dictionary(uniqueKeysWithValues: top.map { ($0.routeNo, $0.etaMinutes) })
//
//            // ✅ 여기부터: 완료된 노선부터 순차 반영(스트리밍)
//            var mergedById: [String: BusLive] = [:]
//            try await withThrowingTaskGroup(of: [BusLive].self) { group in
//                for a in top {
//                    group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) }
//                }
//                while let arr = try await group.next() {
//                    // ETA 붙이기
//                    let enriched = arr.map { b -> BusLive in
//                        var m = b
//                        m.etaMinutes = etaByRoute[m.routeNo]
//                        return m
//                    }
//                    // 머지 & 즉시 퍼블리시
//                    for b in enriched { mergedById[b.id] = b }
//                    self.buses = Array(mergedById.values)
//                }
//            }
//
////            self.lastError = nil
//            startAutoRefresh()
//        } catch {
//            print("❌ reload error: \(error)")
////            self.lastError = SHOW_DEBUG ? (error as NSError).localizedDescription : nil
//        }
//    }
//
////    func reload(center: CLLocationCoordinate2D) async {
////        do {
////            let stops = try await api.fetchStops(lat: center.latitude, lon: center.longitude)
////            self.stops = stops
////            guard let focus = stops.first else { return }
////
////            var arrivals = try await api.fetchArrivalsDetailed(cityCode: CITY_CODE, nodeId: focus.id)
////            arrivals.sort { $0.etaMinutes < $1.etaMinutes }
////            latestTopArrivals = Array(arrivals.prefix(5))
////
////            let busArrays: [[BusLive]] = try await withThrowingTaskGroup(of: [BusLive].self) { group in
////                for a in latestTopArrivals { group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) } }
////                var acc: [[BusLive]] = []; while let arr = try await group.next() { acc.append(arr) }; return acc
////            }
////            var merged = busArrays.flatMap { $0 }
////            let etaByRoute = Dictionary(uniqueKeysWithValues: latestTopArrivals.map { ($0.routeNo, $0.etaMinutes) })
////            merged = merged.map { var m = $0; m.etaMinutes = etaByRoute[m.routeNo]; return m }
////            self.buses = merged
////
////            startAutoRefresh()
////        } catch {
////            print("❌ reload error: \(error)")
////        }
////    }
//
//    private func startAutoRefresh() {
//        autoTask?.cancel()
//        autoTask = Task { [weak self] in
//            guard let self else { return }
//            while !Task.isCancelled {
//                try? await Task.sleep(nanoseconds: BUS_REFRESH_SEC * 1_000_000_000)
//                await self.refreshBusesOnly()
//            }
//        }
//    }
//
//    private func refreshBusesOnly() async {
//        if isRefreshing { return }
//        isRefreshing = true
//        defer { isRefreshing = false }
//
//        let top = latestTopArrivals
//        guard !top.isEmpty else { return }
//
//        do {
//            let etaByRoute = Dictionary(uniqueKeysWithValues: top.map { ($0.routeNo, $0.etaMinutes) })
//            var mergedById: [String: BusLive] = Dictionary(uniqueKeysWithValues: self.buses.map { ($0.id, $0) }) // 기존 위치 유지
//
//            try await withThrowingTaskGroup(of: [BusLive].self) { group in
//                for a in top {
//                    group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) }
//                }
//                while let arr = try await group.next() {
//                    let enriched = arr.map { b -> BusLive in
//                        var m = b
//                        m.etaMinutes = etaByRoute[m.routeNo]
//                        return m
//                    }
//                    for b in enriched { mergedById[b.id] = b }
//                    self.buses = Array(mergedById.values) // ✅ 부분 결과 즉시 반영
//                }
//            }
//        } catch {
//            // 일시 오류 무시
//        }
//    }
//
////    private func refreshBusesOnly() async {
////        if isRefreshing { return }
////        isRefreshing = true
////        defer { isRefreshing = false }
////        guard !latestTopArrivals.isEmpty else { return }
////        do {
////            let busArrays: [[BusLive]] = try await withThrowingTaskGroup(of: [BusLive].self) { group in
////                for a in latestTopArrivals { group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) } }
////                var acc: [[BusLive]] = []; while let arr = try await group.next() { acc.append(arr) }; return acc
////            }
////            var merged = busArrays.flatMap { $0 }
////            let etaByRoute = Dictionary(uniqueKeysWithValues: latestTopArrivals.map { ($0.routeNo, $0.etaMinutes) })
////            merged = merged.map { var m = $0; m.etaMinutes = etaByRoute[m.routeNo]; return m }
////            self.buses = merged
////        } catch { }
////    }
//}
//
//// MARK: - Map helpers
//private extension MKMapView {
//    var isRegionChangeFromUserInteraction: Bool {
//        guard let grs = subviews.first?.gestureRecognizers else { return false }
//        return grs.contains { $0.state == .began || $0.state == .ended || $0.state == .changed }
//    }
//}
//
//// MARK: - Map View
//struct ClusteredMapView: UIViewRepresentable {
//    @ObservedObject var vm: MapVM
//    @Binding var recenterRequest: Bool
//
//    func makeUIView(context: Context) -> MKMapView {
//        let map = MKMapView(frame: .zero)
//        map.delegate = context.coordinator
//        map.showsUserLocation = true
//        map.region = .init(center: .init(latitude: 36.351, longitude: 127.385),
//                           span: .init(latitudeDelta: 0.045, longitudeDelta: 0.045))
//        map.pointOfInterestFilter = .includingAll
//        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "stop")
//        map.register(BusMarkerView.self, forAnnotationViewWithReuseIdentifier: "bus")
//        map.register(ClusterView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
//        return map
//    }
//
//    func updateUIView(_ uiView: MKMapView, context: Context) {
//        // 내 위치로 이동(권한 없으면 스킵)
//        if recenterRequest {
//            defer { DispatchQueue.main.async { self.recenterRequest = false } }
//            let status = CLLocationManager.authorizationStatus()
//            guard status == .authorizedWhenInUse || status == .authorizedAlways else {
//                print("📍 recenter skipped (auth=\(status))"); return
//            }
//            if let loc = uiView.userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(loc) {
//                context.coordinator.centerOn(loc, mapView: uiView, animated: true)
//            } else {
//                print("📍 user location not ready – skip")
//            }
//        }
//
//        // 정류장 동기화
//        let existingStopAnnos = uiView.annotations.compactMap { $0 as? BusStopAnnotation }
//        let existingStopIds = Set(existingStopAnnos.map { $0.stop.id })
//        let desiredStopIds = Set(vm.stops.map { $0.id })
//        let toAddStops = vm.stops.filter { !existingStopIds.contains($0.id) }.map { BusStopAnnotation($0) }
//        if !toAddStops.isEmpty { uiView.addAnnotations(toAddStops) }
//        let stopToRemove = existingStopAnnos.filter { !desiredStopIds.contains($0.stop.id) }
//        if !stopToRemove.isEmpty { uiView.removeAnnotations(stopToRemove) }
//
//        // 버스 동기화(데이터 기준)
//        let existingBusAnnos = uiView.annotations.compactMap { $0 as? BusAnnotation }
//        var byId = Dictionary(uniqueKeysWithValues: existingBusAnnos.map { ($0.id, $0) })
//        let desiredBusIds = Set(vm.buses.map { $0.id })
//
//        for b in vm.buses {
//            if let anno = byId[b.id] {
//                anno.update(to: b)
//                byId.removeValue(forKey: b.id)
//            } else {
//                uiView.addAnnotation(BusAnnotation(bus: b))
//            }
//        }
//        if !byId.isEmpty {
//            let toRemove = byId.values.filter { leftover in
//                if let sel = vm.followBusId, sel == leftover.id { return false }
//                return !desiredBusIds.contains(leftover.id)
//            }
//            if !toRemove.isEmpty { uiView.removeAnnotations(toRemove) }
//        }
//
//        // 선택 버스 팔로우
//        if let followId = vm.followBusId,
//           let anno = uiView.annotations.first(where: { ($0 as? BusAnnotation)?.id == followId }) as? BusAnnotation {
//            context.coordinator.follow(anno, on: uiView)
//        }
//    }
//
//    func makeCoordinator() -> Coord { Coord(self) }
//
//    final class Coord: NSObject, MKMapViewDelegate {
//        let parent: ClusteredMapView
//        private let deb = Debouncer()
//        private var isAutoRecentering = false
//        init(_ p: ClusteredMapView) { parent = p }
//
//        func centerOn(_ center: CLLocationCoordinate2D, mapView: MKMapView, animated: Bool) {
//            isAutoRecentering = true
//            mapView.setCenter(center, animated: animated)
//            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.isAutoRecentering = false }
//        }
//        func follow(_ anno: BusAnnotation, on mapView: MKMapView) {
//            guard CLLocationCoordinate2DIsValid(anno.coordinate) else { return }
//            let center = mapView.centerCoordinate
//            let a = CLLocation(latitude: center.latitude, longitude: center.longitude)
//            let b = CLLocation(latitude: anno.coordinate.latitude, longitude: anno.coordinate.longitude)
//            if a.distance(from: b) > 30 {
//                centerOn(anno.coordinate, mapView: mapView, animated: true)
//            }
//        }
//
//        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
//            deb.call(after: 0.5) {
//                if self.isAutoRecentering { return }
//                if mapView.isRegionChangeFromUserInteraction {
//                    self.parent.vm.onRegionCommitted(mapView.region)
//                } else if let followId = self.parent.vm.followBusId,
//                          let anno = mapView.annotations.first(where: { ($0 as? BusAnnotation)?.id == followId }) as? BusAnnotation {
//                    self.follow(anno, on: mapView)
//                }
//            }
//        }
//
//        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
//            if let s = annotation as? BusStopAnnotation {
//                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "stop", for: s) as! MKMarkerAnnotationView
//                v.clusteringIdentifier = "stop"
//                v.glyphText = "🚏"
//                v.markerTintColor = .systemRed
//                v.displayPriority = .defaultHigh
//                v.titleVisibility = .adaptive
//                return v
//            } else if let b = annotation as? BusAnnotation {
//                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "bus", for: b) as! BusMarkerView
//                v.clusteringIdentifier = "bus"
//                return v
//            } else if annotation is MKClusterAnnotation {
//                return mapView.dequeueReusableAnnotationView(withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: annotation)
//            }
//            return nil
//        }
//
//        // 선택 시 커지고 팔로우 시작
//        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
//            if let bus = view.annotation as? BusAnnotation {
//                UIView.animate(withDuration: 0.2) {
//                    view.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
//                }
//                parent.vm.followBusId = bus.id
//                follow(bus, on: mapView)
//            }
//        }
//        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
//            if view is BusMarkerView {
//                UIView.animate(withDuration: 0.2) { view.transform = .identity }
//            }
//            // 선택 해제 후에도 계속 따라가고 싶지 않다면 아래 주석 해제
//            // parent.vm.followBusId = nil
//        }
//    }
//}
//
//final class Debouncer {
//    private var work: DispatchWorkItem?
//    func call(after sec: Double, _ block: @escaping () -> Void) {
//        work?.cancel(); let w = DispatchWorkItem(block: block); work = w
//        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: w)
//    }
//}
//
//// MARK: - Location
//final class LocationAuth: NSObject, ObservableObject, CLLocationManagerDelegate {
//    private let mgr = CLLocationManager()
//    override init() { super.init(); mgr.delegate = self }
//    func requestWhenInUse() { mgr.requestWhenInUseAuthorization() }
//}
//
//// MARK: - Screen
//struct BusMapScreen: View {
//    @StateObject private var vm = MapVM()
//    @StateObject private var loc = LocationAuth()
//    @State private var recenterRequest = false
//
//    var body: some View {
//        ZStack {
//            ClusteredMapView(vm: vm, recenterRequest: $recenterRequest)
//                .ignoresSafeArea()
//                .task {
//                    loc.requestWhenInUse()
//                    await vm.reload(center: .init(latitude: 36.351, longitude: 127.385))
//                }
//
//            if SHOW_DEBUG, let e = Optional<String>(nil) {
//                VStack {
//                    Text("⚠️ \(e)").font(.caption2)
//                        .padding(6).background(.ultraThinMaterial).cornerRadius(8)
//                    Spacer()
//                }.padding().frame(maxWidth: .infinity, alignment: .topLeading)
//            }
//
//            Button {
//                loc.requestWhenInUse()
//                recenterRequest = true
//            } label: {
//                Image(systemName: "location.fill")
//                    .font(.system(size: 18, weight: .bold))
//                    .padding(14)
//                    .background(.ultraThinMaterial)
//                    .clipShape(Circle())
//                    .shadow(radius: 3)
//            }
//            .padding(.bottom, 24)
//            .padding(.trailing, 16)
//            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
//        }
//    }
//}
