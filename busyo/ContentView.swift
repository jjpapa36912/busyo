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

    // BusAPI 안에 추가
    func fetchStopsByRoute(cityCode: Int, routeId: String) async throws -> [BusStop] {
        // 국토부: BusRouteInfoInqireService/getRouteAcctoThrghSttnList
        let url = try urlWithEncodedKey(
            base: "https://apis.data.go.kr/1613000/BusRouteInfoInqireService/getRouteAcctoThrghSttnList",
            items: [
                .init(name: "pageNo", value: "1"),
                .init(name: "numOfRows", value: "500"),
                .init(name: "_type", value: "json"),
                .init(name: "type", value: "json"),
                .init(name: "cityCode", value: String(cityCode)),
                .init(name: "routeId", value: routeId)
            ])

        struct Root: Decodable {
            struct Resp: Decodable { let body: Body? }
            struct Body: Decodable { let items: ItemsFlex<Item>? }
            struct Item: Decodable {
                let nodeid: String
                let nodenm: String
                let gpsLati: FlexDouble?
                let gpsLong: FlexDouble?
                enum CodingKeys: String, CodingKey { case nodeid, nodenm, gpsLati, gpsLong, gpslati, gpslong }
                init(from d: Decoder) throws {
                    let c = try d.container(keyedBy: CodingKeys.self)
                    nodeid = try c.decode(String.self, forKey: .nodeid)
                    nodenm = try c.decode(String.self, forKey: .nodenm)
                    gpsLati = (try? c.decode(FlexDouble.self, forKey: .gpsLati)) ?? (try? c.decode(FlexDouble.self, forKey: .gpslati))
                    gpsLong = (try? c.decode(FlexDouble.self, forKey: .gpsLong)) ?? (try? c.decode(FlexDouble.self, forKey: .gpslong))
                }
            }
            let response: Resp?
        }

        let (data, _) = try await send("RouteStops", url: url)
        if isLikelyXML(data) {
            let arr = try parseXMLItems(data)
            return arr.compactMap { d in
                guard let id = d["nodeid"], let name = d["nodenm"],
                      let la = toDouble(d["gpslati"]) ?? toDouble(d["gpsLati"]),
                      let lo = toDouble(d["gpslong"]) ?? toDouble(d["gpsLong"]) else { return nil }
                return .init(id: id, name: name, lat: la, lon: lo, cityCode: cityCode)
            }
        } else {
            let r = try JSONDecoder().decode(Root.self, from: data)
            let items = r.response?.body?.items?.values ?? []
            return items.compactMap {
                guard let la = $0.gpsLati?.value, let lo = $0.gpsLong?.value else { return nil }
                return .init(id: $0.nodeid, name: $0.nodenm, lat: la, lon: lo, cityCode: cityCode)
            }
        }
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

        // ⬇️ Root/Items 정의를 아래처럼 교체
        // ⬇️ Root 정의만 교체
        struct Root: Decodable {
            struct Resp: Decodable { let body: Body? }
            struct Body: Decodable { let items: ItemsFlex<Item>? }   // ← 핵심
            struct Item: Decodable {
                let routeid: String?
                let routeno: FlexString?
                let arrtime: FlexInt?
            }
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
            // ⬇️ JSON 브랜치의 매핑만 이처럼 교체
            // JSON 분기만 아래처럼
            let r = try JSONDecoder().decode(Root.self, from: data)
            let items = r.response?.body?.items?.values ?? []     // ← 안전
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
// ⬇️ 기존 BusMarkerView 전체 교체
// ⬇️ 기존 BusMarkerView 를 이 클래스로 교체
final class BusMarkerView: MKMarkerAnnotationView {
    private let bubble = UIView()
    private let bubbleLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        // 시스템 타이틀/서브타이틀/콜아웃 비활성화 → 뒤의 검정 박스 제거
        titleVisibility = .hidden
        subtitleVisibility = .hidden
        canShowCallout = false

        glyphImage = UIImage(systemName: "bus.fill")
        glyphTintColor = .white
        centerOffset = CGPoint(x: 0, y: -10)
        collisionMode = .circle
        displayPriority = .required
        layer.zPosition = 10
        clipsToBounds = false

        // 커스텀 말풍선
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        bubble.layer.cornerRadius = 6
        bubble.layer.masksToBounds = true

        bubbleLabel.translatesAutoresizingMaskIntoConstraints = false
        bubbleLabel.font = .systemFont(ofSize: 11)      // 더 작은 폰트
        bubbleLabel.textColor = .label
        bubbleLabel.numberOfLines = 1                    // 한 줄로 가로로 길게
        bubbleLabel.adjustsFontSizeToFitWidth = true     // 폭에 맞춰 축소
        bubbleLabel.minimumScaleFactor = 0.7             // 최소 70%까지 축소
        bubbleLabel.lineBreakMode = .byTruncatingTail

        addSubview(bubble)
        bubble.addSubview(bubbleLabel)

        NSLayoutConstraint.activate([
            // 말풍선을 마커 위에 붙이고, 가로 최대폭을 크게(340pt) 설정
            bubble.centerXAnchor.constraint(equalTo: centerXAnchor),
            bubble.bottomAnchor.constraint(equalTo: topAnchor, constant: -2),
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 340),

            bubbleLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 8),
            bubbleLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -8),
            bubbleLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 4),
            bubbleLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configureTint(isFollowed: Bool) {
        markerTintColor = isFollowed ? .systemGreen : .systemBlue
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        if let b = annotation as? BusAnnotation { glyphText = b.routeNo }
        updateAlwaysOnBubble()
    }

    /// 마커 위 상시 말풍선 텍스트 갱신 (다음 정류장 · ETA분)
    func updateAlwaysOnBubble() {
        guard let a = annotation as? BusAnnotation else { return }
        let text: String? = {
            if let next = a.nextStopName, let eta = a.etaMinutes {
                return "다음 \(next) · \(eta)분"
            } else if let next = a.nextStopName {
                return "다음 \(next)"
            } else if let eta = a.etaMinutes {
                return "약 \(eta)분"
            } else {
                return nil
            }
        }()
        bubbleLabel.text = text
        bubble.isHidden = (text == nil)
        setNeedsLayout()
        layoutIfNeeded()
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
    // MapVM 안
    private var reloadTask: Task<Void, Never>?
    // MapVM 안에 추가
    private var lastPredictedStopId: [String: String] = [:]   // busId -> stopId

    // MapVM 안에 추가
    private var routeIdByRouteNo: [String: String] = [:]          // 이번 회차 도출된 매핑
    private var lastKnownRouteIdByRouteNo: [String: String] = [:] // 히스토리 캐시(신호등/야간 대비)



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
    
    // MapVM 안
    private var lastStopRefreshCenter: CLLocationCoordinate2D?
    private let stopQueryRadiusMeters: CLLocationDistance = 500          // 보여줄 반경 정보(개념적)
    private let centerShiftTriggerMeters: CLLocationDistance = 200       // 재조회 트리거 임계치(사용자 드래그)
    private let centerShiftTriggerWhenFollow: CLLocationDistance = 120   // 재조회 트리거 임계치(팔로우 중)


    // smoothing / snapping
    private var tracks: [String: BusTrack] = [:]
    private let maxStepMeters: CLLocationDistance = 300
    private let emaAlpha: Double = 0.35
    private let snapRadius: CLLocationDistance = 18
    private let dwellSec: TimeInterval = 15
    private var dwellUntil: [String: Date] = [:]
    
    // MapVM 안에 추가
    private var lastETA: [String: (eta: Int, at: Date)] = [:]
    // MapVM 프로퍼티 (캐시)
    private var routeStopsByRouteId: [String: [BusStop]] = [:]
    
    // routeNo -> routeId 해석
    private func resolveRouteId(for routeNo: String) -> String? {
        if let id = routeIdByRouteNo[routeNo] { return id }
        if let id = lastKnownRouteIdByRouteNo[routeNo] { return id }
        // latestTopArrivals 안에서도 시도
        if let id = latestTopArrivals.first(where: { $0.routeNo == routeNo })?.routeId {
            routeIdByRouteNo[routeNo] = id
            lastKnownRouteIdByRouteNo[routeNo] = id
            return id
        }
        return nil
    }

    // 버스 선택 시: 해당 노선의 정류장 목록을 캐시에 로드
    func onBusSelected(_ bus: BusAnnotation) async {
        guard let rid = resolveRouteId(for: bus.routeNo) else { return }
        if routeStopsByRouteId[rid] != nil { return } // 캐시 있으면 스킵
        do {
            let stops = try await api.fetchStopsByRoute(cityCode: CITY_CODE, routeId: rid)
            routeStopsByRouteId[rid] = stops
        } catch {
            print("❌ route stops load error: \(error)")
        }
    }
    
    // MapVM 안에 추가: 노선 정류장 배열 기반으로 다음 정류장 추정
    private func nextStopFromRoute(
        busId: String,
        busCoord: CLLocationCoordinate2D,
        track: BusTrack,
        routeStops: [BusStop],
        lastStopId: String?
    ) -> BusStop? {
        guard !routeStops.isEmpty else { return nil }

        // 1) 가장 가까운 정류장 index
        let idx = routeStops.enumerated().min { lhs, rhs in
            let dl = GeoUtil.deltaMeters(from: busCoord, to: .init(latitude: lhs.element.lat, longitude: lhs.element.lon)).dist
            let dr = GeoUtil.deltaMeters(from: busCoord, to: .init(latitude: rhs.element.lat, longitude: rhs.element.lon)).dist
            return dl < dr
        }?.offset ?? 0

        // 2) 진행 방향으로 다음 index 선택
        var nextIdx = idx
        if let d = track.dirUnit, idx + 1 < routeStops.count {
            let v = GeoUtil.deltaMeters(from: busCoord, to: .init(latitude: routeStops[idx+1].lat, longitude: routeStops[idx+1].lon))
            let dot = v.dx*d.x + v.dy*d.y
            if dot > 0 { nextIdx = idx + 1 }
        }

        // 3) 히스테리시스: 최근 선택값이 인접해 있으면 유지
        if let last = lastStopId, let lastIdx = routeStops.firstIndex(where: { $0.id == last }),
           abs(lastIdx - nextIdx) <= 1 {
            return routeStops[lastIdx]
        }

        // 4) 최종 선택 기록
        lastPredictedStopId[busId] = routeStops[nextIdx].id
        return routeStops[nextIdx]
    }



    // ETA 스무딩
    private func smoothETA(rawETA: Int?, busId: String, distToNextStop: Double?) -> Int? {
        guard let raw = rawETA else { return nil }
        let now = Date()

        // 멈춤-신호등 상황 완화: 정류장에서 멀리(>50m) + 느림일 때 증가율 제한
        let farFromStop = (distToNextStop ?? 9999) > 50
        let speed = tracks[busId]?.speedMps ?? 0
        let isSlow = speed < 1.0

        if isSlow && farFromStop, let prev = lastETA[busId] {
            // 30초당 +1분까지만 증가 허용, 감소는 즉시 반영
            if raw >= prev.eta {
                let dt = now.timeIntervalSince(prev.at)
                let allowedIncrease = Int(dt / 30.0) // 0,1,2...
                let capped = min(prev.eta + allowedIncrease, raw)
                lastETA[busId] = (capped, now)
                return capped
            } else {
                lastETA[busId] = (raw, now)
                return raw
            }
        } else {
            lastETA[busId] = (raw, now)
            return raw
        }
    }


    deinit { autoTask?.cancel(); regionTask?.cancel() }

    // MapVM 안
    private func metersBetween(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> CLLocationDistance {
        guard let a, let b else { return .greatestFiniteMagnitude }
        let la = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let lb = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return la.distance(from: lb)
    }

    
    // ⬇️ 이 메서드를 통째로 교체
    // MapVM
    private func shouldReload(for region: MKCoordinateRegion) -> Bool {
        // 팔로우 중엔 더 민감
        let threshold: CLLocationDistance = (followBusId == nil) ? 180 : 120

        // 첫 호출
        if lastStopRefreshCenter == nil { return true }

        // 마지막 "정류장/버스" 갱신 중심에서 얼마나 이동했는지
        let moved = metersBetween(lastStopRefreshCenter, region.center)
        if moved >= threshold { return true }

        // 줌 급변은 보조 트리거
        if let prev = lastRegion {
            let zoomDelta = abs(region.span.latitudeDelta - prev.span.latitudeDelta) /
                            max(prev.span.latitudeDelta, 0.0001)
            if zoomDelta >= 0.20 { return true }
        } else {
            return true
        }
        return false
    }



    // follow 중인데 새 결과에 그 id가 없으면 유령 샘플 합성
    // ⬇️ 이 메서드를 교체
    // ⬇️ 교체
    private func ensureFollowGhost(_ mergedById: inout [String: BusLive]) {
        guard let fid = followBusId, mergedById[fid] == nil, let tr = tracks[fid] else { return }

        let age = Date().timeIntervalSince(tr.lastAt)
        let dwellHolding = (dwellUntil[fid] ?? .distantPast) > Date()
        let maxGhostAge: TimeInterval = dwellHolding ? 3600 : 300 // 체류 중 무기한, 일반 5분
        guard age < maxGhostAge else { return }

        let pred = tr.coastPredict(at: Date().addingTimeInterval(0.6),
                                   decay: COAST_DECAY_PER_SEC, minSpeed: COAST_MIN_SPEED)

        var ghost = mergedById.values.first { $0.id == fid }
            ?? BusLive(id: fid, routeNo: routeNoById[fid] ?? "?", lat: pred.latitude, lon: pred.longitude, etaMinutes: nil, nextStopName: nil)

        ghost.lat = pred.latitude
        ghost.lon = pred.longitude

        let (ns, etaRaw) = nextStopAndETA(busId: fid, coord: pred, track: tr, fallbackByName: ghost.nextStopName)
        if let s = ns { ghost.nextStopName = s.name }
        let dist = ns.map { s in GeoUtil.deltaMeters(from: pred, to: .init(latitude: s.lat, longitude: s.lon)).dist }
        ghost.etaMinutes = smoothETA(rawETA: etaRaw, busId: fid, distToNextStop: dist)

        mergedById[fid] = ghost
    }


    // 진행방향 앞쪽 정류장 + ETA
    // ⬇️ MapVM 안의 nextStopAndETA(...) 메서드 교체
    // ⬇️ MapVM 안의 nextStopAndETA(...) 전체 교체
    private func nextStopAndETA(
        busId: String,
        coord: CLLocationCoordinate2D,
        track: BusTrack,
        fallbackByName: String?
    ) -> (BusStop?, Int?) {

        // 파라미터/가중치
        let searchRadius: Double = 320                  // 후보 반경
        let aheadProjMin: Double = -8                   // 약간의 오차 허용(스냅 직후)
        let lateralBias: Double = 2.2                   // 측면 벌점(클수록 진행축 위 후보 선호)
        let switchMarginMeters: Double = 22             // 기존 후보를 버리고 바꿀 최소 우위
        let stickSecs: TimeInterval = 8                 // 최소 유지 시간(히스테리시스)
        let passBehindProj: Double = -18                // 충분히 뒤로 갔으면 “지나침” 처리
        let keepSameIfNearMeters: Double = 60           // 기존 후보가 이 범위면 웬만하면 유지

        // 1) 반경 내 후보 수집
        let here = coord
        let nearby = stops
            .map { stop -> (s: BusStop, dx: Double, dy: Double, dist: Double) in
                let v = GeoUtil.deltaMeters(from: here, to: .init(latitude: stop.lat, longitude: stop.lon))
                return (stop, v.dx, v.dy, v.dist)
            }
            .filter { $0.dist < searchRadius }

        // 후보 없으면 fallback
        guard !nearby.isEmpty else {
            // fallbackByName가 유효하면 그걸로
            if let name = fallbackByName,
               let found = stops.first(where: { name.contains($0.name) || $0.name.contains(name) }) {
                let v = GeoUtil.deltaMeters(from: here, to: .init(latitude: found.lat, longitude: found.lon))
                let vObs = max(0.1, track.speedMps)
                let vForETA = max(1.5, vObs)
                let etaMin = Int((v.dist / vForETA / 60).rounded(.toNearestOrEven))
                return (found, max(0, etaMin))
            }
            return (nil, nil)
        }

        // 2) 진행방향 벡터
        let dir = track.dirUnit

        // 3) 방향 점수화
        struct Cand { let s: BusStop; let proj: Double; let lateral: Double; let dist: Double; let score: Double }
        let ranked: [Cand] = nearby.map { c in
            if let d = dir {
                let proj = c.dx*d.x + c.dy*d.y           // 진행축 투영(+ 앞)
                let lat  = abs(-c.dy*d.x + c.dx*d.y)     // 측면 거리
                let score = proj - lateralBias*lat       // 점수(앞/축 위 가산)
                return Cand(s: c.s, proj: proj, lateral: lat, dist: c.dist, score: score)
            } else {
                // 진행방향 모르면 거리 우선
                return Cand(s: c.s, proj: 0, lateral: c.dist, dist: c.dist, score: -c.dist)
            }
        }
        .sorted { $0.score == $1.score ? $0.dist < $1.dist : $0.score > $1.score }

        // 4) 뒤쪽 후보 제거(소폭 오차 허용)
        let ahead = (dir != nil) ? ranked.filter { $0.proj >= aheadProjMin } : ranked

        // 5) “붙잡기(Sticky)” + “지나침” 판정
        let now = Date()
        let lastId = lastPredictedStopId[busId]

        var chosen: Cand? = ahead.first
        if let lastId,
           let cur = ahead.first(where: { $0.s.id == lastId }) {
            // (a) 지나침: 충분히 뒤로 갔다면 교체 허용
            let passed = cur.proj <= passBehindProj
            // (b) 기존 후보가 여전히 가까우면 유지
            let keepByNear = cur.dist <= keepSameIfNearMeters
            // (c) 점수 우위가 유의미하지 않으면 유지(히스테리시스)
            let best = ahead.first
            let betterByMargin = (best != nil) && ((best!.score - cur.score) >= switchMarginMeters)

            if !passed && (keepByNear || !betterByMargin) {
                chosen = cur
            } else {
                chosen = best
            }
        }

        // fallbackByName가 있고 현재 선택이 없다면 한 번 더 시도
        if chosen == nil, let name = fallbackByName {
            if let found = ranked.first(where: { name.contains($0.s.name) || $0.s.name.contains(name) }) {
                chosen = found
            }
        }

        guard let pick = chosen else { return (nil, nil) }

        // 6) ETA 계산(저속 바닥치 + 근거리 보정)
        let vObs = max(0.1, track.speedMps)
        let vForETA = max(1.5, vObs)             // 신호등 튐 방지 바닥치
        // 진행축 기준 전방 거리(음수면 실제 거리)
        let forwardMeters = max(0, pick.proj > 0 ? pick.proj : pick.dist)
        var etaSec = Int(forwardMeters / vForETA)
        if vObs < 1.2 && pick.dist < 25 { etaSec = 0 }
        let etaMin = max(0, Int((Double(etaSec)/60.0).rounded(.toNearestOrEven)))

        // 7) 최종 선택 기억(붙잡기)
        lastPredictedStopId[busId] = pick.s.id

        return (pick.s, etaMin)
    }



    // ⬇️ 이 메서드를 교체
    // ⬇️ 이 메서드를 교체
    // MapVM
    func onRegionCommitted(_ region: MKCoordinateRegion) {
        regionTask?.cancel()
        regionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000) // 0.15s
            guard let self else { return }
            if self.shouldReload(for: region) {
                self.lastRegion = region
                self.lastReloadAt = Date()
                // 최신 요청만 유지
                self.reloadTask?.cancel()
                self.reloadTask = Task { [weak self] in
                    await self?.reload(center: region.center)
                }
            }
        }
    }

    // MapVM 안에 추가
    private func nearestStops(from center: CLLocationCoordinate2D,
                              limit: Int = 4,
                              within meters: CLLocationDistance = 500) -> [BusStop] {
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return stops
            .map { stop -> (BusStop, CLLocationDistance) in
                let d = here.distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon))
                return (stop, d)
            }
            .filter { $0.1 <= meters }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }


    @MainActor
    func reload(center: CLLocationCoordinate2D) async {
        // 최신 요청만 반영하는 외부 취소는 onRegionCommitted에서 처리된다고 가정
        self.lastStopRefreshCenter = center

        // 1) 정류장: 실패하면 조용히 끝내되, 성공하면 즉시 화면에 반영
        do {
            let stops = try await api.fetchStops(lat: center.latitude, lon: center.longitude)
            self.stops = stops                         // ✅ 정류장 즉시 적용 (이후 단계 실패해도 유지)
        } catch {
            let ns = error as NSError
            if !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) {
                print("❌ stops error: \(error)")
            }
            // 정류장 없으면 더 진행할 의미가 없음
            self.latestTopArrivals = []
            self.buses = []
            return
        }

        // 2) 반경 500 m 인근 정류장 여러 개 추려서 상위 라우트 산출
        do {
            // 근처 후보(없으면 곧장 버스 비우고 종료)
            let candidateStops = nearestStops(from: center, limit: 4, within: 500)
            guard !candidateStops.isEmpty else {
                self.latestTopArrivals = []
                self.buses = []
                return
            }

            // 여러 정류장의 도착예정 수집 (ItemsFlex/OneOrMany로 안전 파싱)
            var allArrivals: [ArrivalInfo] = []
            try await withThrowingTaskGroup(of: [ArrivalInfo].self) { group in
                for s in candidateStops {
                    group.addTask { try await self.api.fetchArrivalsDetailed(cityCode: CITY_CODE, nodeId: s.id) }
                }
                while let arr = try await group.next() { allArrivals.append(contentsOf: arr) }
            }

            // ---------- ⬇️ 여기부터 '팔로우 노선 강제 포함' 로직 통합 ----------
            // 1) 라우트별 최소 ETA만 남기기 + 이번 회차 매핑 갱신
            routeIdByRouteNo.removeAll(keepingCapacity: true)
            var bestByRouteId: [String: ArrivalInfo] = [:]
            for a in allArrivals {
                // routeno -> routeId 매핑 업데이트
                routeIdByRouteNo[a.routeNo] = a.routeId
                lastKnownRouteIdByRouteNo[a.routeNo] = a.routeId   // 캐시에 누적

                if let cur = bestByRouteId[a.routeId] {
                    if a.etaMinutes < cur.etaMinutes { bestByRouteId[a.routeId] = a }
                } else {
                    bestByRouteId[a.routeId] = a
                }
            }

            var top = Array(bestByRouteId.values).sorted { $0.etaMinutes < $1.etaMinutes }

            // 2) 팔로우 중이면 그 버스 라우트를 반드시 포함
            if let fid = followBusId, let rno = routeNoById[fid] {
                let forcedRouteId =
                    routeIdByRouteNo[rno] ??            // 이번 회차에서 찾았거나
                    lastKnownRouteIdByRouteNo[rno]      // 과거 캐시에 있던 것(신호등/야간 대비)
                if let fr = forcedRouteId, !top.contains(where: { $0.routeId == fr }) {
                    // ETA는 임시값(기존 표시 유지용); 실제 위치가 오면 덮임
                    top.insert(.init(routeId: fr, routeNo: rno, etaMinutes: 3), at: 0)
                }
            }

            // 3) 너무 많으면 상한
            let TOP_ROUTE_LIMIT = 6
            top = Array(top.prefix(TOP_ROUTE_LIMIT))
            self.latestTopArrivals = top

            // 상위 라우트가 없으면(야간) 버스 목록만 비우고 종료 — 정류장은 그대로
            guard !top.isEmpty else {
                self.buses = []
                return
            }

            // 4) 상위 라우트들로 BusLoc 병렬 조회
            let etaByRoute = Dictionary(uniqueKeysWithValues: top.map { ($0.routeNo, $0.etaMinutes) })
            var mergedById: [String: BusLive] = [:]

            try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in top {
                    group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) }
                }
                while let arr = try await group.next() {
                    let enriched = arr.map { b -> BusLive in var m = b; m.etaMinutes = etaByRoute[m.routeNo]; return m }
                    let filtered = self.mergeAndFilter(enriched)
                    for b in filtered { self.routeNoById[b.id] = b.routeNo; mergedById[b.id] = b }
                    self.ensureFollowGhost(&mergedById)
                    self.buses = Array(mergedById.values)
                }
            }
            // ---------- ⬆️ 여기까지 ----------

            startAutoRefresh()
        } catch {
            // 네트워크 취소는 무시, 그 외는 로그만 — 정류장 갱신은 이미 화면에 남아있음
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            print("❌ arrivals/busloc error: \(error)")
            self.buses = []               // 야간/오류 시 버스만 비움 — 정류장은 유지
            self.latestTopArrivals = []
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

    // ⬇️ 교체
    private func refreshBusesOnly() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var top = latestTopArrivals

        // 팔로우 노선 강제 포함
        if let fid = followBusId, let rno = routeNoById[fid] {
            let forcedRouteId = routeIdByRouteNo[rno] ?? lastKnownRouteIdByRouteNo[rno]
            if let fr = forcedRouteId, !top.contains(where: { $0.routeId == fr }) {
                top.insert(.init(routeId: fr, routeNo: rno, etaMinutes: 3), at: 0)
            }
        }

        guard !top.isEmpty else {
            // 버스 응답이 비어도 팔로우 유령은 유지되도록 buses를 바로 비우지 않음
            var merged: [String: BusLive] = Dictionary(uniqueKeysWithValues: self.buses.map { ($0.id, $0) })
            self.ensureFollowGhost(&merged)
            self.buses = Array(merged.values)
            return
        }

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
                    for b in filtered { self.routeNoById[b.id] = b.routeNo; mergedById[b.id] = b }
                    self.ensureFollowGhost(&mergedById)
                    self.buses = Array(mergedById.values)
                }
            }
        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            print("❌ refresh error: \(error)")
            // 실패 시에도 팔로우 유령 유지
            var merged: [String: BusLive] = Dictionary(uniqueKeysWithValues: self.buses.map { ($0.id, $0) })
            self.ensureFollowGhost(&merged)
            self.buses = Array(merged.values)
        }
    }

    // MARK: - Filtering & snapping
    // MARK: - Filtering & snapping
    // MARK: - Filtering & snapping (adaptive jump accept)
    // MARK: - Filtering & snapping (route-aware + adaptive jump)
    private func mergeAndFilter(_ incoming: [BusLive]) -> [BusLive] {
        var out: [BusLive] = []

        // 합리적 최고 속도(144km/h), 팔로우 중 점프 허용 상한(1.2km)
        let MAX_PLAUSIBLE_MPS: Double = 40.0
        let FOLLOW_STEP_ALLOW_METERS: CLLocationDistance = 1_200

        for var b in incoming {
            let now = Date()
            let rawC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
            let isFollowed = (followBusId == b.id)

            if var tr = tracks[b.id] {
                // 직전 상태 기준 거리/시간
                let step = CLLocation(latitude: tr.lastLoc.latitude, longitude: tr.lastLoc.longitude)
                    .distance(from: CLLocation(latitude: rawC.latitude, longitude: rawC.longitude))
                let dt = max(0.01, now.timeIntervalSince(tr.lastAt))
                let instMps = step / dt

                // ===== 적응형 점프 허용 =====
                var acceptAsJump = false
                if step > maxStepMeters {
                    // 1) 팔로우 중이면 넉넉히 허용(최대 1.2km)
                    if isFollowed && step <= FOLLOW_STEP_ALLOW_METERS {
                        acceptAsJump = true
                    }
                    // 2) 속도 기준으로도 합리적이면 허용(장시간 폴링 공백 후 점프)
                    else if instMps <= MAX_PLAUSIBLE_MPS {
                        acceptAsJump = true
                    }
                }

                if step > maxStepMeters && !acceptAsJump {
                    // 비현실적 점프 → 이번 샘플 무시
                    continue
                }

                // EMA 스무딩(점프는 리셋에 가깝게 반영)
                let alpha: Double = acceptAsJump ? 0.9 : emaAlpha
                let lat = tr.lastLoc.latitude  * (1 - alpha) + rawC.latitude  * alpha
                let lon = tr.lastLoc.longitude * (1 - alpha) + rawC.longitude * alpha
                let smooth = CLLocationCoordinate2D(latitude: lat, longitude: lon)

                // 트랙 갱신 + 속도/방향 업데이트
                tr.prevLoc = tr.lastLoc
                tr.prevAt  = tr.lastAt
                tr.lastLoc = smooth
                tr.lastAt  = now
                tr.updateKinematics()
                tracks[b.id] = tr

                // 짧은 예측(Dead-reckoning)
                let pred = tr.predicted(at: now.addingTimeInterval(0.6))
                b.lat = pred.latitude
                b.lon = pred.longitude

                // ========= 여기부터: 노선 기반 → 휴리스틱 fallback =========

                // ① 노선 기반 다음 정류장 우선 시도
                var nextStopFromRouteList: BusStop? = nil
                if let rid = resolveRouteId(for: b.routeNo),
                   let rStops = routeStopsByRouteId[rid] {
                    nextStopFromRouteList = nextStopFromRoute(
                        busId: b.id,
                        busCoord: pred,
                        track: tr,
                        routeStops: rStops,
                        lastStopId: lastPredictedStopId[b.id]
                    )
                }

                // 휴리스틱(방향/반경)도 병행 계산해 둔다
                let (nextStopHeur, etaHeur) = nextStopAndETA(
                    busId: b.id,
                    coord: pred,
                    track: tr,
                    fallbackByName: b.nextStopName
                )

                // ② 최종 next/ETA 선택: 노선기반 우선, 없으면 휴리스틱
                let chosenStop: BusStop? = nextStopFromRouteList ?? nextStopHeur
                if let s = chosenStop { b.nextStopName = s.name }

                // 다음 정류장까지의 거리
                let distToNext: Double? = chosenStop.map { s in
                    GeoUtil.deltaMeters(
                        from: pred,
                        to: .init(latitude: s.lat, longitude: s.lon)
                    ).dist
                }

                // 원시 ETA 산출: 노선기반을 우선 사용, 없으면 휴리스틱 ETA
                let etaMinRaw: Int? = {
                    if chosenStop != nil, let d = distToNext {
                        // ETA 계산(저속 바닥치 + 근거리 보정)
                        let vObs = max(0.1, tr.speedMps)
                        let vForETA = max(1.5, vObs)
                        var sec = Int(d / vForETA)
                        if vObs < 1.2 && d < 25 { sec = 0 }
                        return max(0, Int((Double(sec)/60.0).rounded(.toNearestOrEven)))
                    } else {
                        return etaHeur
                    }
                }()

                // ETA 스무딩 적용
                b.etaMinutes = smoothETA(
                    rawETA: etaMinRaw,
                    busId: b.id,
                    distToNextStop: distToNext
                )

                // ========= 여기까지 =========

            } else {
                // 첫 관측: 트랙 생성(다음 루프부터 스무딩/예측)
                tracks[b.id] = BusTrack(prevLoc: nil, prevAt: nil, lastLoc: rawC, lastAt: now)
            }

            // 정류장 스냅/드웰 적용(정확히 붙이기)
            maybeSnapToStop(&b)

            out.append(b)
        }

        return out
    }


    // ⬇️ 이 메서드를 교체
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

        // 속도에 따라 스냅 반경 확장
        let speed: Double = {
            if let tr = tracks[b.id] { return tr.speedMps }
            return 0
        }()
        let baseRadius: CLLocationDistance = snapRadius          // 기존 18
        let slowBonus: CLLocationDistance = (speed < 1.0) ? 20 : (speed < 2.0 ? 10 : 0)
        let dwellBonus: CLLocationDistance = ((dwellUntil[b.id] ?? .distantPast) > Date()) ? 25 : 0
        let dynamicRadius = baseRadius + slowBonus + dwellBonus  // 보통 18~63m

        if d < dynamicRadius {
            // 정류장 체류 모드 시작/연장
            dwellUntil[b.id] = Date().addingTimeInterval(dwellSec)
            b.lat = stop.lat; b.lon = stop.lon
            b.nextStopName = stop.name
            b.etaMinutes = 0
        } else {
            // 반경 밖: 최근 업데이트가 없거나 dwell 만료되면 해제
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
                        v.updateAlwaysOnBubble()
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
                            mv.updateAlwaysOnBubble()
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
                v.updateAlwaysOnBubble()  // ⬅️ 말풍선 즉시 갱신
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
                parent.vm.followBusId = nil
                if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: false) }
            } else {
                parent.vm.followBusId = bus.id
                follow(bus, on: mapView)
                if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: true); mv.updateAlwaysOnBubble() }

                // ✅ 노선 정류장 목록 사전 로드
                Task { await self.parent.vm.onBusSelected(bus) }
            }

            mapView.deselectAnnotation(bus, animated: false)
        }


        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
//            if view is BusMarkerView {
//                UIView.animate(withDuration: 0.2) { view.transform = .identity }
//                // 버튼 라벨은 선택 해제와 무관 (토글은 didSelect/callout에서만)
//            }
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
                if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: true); mv.updateAlwaysOnBubble() }
                if let mv = view as? BusMarkerView, let btn = mv.rightCalloutAccessoryView as? UIButton { btn.setTitle("해제", for: .normal) }
            }
        }

        // 지도가 움직였을 때: 사용자 제스처가 아니더라도, 팔로우 중이면 주기적으로 정류장 재로딩
        // ClusteredMapView.Coord
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            deb.call(after: 0.25) {
                // ✅ 제스처/자동/팔로우 상관없이 항상 통지
                self.parent.vm.onRegionCommitted(mapView.region)
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
/// JSON에서 item이 단일 객체이든 배열이든 모두 수용
/// 배열 또는 단일 객체를 모두 수용
struct OneOrMany<Element: Decodable>: Decodable {
    let array: [Element]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let one = try? c.decode(Element.self) { array = [one] }
        else { array = try c.decode([Element].self) }
    }
}

/// items가 `{ "item": ... }` 이거나 `""`(빈 문자열) 이거나 `null` 이어도 OK
/// 배열/단일/빈문자열 모두 수용하는 items 디코더
struct ItemsFlex<Item: Decodable>: Decodable {
    let values: [Item]

    // ✅ 제네릭 타입은 init 바깥으로
    private struct Box<T: Decodable>: Decodable {
        let item: OneOrMany<T>?
    }

    init(from decoder: Decoder) throws {
        // 1) 단일값 컨테이너: null 또는 "" → 빈 배열
        if let sv = try? decoder.singleValueContainer() {
            if sv.decodeNil() || (try? sv.decode(String.self)) != nil {
                values = []
                return
            }
        }
        // 2) 정상 키드 경로: { "item": {...} } 또는 { "item": [ ... ] }
        if let box = try? Box<Item>(from: decoder) {
            values = box.item?.array ?? []
            return
        }
        // 3) 혹시 다른 변종이면 안전하게 빈 배열
        values = []
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
