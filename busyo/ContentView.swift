//
//  Busyo_SingleFile_FollowFix_StableList.swift
//  CITY_CODE=25 / 제스처 종료 후 1회 호출 / Arrivals→BusLoc / 클러스터링
//  + 버스=파랑, 정류장=빨강 / API 카운터 / 내 위치 버튼
//  + [FIX] 선택해도 다른 버스 안 사라짐(가시성 제거 → 데이터 기준 제거)
//  + [FIX] 선택 상태에서도 좌표 갱신/애니메이션 반영(KVO)
//  + [ADD] 말풍선에 “다음 정류장 · ETA분”
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
    // ✅ 수동 KVO 제거, CATransaction으로만 애니메이션
        func update(to b: BusLive) {
            subtitle = Self.makeSubtitle(eta: b.etaMinutes, next: b.nextStopName)
            let newC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
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

// MARK: - ViewModel
@MainActor
final class MapVM: ObservableObject {
    @Published var stops: [BusStop] = []
    @Published var buses: [BusLive] = []
    @Published var followBusId: String?

    private let api = BusAPI()
    private var lastRegion: MKCoordinateRegion?
    private var lastReloadAt: Date = .distantPast
    private var regionTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var latestTopArrivals: [ArrivalInfo] = []
    private var isRefreshing = false

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
            latestTopArrivals = Array(arrivals.prefix(5))

            let busArrays: [[BusLive]] = try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in latestTopArrivals { group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) } }
                var acc: [[BusLive]] = []; while let arr = try await group.next() { acc.append(arr) }; return acc
            }
            var merged = busArrays.flatMap { $0 }
            let etaByRoute = Dictionary(uniqueKeysWithValues: latestTopArrivals.map { ($0.routeNo, $0.etaMinutes) })
            merged = merged.map { var m = $0; m.etaMinutes = etaByRoute[m.routeNo]; return m }
            self.buses = merged

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
        guard !latestTopArrivals.isEmpty else { return }
        do {
            let busArrays: [[BusLive]] = try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in latestTopArrivals { group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) } }
                var acc: [[BusLive]] = []; while let arr = try await group.next() { acc.append(arr) }; return acc
            }
            var merged = busArrays.flatMap { $0 }
            let etaByRoute = Dictionary(uniqueKeysWithValues: latestTopArrivals.map { ($0.routeNo, $0.etaMinutes) })
            merged = merged.map { var m = $0; m.etaMinutes = etaByRoute[m.routeNo]; return m }
            self.buses = merged
        } catch { }
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
        // 내 위치로 이동(권한 없으면 스킵)
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

        // 정류장 동기화
        let existingStopAnnos = uiView.annotations.compactMap { $0 as? BusStopAnnotation }
        let existingStopIds = Set(existingStopAnnos.map { $0.stop.id })
        let desiredStopIds = Set(vm.stops.map { $0.id })
        let toAddStops = vm.stops.filter { !existingStopIds.contains($0.id) }.map { BusStopAnnotation($0) }
        if !toAddStops.isEmpty { uiView.addAnnotations(toAddStops) }
        let stopToRemove = existingStopAnnos.filter { !desiredStopIds.contains($0.stop.id) }
        if !stopToRemove.isEmpty { uiView.removeAnnotations(stopToRemove) }

        // 버스 동기화(데이터 기준)
        let existingBusAnnos = uiView.annotations.compactMap { $0 as? BusAnnotation }
        var byId = Dictionary(uniqueKeysWithValues: existingBusAnnos.map { ($0.id, $0) })
        let desiredBusIds = Set(vm.buses.map { $0.id })

        for b in vm.buses {
            if let anno = byId[b.id] {
                anno.update(to: b)
                byId.removeValue(forKey: b.id)
            } else {
                uiView.addAnnotation(BusAnnotation(bus: b))
            }
        }
        if !byId.isEmpty {
            let toRemove = byId.values.filter { leftover in
                if let sel = vm.followBusId, sel == leftover.id { return false }
                return !desiredBusIds.contains(leftover.id)
            }
            if !toRemove.isEmpty { uiView.removeAnnotations(toRemove) }
        }

        // 선택 버스 팔로우
        if let followId = vm.followBusId,
           let anno = uiView.annotations.first(where: { ($0 as? BusAnnotation)?.id == followId }) as? BusAnnotation {
            context.coordinator.follow(anno, on: uiView)
        }
    }

    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, MKMapViewDelegate {
        let parent: ClusteredMapView
        private let deb = Debouncer()
        private var isAutoRecentering = false
        init(_ p: ClusteredMapView) { parent = p }

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
            // 선택 해제 후에도 계속 따라가고 싶지 않다면 아래 주석 해제
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
