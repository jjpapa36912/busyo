//
//  Busyo_SingleFile_KVOFix.swift
//  CITY_CODE=25 고정 / 제스처 종료 후 1회 호출 / Arrivals→BusLoc / 버스 주기 갱신
//  ✅ KVO 크래시 방지: 수동 willChange/didChange 제거 + CATransaction 애니메이션
//  ✅ 버스 갱신 직렬화(겹침 방지)
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
private let MIN_RELOAD_DIST: CLLocationDistance = 250   // m
private let MIN_ZOOM_RATIO: CGFloat = 0.10              // 10%
private let REGION_COOLDOWN_SEC: Double = 6.0           // 제스처 종료 후 재호출 쿨다운
private let BUS_REFRESH_SEC: UInt64 = 10                // 버스 주기 갱신(초)

fileprivate extension String {
    var encodedForServiceKey: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self }
}
fileprivate func maskKey(_ k: String) -> String { k.count > 12 ? "\(k.prefix(6))...\(k.suffix(6))" : "****" }

// MARK: - Models

struct BusStop: Identifiable, Hashable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let cityCode: Int
}

struct BusLive: Identifiable, Hashable {
    let id: String        // vehicleno
    let routeNo: String
    var lat: Double
    var lon: Double
    var etaMinutes: Int?
}

struct ArrivalInfo: Identifiable, Hashable {
    let id = UUID()
    let routeId: String
    let routeNo: String
    let etaMinutes: Int
}

enum APIError: Error { case invalidURL, http(Int), decode(Error) }

// MARK: - Flexible Decoders

struct FlexString: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else { throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "Not a string/int/double")) }
    }
}
struct FlexInt: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let s = try? c.decode(String.self) { value = Int(s) }
        else { value = nil }
    }
}
struct FlexDouble: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self), let d = Double(s.replacingOccurrences(of: ",", with: "")) { value = d }
        else { throw DecodingError.typeMismatch(Double.self, .init(codingPath: decoder.codingPath, debugDescription: "Not a double/string")) }
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
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
            let k = name.lowercased(); if k == "item" { cur = [:] } else if cur != nil { key = k; buf = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { buf += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
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
        let p = XMLItemsParser(); let xp = XMLParser(data: data); xp.delegate = p
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
            ]
        )

        struct Root: Decodable {
            struct Resp: Decodable { let body: Body? }
            struct Body: Decodable { let items: Items? }
            struct Items: Decodable { let item: [Item]? }
            struct Item: Decodable {
                let nodeid: String; let nodenm: String; let citycode: Int
                let gpsLati: Double; let gpsLong: Double
                enum CodingKeys: String, CodingKey { case nodeid, nodenm, citycode, gpsLati, gpsLong, gpslati, gpslong }
                init(from d: Decoder) throws {
                    let c = try d.container(keyedBy: CodingKeys.self)
                    nodeid = try c.decode(String.self, forKey: .nodeid)
                    nodenm = try c.decode(String.self, forKey: .nodenm)
                    citycode = try c.decode(Int.self, forKey: .citycode)
                    gpsLati = try (c.decodeIfPresent(Double.self, forKey: .gpsLati) ?? c.decode(Double.self, forKey: .gpslati))
                    gpsLong = try (c.decodeIfPresent(Double.self, forKey: .gpsLong) ?? c.decode(Double.self, forKey: .gpslong))
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
                .map { .init(id: $0.nodeid, name: $0.nodenm, lat: $0.gpsLati, lon: $0.gpsLong, cityCode: $0.citycode) }
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
            ]
        )

        struct Root: Decodable {
            struct Resp: Decodable { let body: Body? }
            struct Body: Decodable { let items: Items? }
            struct Items: Decodable { let item: [Item]? }
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
            let r = try JSONDecoder().decode(Root.self, from: data)
            let items = r.response?.body?.items?.item ?? []
            return items.compactMap { i in
                guard let rid = i.routeid, let sec = i.arrtime?.value else { return nil }
                let rno = i.routeno?.value ?? "?"
                return .init(routeId: rid, routeNo: rno, etaMinutes: max(0, sec/60))
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
            ]
        )

        struct Root: Decodable {
            struct Resp: Decodable { let body: Body? }
            struct Body: Decodable { let items: Items? }
            struct Items: Decodable { let item: [Item]? }
            struct Item: Decodable {
                let vehicleno: String
                let routenm: FlexString?
                let routeno: FlexString?
                let gpsLati: FlexDouble
                let gpsLong: FlexDouble
                enum CodingKeys: String, CodingKey { case vehicleno, routenm, routeno, gpsLati, gpsLong, gpslati, gpslong }
                init(from d: Decoder) throws {
                    let c = try d.container(keyedBy: CodingKeys.self)
                    vehicleno = try c.decode(String.self, forKey: .vehicleno)
                    routenm   = try? c.decode(FlexString.self, forKey: .routenm)
                    routeno   = try? c.decode(FlexString.self, forKey: .routeno)
                    if let v = try? c.decode(FlexDouble.self, forKey: .gpsLati) { gpsLati = v }
                    else { gpsLati = try c.decode(FlexDouble.self, forKey: .gpslati) }
                    if let v = try? c.decode(FlexDouble.self, forKey: .gpsLong) { gpsLong = v }
                    else { gpsLong = try c.decode(FlexDouble.self, forKey: .gpslong) }
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
                return BusLive(id: veh, routeNo: r, lat: la, lon: lo, etaMinutes: nil)
            }
        } else {
            let r = try JSONDecoder().decode(Root.self, from: data)
            return (r.response?.body?.items?.item ?? []).map {
                BusLive(id: $0.vehicleno,
                        routeNo: $0.routenm?.value ?? $0.routeno?.value ?? "?",
                        lat: $0.gpsLati.value,
                        lon: $0.gpsLong.value,
                        etaMinutes: nil)
            }
        }
    }
}

// MARK: - Annotations & Views

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
        self.id = bus.id
        self.routeNo = bus.routeNo
        self.coordinate = .init(latitude: bus.lat, longitude: bus.lon)
        self.subtitle = bus.etaMinutes.map { "약 \($0)분" }
    }

    // ✅ 수동 KVO 호출 제거, CATransaction으로 좌표 애니메이션
    func update(to b: BusLive) {
        self.subtitle = b.etaMinutes.map { "약 \($0)분" }
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
        markerTintColor = .systemBlue
        titleVisibility = .visible
        subtitleVisibility = .visible
        animatesWhenAdded = true
        displayPriority = .required
    }
    required init?(coder: NSCoder) { fatalError() }
    override func prepareForDisplay() {
        super.prepareForDisplay()
        if let b = annotation as? BusAnnotation { glyphText = b.routeNo }
    }
}

// MARK: - VM

@MainActor
final class MapVM: ObservableObject {
    @Published var stops: [BusStop] = []
    @Published var buses: [BusLive] = []
    @Published var lastError: String?

    private let api = BusAPI()

    // 제스처-호출 관리
    private var lastRegion: MKCoordinateRegion?
    private var lastReloadAt: Date = .distantPast
    private var regionTask: Task<Void, Never>?

    // 주기 갱신(버스만)
    private var autoTask: Task<Void, Never>?
    private var focusStopId: String?
    private var latestTopArrivals: [ArrivalInfo] = []

    // ✅ 갱신 직렬화(겹침 방지)
    private var isRefreshingBuses = false

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
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s 디바운스
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
            self.focusStopId = focus.id

            var arrivals = try await api.fetchArrivalsDetailed(cityCode: CITY_CODE, nodeId: focus.id)
            arrivals.sort { $0.etaMinutes < $1.etaMinutes }
            let top = Array(arrivals.prefix(3))
            self.latestTopArrivals = top

            let busArrays: [[BusLive]] = try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in top { group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) } }
                var acc: [[BusLive]] = []; while let arr = try await group.next() { acc.append(arr) }; return acc
            }
            var merged = busArrays.flatMap { $0 }
            let etaByRoute = Dictionary(uniqueKeysWithValues: top.map { ($0.routeNo, $0.etaMinutes) })
            merged = merged.map { var m = $0; m.etaMinutes = etaByRoute[m.routeNo]; return m }

            if !merged.isEmpty { self.buses = merged } // 빈 응답이면 유지
            self.lastError = nil

            startAutoRefresh()
        } catch {
            self.lastError = (error as NSError).localizedDescription
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
        if isRefreshingBuses { return }    // ✅ 겹침 방지
        isRefreshingBuses = true
        defer { isRefreshingBuses = false }

        let top = latestTopArrivals
        guard !top.isEmpty else { return }
        do {
            let busArrays: [[BusLive]] = try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in top { group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) } }
                var acc: [[BusLive]] = []; while let arr = try await group.next() { acc.append(arr) }; return acc
            }
            var merged = busArrays.flatMap { $0 }
            let etaByRoute = Dictionary(uniqueKeysWithValues: top.map { ($0.routeNo, $0.etaMinutes) })
            merged = merged.map { var m = $0; m.etaMinutes = etaByRoute[m.routeNo]; return m }
            if !merged.isEmpty { self.buses = merged }
        } catch {
            // 네트워크 일시 오류는 무시
        }
    }
}

// MARK: - Map

private extension MKMapView {
    var isRegionChangeFromUserInteraction: Bool {
        guard let grs = subviews.first?.gestureRecognizers else { return false }
        return grs.contains { $0.state == .began || $0.state == .ended || $0.state == .changed }
    }
}

struct ClusteredMapView: UIViewRepresentable {
    @ObservedObject var vm: MapVM

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.region = .init(center: .init(latitude: 36.351, longitude: 127.385),
                           span: .init(latitudeDelta: 0.045, longitudeDelta: 0.045))
        map.pointOfInterestFilter = .includingAll
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "stop")
        map.register(BusMarkerView.self, forAnnotationViewWithReuseIdentifier: "bus")
        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // 정류장: 증분 추가
        let existingStops = Set(uiView.annotations.compactMap { ($0 as? BusStopAnnotation)?.stop.id })
        let toAddStops = vm.stops.filter { !existingStops.contains($0.id) }.map { BusStopAnnotation($0) }
        if !toAddStops.isEmpty { uiView.addAnnotations(toAddStops) }

        // 버스: 증분 업데이트 + 애니메이션 이동
        let current = uiView.annotations.compactMap { $0 as? BusAnnotation }
        var byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let targetIds = Set(vm.buses.map { $0.id })

        for b in vm.buses {
            if let anno = byId[b.id] {
                anno.update(to: b)                  // ✅ KVO 안전 애니메이션 갱신
                byId.removeValue(forKey: b.id)
            } else {
                uiView.addAnnotation(BusAnnotation(bus: b))
            }
        }

        // 남은(=사라진) 애노테이션 제거는 살짝 지연해, 업데이트 중 KVO 해제 경합을 회피
        if !byId.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // 혹시 최신 타깃에 다시 포함되었으면 남겨둔다
                let toRemove = byId.values.filter { !targetIds.contains($0.id) }
                if !toRemove.isEmpty { uiView.removeAnnotations(toRemove) }
            }
        }
    }

    func makeCoordinator() -> Coord { Coord(self) }
    final class Coord: NSObject, MKMapViewDelegate {
        let parent: ClusteredMapView
        private let deb = Debouncer()
        init(_ p: ClusteredMapView) { self.parent = p }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard mapView.isRegionChangeFromUserInteraction else { return }
            deb.call(after: 0.5) { self.parent.vm.onRegionCommitted(mapView.region) }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let s = annotation as? BusStopAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "stop", for: s) as! MKMarkerAnnotationView
                v.clusteringIdentifier = "stop"
                v.glyphText = "🚏"
                v.markerTintColor = .systemGray
                v.displayPriority = .defaultHigh
                v.titleVisibility = .adaptive
                return v
            } else if let b = annotation as? BusAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "bus", for: b) as! BusMarkerView
                v.clusteringIdentifier = "bus"
                return v
            }
            return nil
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

// MARK: - Screen

struct BusMapScreen: View {
    @StateObject private var vm = MapVM()
    var body: some View {
        ClusteredMapView(vm: vm)
            .ignoresSafeArea()
            .task { await vm.reload(center: .init(latitude: 36.351, longitude: 127.385)) }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("정류장 \(vm.stops.count)  버스 \(vm.buses.count)")
                        .font(.caption).padding(6).background(.ultraThinMaterial).cornerRadius(8)
                    if let e = vm.lastError {
                        Text("⚠️ \(e)").font(.caption2).padding(6).background(.ultraThinMaterial).cornerRadius(8)
                    }
                }.padding()
            }
    }
}
