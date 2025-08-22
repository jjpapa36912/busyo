//
//  Busyo_SingleFile.swift
//  CITY_CODE=25 / 제스처 종료 후 1회 호출 / Arrivals→BusLoc / 클러스터링
//  + 버스=파랑, 정류장=빨강 / API 카운터 / 내 위치 버튼
//  + [FIX] 선택해도 다른 버스 안 사라짐(가시성 제거 → 데이터 기준 제거)
//  + [FIX] 선택 상태에서도 좌표 갱신/애니메이션 반영(KVO)
//  + [ADD] 말풍선·마커 subtitle에 “다음 정류장 · ETA분” (KVO)
//  + [ADD] Dead-reckoning, EMA 스무딩, 스냅, 점프 제거
//  + [FIX] 팔로우 해제 후 재추적 가능 / 겹치면 버스 우선 / 팔로우 이동 시 정류장 자동 로드
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

// MARK: - Geo util
fileprivate struct GeoUtil {
    static func metersPerDegLat(at lat: Double) -> Double { 111_320 }
    static func metersPerDegLon(at lat: Double) -> Double { 111_320 * cos(lat * .pi/180) }
    static func deltaMeters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> (dx: Double, dy: Double, dist: Double) {
        let mLat = metersPerDegLat(at: (a.latitude + b.latitude)/2)
        let mLon = metersPerDegLon(at: (a.latitude + b.latitude)/2)
        let dy = (b.latitude  - a.latitude ) * mLat
        let dx = (b.longitude - a.longitude) * mLon
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
        let safe = url.absoluteString.replacingOccurrences(of: serviceKeyRaw.encodedForServiceKey, with: maskKey(serviceKeyRaw.encodedForServiceKey))
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
                    gpsLati = (try? c.decode(FlexDouble.self, forKey: .gpsLati)) ?? (try? c.decode(FlexDouble.self, forKey: .gpslati))
                    gpsLong = (try? c.decode(FlexDouble.self, forKey: .gpsLong)) ?? (try? c.decode(FlexDouble.self, forKey: .gpslong))
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
                    gpsLati   = (try? c.decode(FlexDouble.self, forKey: .gpsLati)) ?? (try? c.decode(FlexDouble.self, forKey: .gpslati))
                    gpsLong   = (try? c.decode(FlexDouble.self, forKey: .gpsLong)) ?? (try? c.decode(FlexDouble.self, forKey: .gpslong))
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

    // 콜아웃/라벨 표시용 최신 값 (Obj-C KVO 불필요)
    private(set) var nextStopName: String?
    private(set) var etaMinutes: Int?

    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { routeNo }

    // KVO 가능한 subtitleStorage만 유지 (marker subtitle 갱신용)
    @objc dynamic private var subtitleStorage: String?
    var subtitle: String? { subtitleStorage }

    init(bus: BusLive) {
        id = bus.id
        routeNo = bus.routeNo
        coordinate = .init(latitude: bus.lat, longitude: bus.lon)
        nextStopName = bus.nextStopName
        etaMinutes   = bus.etaMinutes
        super.init()
        setSubtitle(Self.makeSubtitle(eta: bus.etaMinutes, next: bus.nextStopName))
    }

    private static func makeSubtitle(eta: Int?, next: String?) -> String? {
        switch (eta, next) {
        case let (.some(e), .some(n)): return "다음 \(n) · 약 \(e)분"
        case let (.none, .some(n)):    return "다음 \(n)"
        case let (.some(e), .none):    return "약 \(e)분"
        default:                       return nil
        }
    }

    private func setSubtitle(_ s: String?) {
        willChangeValue(forKey: "subtitle")
        subtitleStorage = s
        didChangeValue(forKey: "subtitle")
    }

    func update(to b: BusLive) {
        // 값 갱신
        self.nextStopName = b.nextStopName
        self.etaMinutes   = b.etaMinutes
        // 마커 subtitle 즉시 반영
        setSubtitle(Self.makeSubtitle(eta: b.etaMinutes, next: b.nextStopName))

        // 좌표 애니메이션
        let newC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        self.coordinate = newC
        CATransaction.commit()
    }
}

// MARK: - Marker view with custom callout (+ 항상 보이는 subtitle)
final class BusMarkerView: MKMarkerAnnotationView {
    private let etaLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        glyphImage = UIImage(systemName: "bus.fill")
        titleVisibility = .visible
        subtitleVisibility = .visible        // 👈 마커 위의 소제목 항상 보이게
        canShowCallout = true

        glyphTintColor = .white
        centerOffset = CGPoint(x: 0, y: -10)
        collisionMode = .circle
        displayPriority = .required          // 👈 버스 우선 노출
        layer.zPosition = 10                 // 👈 겹치면 버스가 위

        // 콜아웃(말풍선) detail — 선택 시에도 동일 정보 노출(2줄)
        etaLabel.font = .systemFont(ofSize: 13)
        etaLabel.numberOfLines = 2
        etaLabel.textColor = .secondaryLabel
        self.detailCalloutAccessoryView = etaLabel
    }
    required init?(coder: NSCoder) { fatalError() }

    func configureTint(isFollowed: Bool) {
        markerTintColor = isFollowed ? .systemGreen : .systemBlue
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        if let b = annotation as? BusAnnotation { glyphText = b.routeNo }
        refreshDetail()
    }

    func refreshDetail() {
        guard let a = annotation as? BusAnnotation else { return }
        // 콜아웃 라벨
        if let next = a.nextStopName, let eta = a.etaMinutes {
            etaLabel.text = "다음 \(next)\n약 \(eta)분"
        } else if let next = a.nextStopName {
            etaLabel.text = "다음 \(next)"
        } else if let eta = a.etaMinutes {
            etaLabel.text = "약 \(eta)분"
        } else {
            etaLabel.text = nil
        }
        if isSelected { setNeedsLayout() }
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
    var speedMps: Double = 0
    var dirUnit: (x: Double, y: Double)? = nil

    mutating func updateKinematics() {
        guard let p = prevLoc, let _ = prevAt else { speedMps = 0; dirUnit = nil; return }
        let v = GeoUtil.deltaMeters(from: p, to: lastLoc)
        let dt = max(0.01, lastAt.timeIntervalSince(prevAt!))
        speedMps = v.dist / dt
        if v.dist > 0.5 { dirUnit = (x: v.dx / v.dist, y: v.dy / v.dist) } else { dirUnit = nil }
    }

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

        let v = GeoUtil.deltaMeters(from: p, to: lastLoc)
        let ux = v.dx / max(0.001, v.dist)
        let uy = v.dy / max(0.001, v.dist)

        let dLat = (fwd * uy) / mLat
        let dLon = (fwd * ux) / mLon
        return .init(latitude: lastLoc.latitude + dLat, longitude: lastLoc.longitude + dLon)
    }

    func coastPredict(at t: Date, decay: Double, minSpeed: Double) -> CLLocationCoordinate2D {
        guard let p = prevLoc, let pa = prevAt else { return lastLoc }
        let base = GeoUtil.deltaMeters(from: p, to: lastLoc)
        let baseDt = max(0.01, lastAt.timeIntervalSince(pa))
        let baseV  = base.dist / baseDt
        let dt = max(0, t.timeIntervalSince(lastAt))
        let v = max(minSpeed, baseV * pow(decay, dt))
        if v < minSpeed { return lastLoc }

        let ux = base.dx / max(0.001, base.dist)
        let uy = base.dy / max(0.001, base.dist)
        let forward = v * dt

        let mLat = GeoUtil.metersPerDegLat(at: lastLoc.latitude)
        let mLon = GeoUtil.metersPerDegLon(at: lastLoc.latitude)
        let dLat = (forward * uy) / mLat
        let dLon = (forward * ux) / mLon
        return .init(latitude: lastLoc.latitude + dLat, longitude: lastLoc.longitude + dLon)
    }
}

// MARK: - ViewModel
@MainActor
final class MapVM: ObservableObject {
    @Published var stops: [BusStop] = []
    @Published var buses: [BusLive] = []
    @Published var followBusId: String?

    // 유령 파라미터
    private let STALE_GRACE_SEC: TimeInterval = 45
    private let COAST_MIN_SPEED: Double = 0.3
    private let COAST_DECAY_PER_SEC: Double = 0.92
    private var routeNoById: [String: String] = [:]

    private let api = BusAPI()
    private var lastRegion: MKCoordinateRegion?
    private var lastReloadAt: Date = .distantPast
    private var regionTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var latestTopArrivals: [ArrivalInfo] = []
    private var isRefreshing = false

    // smoothing / snapping
    private var tracks: [String: BusTrack] = [:]
    private let maxStepMeters: CLLocationDistance = 300
    private let emaAlpha: Double = 0.35
    private let snapRadius: CLLocationDistance = 18
    private let dwellSec: TimeInterval = 15
    private var dwellUntil: [String: Date] = [:]

    deinit { autoTask?.cancel(); regionTask?.cancel() }

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

    // follow 중인데 새 결과에 그 id가 없으면 유령 샘플 합성
    private func ensureFollowGhost(_ mergedById: inout [String: BusLive]) {
        guard let fid = followBusId, mergedById[fid] == nil, let tr = tracks[fid] else { return }
        let age = Date().timeIntervalSince(tr.lastAt)
        guard age < STALE_GRACE_SEC else { followBusId = nil; return }
        let pred = tr.coastPredict(at: Date().addingTimeInterval(0.6), decay: COAST_DECAY_PER_SEC, minSpeed: COAST_MIN_SPEED)
        var ghost = mergedById.values.first { $0.id == fid } ?? BusLive(id: fid, routeNo: routeNoById[fid] ?? "?", lat: pred.latitude, lon: pred.longitude, etaMinutes: nil, nextStopName: nil)
        ghost.lat = pred.latitude
        ghost.lon = pred.longitude
        if let trc = tracks[fid] {
            let (ns, eta) = nextStopAndETA(for: pred, track: trc, fallbackByName: ghost.nextStopName)
            if let s = ns { ghost.nextStopName = s.name }
            if let e = eta { ghost.etaMinutes = e }
        }
        mergedById[fid] = ghost
    }

    // 진행방향 앞쪽 정류장 + ETA
    private func nextStopAndETA(for coord: CLLocationCoordinate2D, track: BusTrack, fallbackByName: String?) -> (BusStop?, Int?) {
        let here = coord
        let nearby = stops
            .map { stop -> (BusStop, Double, Double, Double) in
                let v = GeoUtil.deltaMeters(from: here, to: .init(latitude: stop.lat, longitude: stop.lon))
                return (stop, v.dx, v.dy, v.dist)
            }
            .filter { $0.3 < 300 }

        let dir = track.dirUnit
        let ranked: [(BusStop, Double, Double, Double)]
        if let d = dir {
            ranked = nearby
                .map { (s, dx, dy, dist) -> (BusStop, Double, Double, Double) in
                    let proj = dx*d.x + dy*d.y
                    let lateral = abs(-dy*d.x + dx*d.y)
                    return (s, proj, lateral, dist)
                }
                .sorted {
                    if ($0.1 >= 0) != ($1.1 >= 0) { return $0.1 >= 0 }
                    if abs($0.2 - $1.2) > 3 { return $0.2 < $1.2 }
                    return $0.3 < $1.3
                }
        } else {
            ranked = nearby.sorted { $0.3 < $1.3 }
        }

        var chosen: BusStop?
        var forwardMeters: Double?
        if let first = ranked.first, dir != nil, first.1 >= -15 {
            chosen = first.0
            forwardMeters = max(0, first.1)
        }
        if chosen == nil, let name = fallbackByName {
            chosen = stops.first { name.contains($0.name) || $0.name.contains(name) }
            if let c = chosen {
                let v = GeoUtil.deltaMeters(from: here, to: .init(latitude: c.lat, longitude: c.lon))
                forwardMeters = v.dist
            }
        }
        if chosen == nil, let near = nearby.min(by: { $0.3 < $1.3 }) {
            chosen = near.0
            forwardMeters = near.3
        }
        guard let stop = chosen else { return (nil, nil) }

        let v = max(0.1, track.speedMps)
        let dist = max(0, forwardMeters ?? 0)
        var etaSec = Int(dist / v)
        if v < 1.2 && dist < 25 { etaSec = 0 }
        let etaMin = max(0, Int((Double(etaSec) / 60.0).rounded(.toNearestOrEven)))
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

            var mergedById: [String: BusLive] = [:]
            try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in top {
                    group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) }
                }
                while let arr = try await group.next() {
                    let enriched = arr.map { b -> BusLive in var m = b; m.etaMinutes = etaByRoute[m.routeNo]; return m }
                    let filtered = self.mergeAndFilter(enriched)
                    for b in filtered { routeNoById[b.id] = b.routeNo; mergedById[b.id] = b }
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
                    let enriched = arr.map { b -> BusLive in var m = b; m.etaMinutes = etaByRoute[m.routeNo]; return m }
                    let filtered = self.mergeAndFilter(enriched)
                    for b in filtered { routeNoById[b.id] = b.routeNo; mergedById[b.id] = b }
                    self.ensureFollowGhost(&mergedById)
                    self.buses = Array(mergedById.values)
                }
            }
        } catch { }
    }

    // MARK: - Filtering & snapping
    private func mergeAndFilter(_ incoming: [BusLive]) -> [BusLive] {
        var out: [BusLive] = []
        for var b in incoming {
            let now = Date()
            let rawC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)

            if var tr = tracks[b.id] {
                let step = CLLocation(latitude: tr.lastLoc.latitude, longitude: tr.lastLoc.longitude)
                    .distance(from: CLLocation(latitude: rawC.latitude, longitude: rawC.longitude))
                if step > maxStepMeters { continue }

                let lat = tr.lastLoc.latitude  * (1 - emaAlpha) + rawC.latitude  * emaAlpha
                let lon = tr.lastLoc.longitude * (1 - emaAlpha) + rawC.longitude * emaAlpha
                let smooth = CLLocationCoordinate2D(latitude: lat, longitude: lon)

                tr.prevLoc = tr.lastLoc
                tr.prevAt  = tr.lastAt
                tr.lastLoc = smooth
                tr.lastAt  = now
                tr.updateKinematics()
                tracks[b.id] = tr

                let pred = tr.predicted(at: now.addingTimeInterval(0.6))
                b.lat = pred.latitude
                b.lon = pred.longitude

                let (nextStop, etaMin) = nextStopAndETA(for: pred, track: tr, fallbackByName: b.nextStopName)
                if let s = nextStop { b.nextStopName = s.name }
                if let e = etaMin   { b.etaMinutes   = e }
            } else {
                tracks[b.id] = BusTrack(prevLoc: nil, prevAt: nil, lastLoc: rawC, lastAt: now)
            }

            maybeSnapToStop(&b)
            out.append(b)
        }
        return out
    }

    private func maybeSnapToStop(_ b: inout BusLive) {
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
            b.etaMinutes = 0
        } else {
            let recentOk: Bool = {
                if let tr = tracks[b.id] { return Date().timeIntervalSince(tr.lastAt) < 2 * TimeInterval(BUS_REFRESH_SEC) }
                return false
            }()
            if let until = dwellUntil[b.id], until < Date() || !recentOk {
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
        // 내 위치 버튼 처리
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

        // 1) 스냅샷
        let currentStops = uiView.annotations.compactMap { $0 as? BusStopAnnotation }
        let currentBuses = uiView.annotations.compactMap { $0 as? BusAnnotation }
        let currentStopIds = Set(currentStops.map { $0.stop.id })

        // 2) 원하는 상태
        let desiredStops = vm.stops
        let desiredBuses = vm.buses
        let desiredStopIds = Set(desiredStops.map { $0.id })

        // add/remove
        let stopsToAdd    = desiredStops.filter { !currentStopIds.contains($0.id) }.map { BusStopAnnotation($0) }
        let stopsToRemove = currentStops.filter { !desiredStopIds.contains($0.stop.id) }

        var busAnnoById = Dictionary(uniqueKeysWithValues: currentBuses.map { ($0.id, $0) })
        var busesToAdd: [BusAnnotation] = []
        var busesToRemove: [BusAnnotation] = []
        var busUpdates: [(BusAnnotation, BusLive)] = []

        for b in desiredBuses {
            if let anno = busAnnoById.removeValue(forKey: b.id) {
                busUpdates.append((anno, b))
            } else {
                busesToAdd.append(BusAnnotation(bus: b))
            }
        }
        for leftover in busAnnoById.values {
            if let sel = vm.followBusId, sel == leftover.id { continue }
            let stillDesired = desiredBuses.contains { $0.id == leftover.id }
            if stillDesired { continue }
            busesToRemove.append(leftover)
        }

        // 3) 일괄 적용
        context.coordinator.applyAnnotationDiff(
            on: uiView,
            stopsToAdd: stopsToAdd,
            stopsToRemove: stopsToRemove,
            busesToAdd: busesToAdd,
            busesToRemove: busesToRemove,
            busUpdates: busUpdates
        )

        // 4) 팔로우 중이면 재센터+색상 최신화
        if let followId = vm.followBusId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let anno = uiView.annotations.first(where: { ($0 as? BusAnnotation)?.id == followId }) as? BusAnnotation {
                    context.coordinator.follow(anno, on: uiView)
                    if let v = uiView.view(for: anno) as? BusMarkerView {
                        v.configureTint(isFollowed: true)
                        v.refreshDetail()
                    }
                }
            }
        }

        // 5) 배치 후 팔로우 색상/라벨 일괄 재도색(안전망)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            context.coordinator.updateFollowTints(uiView)
        }
    }

    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, MKMapViewDelegate {
        let parent: ClusteredMapView
        private let deb = Debouncer()
        private var isAutoRecentering = false
        private var isApplyingDiff = false

        init(_ p: ClusteredMapView) { parent = p }

        // 추적 색상 일괄 반영
        func updateFollowTints(_ mapView: MKMapView) {
            let followed = parent.vm.followBusId
            for anno in mapView.annotations {
                guard let a = anno as? BusAnnotation,
                      let v = mapView.view(for: a) as? BusMarkerView else { continue }
                v.configureTint(isFollowed: (a.id == followed))
            }
        }

        // diff 적용 (delegate 잠시 분리)
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

                let oldDelegate = mapView.delegate
                mapView.delegate = nil

                UIView.performWithoutAnimation {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    if !stopsToRemove.isEmpty || !busesToRemove.isEmpty {
                        mapView.removeAnnotations(stopsToRemove + busesToRemove)
                    }
                    if !stopsToAdd.isEmpty || !busesToAdd.isEmpty {
                        mapView.addAnnotations(stopsToAdd + busesToAdd)
                    }
                    CATransaction.commit()
                }

                // 좌표/데이터 업데이트 + 콜아웃/서브타이틀 즉시 갱신
                if !busUpdates.isEmpty {
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.9)
                    for (anno, live) in busUpdates {
                        anno.update(to: live)
                        if let mv = mapView.view(for: anno) as? BusMarkerView {
                            mv.refreshDetail()
                        }
                    }
                    CATransaction.commit()
                }

                mapView.setNeedsLayout()
                mapView.layoutIfNeeded()
                mapView.delegate = oldDelegate
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
                // 팔로우 이동으로 화면이 크게 바뀌었으면 정류장 자동 갱신
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.parent.vm.onRegionCommitted(mapView.region)
                }
            }
        }

        // 뷰 팩토리
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let s = annotation as? BusStopAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "stop", for: s) as! MKMarkerAnnotationView
                v.clusteringIdentifier = "stop"
                v.glyphText = "🚏"
                v.markerTintColor = .systemRed
                v.displayPriority = .defaultLow     // 👈 버스가 우선
                v.layer.zPosition = 1
                v.titleVisibility = .adaptive
                return v
            } else if let b = annotation as? BusAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "bus", for: b) as! BusMarkerView
                v.clusteringIdentifier = "bus"
                v.configureTint(isFollowed: (parent.vm.followBusId == b.id))
                // 콜아웃 버튼
                v.canShowCallout = true
                let btn = UIButton(type: .system)
                let following = (parent.vm.followBusId == b.id)
                btn.setTitle(following ? "해제" : "추적", for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
                v.rightCalloutAccessoryView = btn
                // 초기 라벨 세팅
                v.refreshDetail()
                return v
            } else if annotation is MKClusterAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: annotation)
            }
            return nil
        }

        // **탭 토글**: 같은 버스를 다시 누르면 해제, 해제 후 다시 누르면 재추적
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let bus = view.annotation as? BusAnnotation else { return }
            let already = (parent.vm.followBusId == bus.id)
            if already {
                // → 추적 해제
                parent.vm.followBusId = nil
                UIView.animate(withDuration: 0.2) { view.transform = .identity }
                if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: false) }
                mapView.deselectAnnotation(bus, animated: true)
                return
            }
            // → 새 추적 시작
            UIView.animate(withDuration: 0.2) { view.transform = CGAffineTransform(scaleX: 1.35, y: 1.35) }
            parent.vm.followBusId = bus.id
            follow(bus, on: mapView)
            if let mv = view as? BusMarkerView {
                mv.configureTint(isFollowed: true)
                mv.refreshDetail()
                if let btn = mv.rightCalloutAccessoryView as? UIButton { btn.setTitle("해제", for: .normal) }
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if view is BusMarkerView {
                UIView.animate(withDuration: 0.2) { view.transform = .identity }
                // 버튼 라벨은 선택 해제와 무관 (토글은 didSelect/callout에서만)
            }
        }

        // 콜아웃 버튼으로도 토글
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            guard let bus = view.annotation as? BusAnnotation else { return }
            if parent.vm.followBusId == bus.id {
                parent.vm.followBusId = nil
                mapView.deselectAnnotation(bus, animated: true)
                if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: false) }
                if let mv = view as? BusMarkerView, let btn = mv.rightCalloutAccessoryView as? UIButton { btn.setTitle("추적", for: .normal) }
            } else {
                parent.vm.followBusId = bus.id
                follow(bus, on: mapView)
                if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: true); mv.refreshDetail() }
                if let mv = view as? BusMarkerView, let btn = mv.rightCalloutAccessoryView as? UIButton { btn.setTitle("해제", for: .normal) }
            }
        }

        // 지도가 움직였을 때: 사용자 제스처가 아니더라도, 팔로우 중이면 주기적으로 정류장 재로딩
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            deb.call(after: 0.5) {
                // 팔로우 중이면 자동 이동이어도 주기적으로 로드
                if let fid = self.parent.vm.followBusId, !fid.isEmpty {
                    self.parent.vm.onRegionCommitted(mapView.region)
                    return
                }
                // 사용자 조작 시에도 로드
                if mapView.isRegionChangeFromUserInteraction {
                    self.parent.vm.onRegionCommitted(mapView.region)
                }
            }
        }
    }
}

final class Debouncer {
    private var work: DispatchWorkItem?
    func call(after sec: Double, _ block: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: block)
        work = w
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

            // 내 위치 버튼
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
        // 고정 “추적 중” 배지
        .overlay(alignment: .topLeading) {
            TrackingBadgeView(vm: vm)
                .padding(.top, 8)
                .padding(.leading, 8)
                .padding(.trailing, 8)
        }
    }
}

// 고정 추적 배지
struct TrackingBadgeView: View {
    @ObservedObject var vm: MapVM

    var body: some View {
        if let fid = vm.followBusId,
           let info = vm.buses.first(where: { $0.id == fid }) {
            HStack(spacing: 8) {
                Text("🎯 추적 중").font(.caption).bold()
                Text("\(info.routeNo) • \(info.nextStopName ?? "다음 정류장 미정")")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { vm.followBusId = nil }
                } label: {
                    Text("해제").font(.caption2).bold()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("추적 중 배지")
        }
    }
}
