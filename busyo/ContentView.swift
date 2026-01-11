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
import simd
import GoogleMobileAds
import Combine
import Foundation

extension Notification.Name {
    static let stopAlertOpened = Notification.Name("stopAlertOpened")
}

// MARK: - App
@main
struct BusyoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var vm = MapVM()

    var body: some Scene {
        WindowGroup {
            BusMapScreen()                // ← 화면 루트
                .environmentObject(vm)    // ← 전역 공유
                .onAppear { AppNavigator.shared.bind(vm: vm) }
                
        }
    }
}
struct UpcomingStopETA: Identifiable {
    let id: String
    let name: String
    let etaMin: Int
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
//struct ArrivalInfo: Identifiable, Hashable { let id = UUID(); let routeId: String; let routeNo: String; let etaMinutes: Int }
struct ArrivalInfo: Identifiable, Hashable {
    let id = UUID()
    let routeId: String
    let routeNo: String
    let etaMinutes: Int
    var destination: String? = nil   // 패널에서 쓸 수 있게(옵션)
}

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
private extension URLResponse {
    var responseCode: Int { (self as? HTTPURLResponse)?.statusCode ?? -1 }
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
    // 노선 경로(위경도 점열) 조회
    func fetchRoutePath(cityCode: Int, routeId: String) async throws -> [CLLocationCoordinate2D] {
        // 국토부: BusRouteInfoInqireService/getRoutePathList
        let url = try urlWithEncodedKey(
            base: "https://apis.data.go.kr/1613000/BusRouteInfoInqireService/getRoutePathList",
            items: [
                .init(name: "pageNo", value: "1"),
                .init(name: "numOfRows", value: "1000"),
                .init(name: "_type", value: "json"),
                .init(name: "type", value: "json"),
                .init(name: "cityCode", value: String(cityCode)),
                .init(name: "routeId", value: routeId)
            ])

        struct Root: Decodable {
            struct Resp: Decodable { let body: Body? }
            struct Body: Decodable { let items: ItemsFlex<Item>? }
            struct Item: Decodable {
                let gpsLati: FlexDouble?
                let gpsLong: FlexDouble?
                enum CodingKeys: String, CodingKey { case gpsLati, gpsLong, gpslati, gpslong }
                init(from d: Decoder) throws {
                    let c = try d.container(keyedBy: CodingKeys.self)
                    gpsLati = (try? c.decode(FlexDouble.self, forKey: .gpsLati)) ?? (try? c.decode(FlexDouble.self, forKey: .gpslati))
                    gpsLong = (try? c.decode(FlexDouble.self, forKey: .gpsLong)) ?? (try? c.decode(FlexDouble.self, forKey: .gpslong))
                }
            }
            let response: Resp?
        }

        let (data, _) = try await send("RoutePath", url: url)
        if isLikelyXML(data) {
            let arr = try parseXMLItems(data)
            return arr.compactMap { d in
                guard let la = toDouble(d["gpslati"]) ?? toDouble(d["gpsLati"]),
                      let lo = toDouble(d["gpslong"]) ?? toDouble(d["gpsLong"]) else { return nil }
                return .init(latitude: la, longitude: lo)
            }
        } else {
            let r = try JSONDecoder().decode(Root.self, from: data)
            let items = r.response?.body?.items?.values ?? []
            return items.compactMap {
                guard let la = $0.gpsLati?.value, let lo = $0.gpsLong?.value else { return nil }
                return .init(latitude: la, longitude: lo)
            }
        }
    }
    // 대전시: 노선별 버스 위치
        func fetchBusLocationsDaejeon(routeId: String) async throws -> [BusLive] {
            // 보통 기능명 붙여 호출: .../busposinfo/getBusPosByRtid
            guard var comps = URLComponents(string: "https://openapittraffic.daejeon.go.kr/api/rest/busposinfo/getBusPosByRtid") else {
                throw APIError.invalidURL
            }
            comps.queryItems = [
                URLQueryItem(name: "serviceKey", value: serviceKeyRaw.encodedForServiceKey),  // ✅ Encoding 키
                URLQueryItem(name: "busRouteId", value: routeId)
            ]
            guard let url = comps.url else { throw APIError.invalidURL }

            let (data, _) = try await send("BusLoc(DJ)", url: url)

            // XML only → 기존 XMLItemsParser 재사용
            let arr = try parseXMLItems(data)

            // 필드명이 지역별로 조금씩 달라 확장적으로 파싱
            // 흔한 케이스: vehicleno, routeno, nodeNm / gpsX,gpsY 또는 wgs84Lon,wgs84Lat, gpsLong,gpsLati
            func dbl(_ d: [String:String], _ keys: [String]) -> Double? {
                for k in keys { if let v = d[k] ?? d[k.lowercased()], let x = Double(v) { return x } }
                return nil
            }
            func str(_ d: [String:String], _ keys: [String]) -> String? {
                for k in keys { if let v = d[k] ?? d[k.lowercased()], !v.isEmpty { return v } }
                return nil
            }

            return arr.compactMap { d in
                let veh = str(d, ["vehicleno","carNo","carno"]) ?? ""
                let rno = str(d, ["routeno","routenm","routeNo","routeNm"]) ?? "?"
                let lat = dbl(d, ["gpsLati","gpsY","wgs84Lat","lat"])
                let lon = dbl(d, ["gpsLong","gpsX","wgs84Lon","lon"])
                guard !veh.isEmpty, let la = lat, let lo = lon else { return nil }
                let nextNm = str(d, ["nodeNm","nodenm","nextStop","stationNm"])
                return BusLive(id: veh, routeNo: rno, lat: la, lon: lo, etaMinutes: nil, nextStopName: nextNm)
            }
        }
    // BusAPI 안에 추가
    // 대전시: 노선별 정류장 목록 조회 (routeId: DJB...)
    func fetchStopsByRouteDaejeon(routeId: String) async throws -> [BusStop] {
        // 흔한 엔드포인트명: /busRouteInfo/getStaionByRtid
        // (공식 명칭 오타 'Staion'인 곳이 실제로 많음)
        guard var comps = URLComponents(string: "https://openapittraffic.daejeon.go.kr/api/rest/busRouteInfo/getStaionByRtid") else {
            throw APIError.invalidURL
        }
        comps.queryItems = [
            .init(name: "serviceKey", value: serviceKeyRaw.encodedForServiceKey),
            .init(name: "busRouteId", value: routeId)
        ]
        guard let url = comps.url else { throw APIError.invalidURL }

        let (data, _) = try await send("RouteStops(DJ)", url: url)

        // XML only → 기존 XML 파서 재사용
        let arr = try parseXMLItems(data)

        // 지역별로 키가 제각각일 수 있어 확장 파서 사용
        func dbl(_ d: [String:String], _ keys: [String]) -> Double? {
            for k in keys { if let v = d[k] ?? d[k.lowercased()], let x = Double(v) { return x } }
            return nil
        }
        func str(_ d: [String:String], _ keys: [String]) -> String? {
            for k in keys { if let v = d[k] ?? d[k.lowercased()], !v.isEmpty { return v } }
            return nil
        }

        // 자주 보이는 필드 예:
        // • nodeid / nodenm
        // • gpsX/gpsY   또는   wgs84Lon/wgs84Lat   또는   gpsLong/gpsLati
        return arr.compactMap { d in
            guard
                let id   = str(d, ["nodeid","stationId","stopId"]),
                let name = str(d, ["nodenm","stationNm","stopNm"]),
                let lat  = dbl(d, ["gpsY","wgs84Lat","gpsLati","lat"]),
                let lon  = dbl(d, ["gpsX","wgs84Lon","gpsLong","lon"])
            else { return nil }
            return BusStop(id: id, name: name, lat: lat, lon: lon, cityCode: CITY_CODE)
        }
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

    func send(_ name: String, url: URL) async throws -> (Data, HTTPURLResponse) {
           Telemetry.shared.mark(.fetchArrivalsBegin, tags:["name":name])
           let t0 = Date()
           do {
               let (data, resp) = try await URLSession.shared.data(from: url)
               let ms = Date().timeIntervalSince(t0) * 1000
               Telemetry.shared.mark(.fetchArrivalsEnd, tags:["name":name, "code":"\(resp.responseCode)"], fields:["ms": ms])
               return (data, resp as! HTTPURLResponse)
           } catch {
               let ms = Date().timeIntervalSince(t0) * 1000
               Telemetry.shared.mark(.error, tags:["where":"send", "name":name], fields:["ms": ms])
               throw error
           }
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
    // 1) 근처 정류장 (BusAPI 내부 함수라고 가정)
    // - center.latitude/longitude → 파라미터 lat/lon 사용
    // - api.fetchStops(...) 자기 자신/순환 호출 제거
    // - Telemetry: Begin → time(...)으로 End 계측
    func fetchStops(lat: Double, lon: Double) async throws -> [BusStop] {
        Telemetry.shared.mark(.fetchStopsBegin, tags: ["fn": "fetchStops"])

        return try await Telemetry.shared.time(.fetchStopsEnd, tags: ["fn": "fetchStops"]) {
            let url = try urlWithEncodedKey(
                base: "https://apis.data.go.kr/1613000/BusSttnInfoInqireService/getCrdntPrxmtSttnList",
                items: [
                    .init(name: "pageNo", value: "1"),
                    .init(name: "numOfRows", value: "200"),
                    .init(name: "_type", value: "json"),
                    .init(name: "type", value: "json"),
                    .init(name: "gpsLati", value: "\(lat)"),   // ✅ 입력 파라미터 사용
                    .init(name: "gpsLong", value: "\(lon)")    // ✅ 입력 파라미터 사용
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
                    enum CodingKeys: String, CodingKey {
                        case nodeid, nodenm, citycode, gpsLati, gpsLong, gpslati, gpslong
                    }
                    init(from d: Decoder) throws {
                        let c = try d.container(keyedBy: CodingKeys.self)
                        nodeid = try c.decode(String.self, forKey: .nodeid)
                        nodenm = try c.decode(String.self, forKey: .nodenm)
                        citycode = try c.decode(Int.self, forKey: .citycode)
                        // 대소문자 변종 모두 수용
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
                // XML 변종 처리
                let arr = try parseXMLItems(data)
                return arr.compactMap { d in
                    guard
                        let id   = d["nodeid"],
                        let name = d["nodenm"],
                        let city = toInt(d["citycode"]),
                        let la   = toDouble(d["gpslati"]) ?? toDouble(d["gpsLati"]),
                        let lo   = toDouble(d["gpslong"]) ?? toDouble(d["gpsLong"])
                    else { return nil }
                    return .init(id: id, name: name, lat: la, lon: lo, cityCode: city)
                }
                .filter { $0.cityCode == CITY_CODE }
            } else {
                // JSON 정상 처리
                let r = try JSONDecoder().decode(Root.self, from: data)
                return (r.response?.body?.items?.item ?? [])
                    .filter { $0.citycode == CITY_CODE }
                    .compactMap {
                        guard let la = $0.gpsLati?.value, let lo = $0.gpsLong?.value else { return nil }
                        return .init(id: $0.nodeid, name: $0.nodenm, lat: la, lon: lo, cityCode: $0.citycode)
                    }
            }
        }
    }


    // 2) 정류장 ETA
    func fetchArrivalsDetailed(cityCode: Int, nodeId: String) async throws -> [ArrivalInfo] {
        // 텔레메트리: 시작
        Telemetry.shared.mark(.fetchArrivalsBegin, tags: ["fn": "fetchArrivalsDetailed"])

        return try await Telemetry.shared.time(.fetchArrivalsEnd, tags: ["fn": "fetchArrivalsDetailed"]) {
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

            // JSON 스키마: items가 단일/배열/빈문자열 모두 올 수 있으니 ItemsFlex 사용
            struct Root: Decodable {
                struct Resp: Decodable { let body: Body? }
                struct Body: Decodable { let items: ItemsFlex<Item>? }
                struct Item: Decodable {
                    let routeid: String?
                    let routeno: FlexString?
                    let arrtime: FlexInt?
                }
                let response: Resp?
            }

            let (data, _) = try await send("Arrivals", url: url)

            if isLikelyXML(data) {
                // XML 변종
                let arr = try parseXMLItems(data)
                return arr.compactMap { d in
                    guard
                        let rid = d["routeid"],
                        let rno = d["routeno"],
                        let sec = toInt(d["arrtime"])
                    else { return nil }
                    return .init(routeId: rid, routeNo: rno, etaMinutes: max(0, sec / 60))
                }
            } else {
                // JSON
                let r = try JSONDecoder().decode(Root.self, from: data)
                let items = r.response?.body?.items?.values ?? []
                return items.compactMap { i in
                    guard let rid = i.routeid, let sec = i.arrtime?.value else { return nil }
                    return .init(routeId: rid, routeNo: i.routeno?.value ?? "?", etaMinutes: max(0, sec / 60))
                }
            }
        }
    }

    func fetchBusLocations(cityCode: Int, routeId: String) async throws -> [BusLive] {
        // 텔레메트리: 시작
        Telemetry.shared.mark(.fetchBusLocBegin, tags: ["fn": "fetchBusLocations"])

        return try await Telemetry.shared.time(.fetchBusLocEnd, tags: ["fn": "fetchBusLocations"]) {
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

            // JSON 스키마: items가 단일/배열/빈문자열 모두 올 수 있으니 ItemsFlex 사용
            struct Root: Decodable {
                struct Resp: Decodable { let body: Body? }
                struct Body: Decodable { let items: ItemsFlex<Item>? }
                struct Item: Decodable {
                    let vehicleno: String
                    let routenm: FlexString?
                    let routeno: FlexString?
                    let gpsLati: FlexDouble?
                    let gpsLong: FlexDouble?
                    let nodenm: FlexString?

                    enum CodingKeys: String, CodingKey {
                        case vehicleno, routenm, routeno, gpsLati, gpsLong, gpslati, gpslong, nodenm
                    }
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
                // XML 변종
                let arr = try parseXMLItems(data)
                return arr.compactMap { d in
                    guard
                        let veh = d["vehicleno"],
                        let r   = d["routenm"] ?? d["routeno"],
                        let la  = toDouble(d["gpslati"]) ?? toDouble(d["gpsLati"]),
                        let lo  = toDouble(d["gpslong"]) ?? toDouble(d["gpsLong"])
                    else { return nil }
                    return BusLive(
                        id: veh,
                        routeNo: r,
                        lat: la, lon: lo,
                        etaMinutes: nil,
                        nextStopName: d["nodenm"]
                    )
                }
            } else {
                // JSON
                let r = try JSONDecoder().decode(Root.self, from: data)
                let items = r.response?.body?.items?.values ?? []
                return items.compactMap {
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

    
    
    private enum WireFormat { case json, xml, text, unknown }

    // HTTP 헤더 값 얻기(대/소문자 무시)
    private func header(_ resp: HTTPURLResponse, _ name: String) -> String? {
        for (k, v) in resp.allHeaderFields {
            if String(describing: k).lowercased() == name.lowercased() {
                return String(describing: v)
            }
        }
        return nil
    }

    // 응답 포맷 스니핑
    private func sniffFormat(data: Data, resp: HTTPURLResponse) -> WireFormat {
        if let ct = header(resp, "Content-Type")?.lowercased() {
            if ct.contains("json") { return .json }
            if ct.contains("xml")  { return .xml }
            if ct.contains("html") || ct.contains("text") { return .text }
        }
        guard let s0 = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return .unknown }
        if s0.hasPrefix("{") || s0.hasPrefix("[") { return .json }
        if s0.hasPrefix("<") || s0.lowercased().hasPrefix("<?xml") { return .xml }
        if s0.lowercased().hasPrefix("forbidden")
            || s0.lowercased().contains("service key")
            || s0.lowercased().contains("unauthorized")
            || s0.lowercased().contains("인증") { return .text }
        return .unknown
    }

    // 응답 앞부분 미리보기(로그용)
    private func peek(_ data: Data, limit: Int = 300) -> String {
        let s = String(data: data, encoding: .utf8) ?? "<non-utf8 bytes: \(data.count)b>"
        return String(s.prefix(limit)).replacingOccurrences(of: "\n", with: " ")
    }

    // JSON 디코딩(실패 시 원문 피크 로그)
    private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data, name: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            print("❌ [\(name)] JSON decode failed. peek=\(peek(data))")
            throw APIError.decode(error as NSError)
        }
    }

    // 서비스 키 마스킹(로그용) — 없으면 추가
    private func maskKey(_ s: String) -> String {
        guard s.count > 8 else { return "******" }
        let head = s.prefix(4), tail = s.suffix(4)
        return "\(head)****\(tail)"
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

    // 콜아웃/라벨용 캐시
    private(set) var nextStopName: String?
    private(set) var etaMinutes: Int?

    // ✅ MapKit KVO용: dynamic만, will/didChange 직접 호출 금지
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { routeNo }

    // subtitle은 수동 KVO(다음 런루프)로 유지해도 OK (MapKit이 직접 관찰 안함)
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

    // subtitle은 다음 런루프에서만 KVO 알림 (MapKit 내부 열거와 충돌 방지)
    private func setSubtitle(_ s: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.willChangeValue(forKey: "subtitle")
            self.subtitleStorage = s
            self.didChangeValue(forKey: "subtitle")
        }
    }

    // ✅ 모델만 업데이트할 때도 will/didChange 금지. 그냥 대입.
    @MainActor
    func applyModelOnly(_ live: BusLive) {
        // 좌표 대입 (메인 스레드)
        coordinate = CLLocationCoordinate2D(latitude: live.lat, longitude: live.lon)
        // 캐시만 갱신
        nextStopName = live.nextStopName
        etaMinutes   = live.etaMinutes
        // subtitle 갱신은 필요 시 뷰 단계에서만
    }

    // ✅ 전체 업데이트(애니메이션 포함): will/did 없이 coordinate 직접 대입
    @MainActor
    func update(to b: BusLive) {
        nextStopName = b.nextStopName
        etaMinutes   = b.etaMinutes
        setSubtitle(Self.makeSubtitle(eta: b.etaMinutes, next: b.nextStopName))

        let newC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        coordinate = newC
        CATransaction.commit()
    }

    // (선택) VM과 연동 버전
    @MainActor
    func update(to b: BusLive, vm: MapVM) {
        update(to: b)
        vm.updateHighlightStop(for: b)
    }
}



// 기존 BusMarkerView 전체 교체
final class BusMarkerView: MKMarkerAnnotationView {
    private let bubble = UIView()
    private let bubbleLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

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

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        bubble.layer.cornerRadius = 6
        bubble.layer.masksToBounds = true

        bubbleLabel.translatesAutoresizingMaskIntoConstraints = false
        bubbleLabel.font = .systemFont(ofSize: 11)
        bubbleLabel.textColor = .label
        bubbleLabel.numberOfLines = 1
        bubbleLabel.adjustsFontSizeToFitWidth = true
        bubbleLabel.minimumScaleFactor = 0.7
        bubbleLabel.lineBreakMode = .byTruncatingTail

        addSubview(bubble)
        bubble.addSubview(bubbleLabel)

        NSLayoutConstraint.activate([
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
        setNeedsLayout(); layoutIfNeeded()
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
struct BusTrack {
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
    // ADD: routeNo -> routeId thin wrapper
    func routeId(forRouteNo routeNo: String) -> String? {
        return resolveRouteId(for: routeNo)
    }

    // ADD: 누적거리 테이블에서 s 이하 마지막 인덱스
    private func vertexIndex(forS s: Double, in cumul: [Double]) -> Int {
        guard !cumul.isEmpty else { return 0 }
        if s <= cumul[0] { return 0 }
        if s >= cumul.last! { return max(0, cumul.count - 1) }

        var lo = 0, hi = cumul.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) >> 1
            if cumul[mid] <= s { lo = mid } else { hi = mid }
        }
        return lo
    }

    // ADD: 중복요청/쿨다운 가드
    private var metaInFlight = Set<String>()
    private var metaCooldownUntil = [String: Date]()
    private func isCoolingDown(_ id: String) -> Bool {
        if let until = metaCooldownUntil[id] { return until > Date() }
        return false
    }
    private func startCooldown(_ id: String, minutes: Int = 15) {
        metaCooldownUntil[id] = Date().addingTimeInterval(Double(minutes) * 60)
    }
    private func clearCooldown(_ id: String) { metaCooldownUntil[id] = nil }

    // ADD: 정류장 좌표만 잇는 미래경로
    func setFutureRouteByStops(
        meta: RouteMeta,
        from prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double),
        nextIdx: Int,
        maxAheadStops: Int = 7,
        includeTerminal: Bool = true
    ) {
        var coords: [CLLocationCoordinate2D] = [prj.snapped]

        guard nextIdx < meta.stopCoords.count else {
            futureRouteCoords.removeAll()
            futureRouteVersion &+= 1
            return
        }
        var end = min(meta.stopCoords.count - 1, nextIdx + maxAheadStops - 1)
        if !includeTerminal, end == meta.stopCoords.count - 1 {
            end = max(nextIdx, end - 1)
        }
        if nextIdx <= end {
            coords.append(contentsOf: meta.stopCoords[nextIdx...end])
        }
        if coords.count >= 2 {
            futureRouteCoords = coords
        } else {
            futureRouteCoords.removeAll()
        }
        futureRouteVersion &+= 1
    }
    
    
//    ======================
    
    
    
    
    static let shared = MapVM()   // ✅ 싱글턴 인스턴스

    @Published var stops: [BusStop] = []
    @Published var buses: [BusLive] = []
    @Published var followBusId: String?
    // 게이트/진행도 히스테리시스용 상태
    private var lastNextStopIndexByBusId: [String: Int] = [:]
    private var lastProgressSByBusId:    [String: Double] = [:]
    private var passStreakByBusId:       [String: Int] = [:]
    // MapVM 안에 추가
    private var lastETAMinByBusId: [String: Int] = [:]
    // MapVM 안에 추가
    private var lastSByBusId: [String: Double] = [:]        // 마지막 진행거리 s
    private var lastStopIdByBusId: [String: String] = [:]   // 마지막으로 고른 nextStop


    // MapVM 프로퍼티에 추가
    // routeNo -> (숫자)routeId 캐시 (국토부 메타용)
    private var numericRouteIdByRouteNo: [String: String] = [:]

    // routeId(숫자 or DJB) -> routeNo 역방향 캐시 (follow/메타 추적용)
    private var routeNoByRouteId: [String: String] = [:]


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
//    static let shared = MapVM()   // ✅ 싱글톤 접근 (AppDelegate에서 호출할 수 있도록)

//       func stopById(_ id: String) -> BusStop? {
//           return stops.first { $0.id == id }
//       }
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
    // MapVM 프로퍼티에 추가
    private var kfByBusId: [String: KF1D.State] = [:]
    private var kf = KF1D()
    // MapVM 클래스 맨 위 @Published 모음 근처에 추가
    @Published var stickToFollowedBus: Bool = false
    
    // MapVM 내부
    @Published var focusStop: BusStop? = nil              // 현재 정보 패널에 띄울 정류소
    @Published var focusStopETAs: [ArrivalInfo] = []      // 해당 정류소의 ETA 전체(스냅샷)
    @Published var focusStopLoading: Bool = false

//    @MainActor
//    func setFocusStop(_ stop: BusStop?) {
//        focusStop = stop
//        focusStopETAs = []
//    }

    
//    
//    func refreshFocusStopETA() async {
//        if Date().timeIntervalSince(lastRefreshAt) < minRefreshInterval { return }
//            lastRefreshAt = Date()
//        guard let s = focusStop else { return }
//        await MainActor.run { self.focusStopLoading = true }
//        do {
//            let arr = try await api.fetchArrivalsDetailed(cityCode: CITY_CODE, nodeId: s.id)
//            // 보기 좋게 정렬: 가장 빠른 ETA 순, 동일 노선끼리 묶임 유지
//            let sorted = arr.sorted { $0.etaMinutes < $1.etaMinutes }
//            await MainActor.run {
//                self.focusStopETAs = sorted
//                self.focusStopLoading = false
//            }
//        } catch {
//            await MainActor.run {
//                self.focusStopETAs = []
//                self.focusStopLoading = false
//            }
//        }
//    }

    // 알람 본문에 넣을 ETA 요약 문자열 (스냅샷)
    func focusETACompactSummary(maxPerRoute: Int = 2) -> String {
        guard !focusStopETAs.isEmpty else { return "ETA 정보 없음" }
        // routeNo별 상위 N개 ETA만
        let grouped = Dictionary(grouping: focusStopETAs, by: { $0.routeNo })
        let parts = grouped.keys.sorted().map { rno in
            let mins = (grouped[rno] ?? []).prefix(maxPerRoute).map { "\($0.etaMinutes)분" }.joined(separator: ",")
            return "\(rno): \(mins)"
        }
        return parts.joined(separator: " • ")
    }
// 팔로우 시 자동 재센터링 여부 (기본: 꺼짐)

    // ✅ 선택된 정류장 영속 저장
       @Published private(set) var selectedStopIds: Set<String> = []
       private let selectedStopsKey = "busyo.selectedStopIds"

//       init() {
//           loadSelectedStops()
//       }

       private func loadSelectedStops() {
           if let arr = UserDefaults.standard.array(forKey: selectedStopsKey) as? [String] {
               selectedStopIds = Set(arr)
           }
       }

       private func persistSelectedStops() {
           UserDefaults.standard.set(Array(selectedStopIds), forKey: selectedStopsKey)
       }

       func isStopSelected(_ id: String) -> Bool { selectedStopIds.contains(id) }

       func toggleStopSelection(_ id: String) {
           if selectedStopIds.contains(id) { selectedStopIds.remove(id) }
           else { selectedStopIds.insert(id) }
           persistSelectedStops()
           // 지도(주석 색상) 반영될 수 있도록 퍼블리시
           objectWillChange.send()
       }
    // MapVM 안에 추가
    private var lastETA: [String: (eta: Int, at: Date)] = [:]
    // MapVM 프로퍼티 (캐시)
    private var routeStopsByRouteId: [String: [BusStop]] = [:]
    // ✅ epoch 게이팅
       private var epochCounter: UInt64 = 0
       private var latestAppliedEpoch: UInt64 = 0
    // MapVM.swift

    // MapVM.swift (클래스 맨 위 @Published 모음 근처)
    // MapVM 내부에 추가

    @Published var futureRouteCoords: [CLLocationCoordinate2D] = []   // ▶ 미래(앞으로 갈) 경로
    @Published var highlightedStopId: String?                         // ▶ 노란 하이라이트 정류장

    // MapVM 안 (프로퍼티들 근처)
    @Published var futureRouteVersion: Int = 0
    
    // 🔸 알람 걸린 정류소 id 저장소 (디스크에 유지)
        @Published private(set) var alarmedStopIds: Set<String> = []
        private let alarmedKey = "alarmedStopIds.v1"

    init() { loadAlarmedStopIds() }

        // MARK: - 알람 persist
        private func loadAlarmedStopIds() {
            if let arr = UserDefaults.standard.array(forKey: alarmedKey) as? [String] {
                alarmedStopIds = Set(arr)
            }
        }
        private func saveAlarmedStopIds() {
            UserDefaults.standard.set(Array(alarmedStopIds), forKey: alarmedKey)
        }
        func setAlarmed(_ on: Bool, stopId: String) {
            if on { alarmedStopIds.insert(stopId) } else { alarmedStopIds.remove(stopId) }
            saveAlarmedStopIds()
        }
        func clearAllAlarms() {
            alarmedStopIds.removeAll()
            saveAlarmedStopIds()
        }

        // MARK: - 포커스/ETA
    func setFocusStop(_ stop: BusStop?) {
            self.focusStop = stop
            self.highlightedStopId = stop?.id
        }
    func clearFocusStop() {
            self.focusStop = nil
            self.highlightedStopId = nil
        }
        func stopById(_ id: String) -> BusStop? {
            // your storage 이름에 맞게 교체 (stops, stopsById 등)
            return stops.first(where: { $0.id == id })
        }

   

    func refreshFocusStopETA() async {
        guard let s = focusStop else { return }

        focusStopLoading = true
        defer { focusStopLoading = false }

        do {
            // 국토부 API 호출 (CITY_CODE = 25 대전)
            let arr = try await api.fetchArrivalsDetailed(cityCode: CITY_CODE, nodeId: s.id)

            // 보기 좋게 정렬 + 필요시 중복(routeId) 최소 ETA만 남기기
            // (원하면 그대로 두고 단순 정렬만 해도 됩니다)
            let bestByRouteId = Dictionary(grouping: arr, by: { $0.routeId })
                .compactMapValues { $0.min(by: { $0.etaMinutes < $1.etaMinutes }) }
            let sorted = Array(bestByRouteId.values).sorted { $0.etaMinutes < $1.etaMinutes }

            self.focusStopETAs = sorted
        } catch {
            // 실패 시 빈 목록로 처리
            self.focusStopETAs = []
            print("❌ refreshFocusStopETA error: \(error)")
        }
    }

        // 알림 본문 요약
        func focusETACompactSummary() -> String {
            guard !focusStopETAs.isEmpty else { return "도착 정보 없음" }
            let parts = focusStopETAs.prefix(5).map { "\($0.routeNo) \($0.etaMinutes)분" }
            return parts.joined(separator: " · ")
        }
    // 현재 좌표와 (가능하면) 추정 진행방향으로 임시 빨간선(직선) 그리기
    func setTemporaryFutureRouteFromBus(busId: String, coordinate: CLLocationCoordinate2D, meters: Double = 1200) {
        // tracks는 MapVM 내부에 private이지만, 여기선 접근 가능
        let tr = tracks[busId]
        setTemporaryFutureRoute(from: coordinate, using: tr, meters: meters)
    }
    // MapVM.swift 맨 위 근처에 타입 추가
    

    // MapVM 안에 메서드 추가
    /// 팔로우 중 버스의 앞으로 최대 N개 정류장 + ETA(분) (디버그 로그 강화)
    func upcomingStops(for busId: String, maxCount: Int = 7) -> [UpcomingStopETA] {
        guard let live = buses.first(where: { $0.id == busId }) else { return [] }
        let here = CLLocationCoordinate2D(latitude: live.lat, longitude: live.lon)

        let routeNo = routeNoById[busId] ?? live.routeNo
        let ridRaw  = routeIdByRouteNo[routeNo] ?? lastKnownRouteIdByRouteNo[routeNo] ?? ""
        let ridEff  = numericRouteIdByRouteNo[routeNo] ?? numericRouteId(from: ridRaw) ?? ridRaw

        guard let meta = routeMetaById[ridEff],
              meta.shape.count >= 2, meta.shape.count == meta.cumul.count
        else {
            // 메타가 없거나 불완전 → 방향/근접 폴백
            return upcomingStopsDirectionalFallback(for: busId, maxCount: maxCount)
        }

        // 정류장 배열: 캐시에 없으면 meta의 stopIds/coords로 합성
        let routeStops: [BusStop] = {
            if let s = routeStopsByRouteId[ridEff], !s.isEmpty { return s }
            if let s2 = routeStopsByRouteId[ridRaw], !s2.isEmpty { return s2 }
            // 합성: id/좌표는 meta의 것을 쓰고, 이름은 캐시/화면 목록에서 찾아 붙임
            var list: [BusStop] = []
            list.reserveCapacity(meta.stopIds.count)
            for (i, sid) in meta.stopIds.enumerated() {
                let coord = meta.stopCoords[i]
                let name = stops.first(where: { $0.id == sid })?.name
                       ?? knownStopsIndex[sid]?.name
                       ?? "정류장"
                list.append(BusStop(id: sid, name: name, lat: coord.latitude, lon: coord.longitude, cityCode: CITY_CODE))
            }
            return list
        }()

        guard let prj = projectOnRoute(here, shape: meta.shape, cumul: meta.cumul),
              !meta.stopS.isEmpty, meta.stopS.count == routeStops.count
        else {
            // 사영 실패 시에도 폴백
            return upcomingStopsDirectionalFallback(for: busId, maxCount: maxCount)
        }

        let stopS = meta.stopS
        let startIdx = max(0, stopS.firstIndex(where: { $0 > prj.s }) ?? (stopS.count - 1))
        let endIdx   = min(routeStops.count - 1, startIdx + maxCount - 1)

        let vObs    = max(0.1, tracks[busId]?.speedMps ?? 0)
        let vForETA = min(25.0, max(1.5, vObs))

        // 첫 정류장까지 시간과 관측 ETA 중 큰 값으로 시작 (패널과 자연스럽게)
        var tAccSec = max((stopS[startIdx] - prj.s) / vForETA, Double(live.etaMinutes ?? 0) * 60.0)

        var out: [UpcomingStopETA] = []
        // 첫 정류장
        let firstMin = max(0, Int(ceil(tAccSec / 60.0)))
        out.append(.init(id: routeStops[startIdx].id, name: routeStops[startIdx].name, etaMin: firstMin))

        // 이후 정류장: 구간 거리 누적
        if startIdx < endIdx {
            var prevS = stopS[startIdx]
            for j in (startIdx + 1)...endIdx {
                let ds = max(0, stopS[j] - prevS)
                tAccSec += ds / vForETA
                let etaMin = max(0, Int(ceil(tAccSec / 60.0)))
                out.append(.init(id: routeStops[j].id, name: routeStops[j].name, etaMin: etaMin))
                prevS = stopS[j]
            }
        }

        return out
    }


    // MapVM
    @Published private(set) var upcomingTick: Int = 0

    private var knownStopsIndex: [String: BusStop] = [:]   // 전역 캐시(지도에 안 뿌림)
    private var aheadPrefetchInFlight: Set<String> = []    // 중복 프리페치 방지
    private var aheadPrefetchCooldown: [String: Date] = [:]// 너무 잦은 프리페치 쿨다운

    // MapVM
    private func prefetchStopsAhead(for busId: String, hops: Int = 6, stepMeters: Double = 400) async {
        // 쿨다운/중복 가드
        let now = Date()
        if aheadPrefetchInFlight.contains(busId) { return }
        if let until = aheadPrefetchCooldown[busId], until > now { return }
        aheadPrefetchInFlight.insert(busId)
        defer { aheadPrefetchInFlight.remove(busId) }

        guard let live = buses.first(where: { $0.id == busId }),
              let tr = tracks[busId], let dir = tr.dirUnit else { return }

        let lat0 = live.lat, lon0 = live.lon
        let cosLat = cos(lat0 * .pi/180)
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cosLat

        var newly: [BusStop] = []
        for i in 1...hops {
            let dist = Double(i) * stepMeters
            // dir(x,y)는 미터 기준 단위벡터임: 이를 위경도로 투영
            let dLat = (dir.y * dist) / mPerDegLat
            let dLon = (dir.x * dist) / mPerDegLon
            let lat = lat0 + dLat
            let lon = lon0 + dLon

            // MOTIE 근접정류장 API 재사용
            if let arr = try? await api.fetchStops(lat: lat, lon: lon), !arr.isEmpty {
                newly.append(contentsOf: arr)
            }
        }

        if !newly.isEmpty {
            await MainActor.run {
                self.integrateKnownStops(newly)
                self.upcomingTick &+= 1           // ✅ 패널 리렌더 트리거
            }
        } else {
            // 너무 자주 빈손이면 60초 쿨다운
            aheadPrefetchCooldown[busId] = Date().addingTimeInterval(60)
        }
    }

    
    // MapVM
    private func upcomingStopsDirectionalFallback(for busId: String, maxCount: Int) -> [UpcomingStopETA] {
        guard let live = buses.first(where: { $0.id == busId }) else { return [] }
        let here = CLLocationCoordinate2D(latitude: live.lat, longitude: live.lon)
        let tr = tracks[busId]   // 방향이 없을 수도 있음

        // 후보 카탈로그(화면+전역)
        let catalog: [BusStop] = {
            var dict = [String: BusStop]()
            for s in stops { dict[s.id] = s }
            for s in knownStopsIndex.values { dict[s.id] = s }
            return Array(dict.values)
        }()
        guard !catalog.isEmpty else { return [] }

        let vObs  = max(0.1, tr?.speedMps ?? 0)
        let vForE = max(1.5, min(25.0, vObs))

        // 1) 방향 기반 후보 뽑기(되도록)
        func directionalCandidates(aheadMin: Double, aheadMax: Double, lateralMax: Double) -> [(stop: BusStop, key: Double, dist: Double)] {
            guard let dir = tr?.dirUnit else { return [] }
            return catalog.compactMap { s in
                let v = GeoUtil.deltaMeters(from: here, to: .init(latitude: s.lat, longitude: s.lon))
                let proj = v.dx*dir.x + v.dy*dir.y
                let lat  = abs(-v.dy*dir.x + v.dx*dir.y)
                let ok = (proj >= aheadMin && proj <= aheadMax && lat <= lateralMax)
                return ok ? (s, proj, v.dist) : nil
            }
            .sorted { $0.key < $1.key }
        }

        // 2) 근접 기반 후보(방향 없음/방향 후보 0개일 때)
        func proximityCandidates(limit: Int, within: Double) -> [(stop: BusStop, key: Double, dist: Double)] {
            let hereLoc = CLLocation(latitude: here.latitude, longitude: here.longitude)
            return catalog
                .map { s in (s, hereLoc.distance(from: CLLocation(latitude: s.lat, longitude: s.lon))) }
                .filter { $0.1 <= within }
                .sorted { $0.1 < $1.1 }
                .prefix(limit)
                .map { ($0.0, $0.1, $0.1) }
        }

        // 필터 → 없으면 점차 완화
        var cands = directionalCandidates(aheadMin: 8, aheadMax: 3500, lateralMax: 180)
        if cands.isEmpty { cands = directionalCandidates(aheadMin: -5, aheadMax: 5000, lateralMax: 260) }
        if cands.isEmpty { cands = proximityCandidates(limit: maxCount, within: 1200) }
        if cands.isEmpty { cands = proximityCandidates(limit: maxCount, within: 2500) }
        if cands.isEmpty { return [] }

        // 누적 시간 계산
        var out: [UpcomingStopETA] = []
        // 첫 항: 현재→첫 후보
        let first = cands[0]
        var baseSec = (first.key > 0 ? first.key : first.dist) / vForE
        baseSec = max(baseSec, Double(live.etaMinutes ?? 0) * 60.0) // 관측 ETA 최소 보정
        var tAccSec = baseSec
        out.append(.init(id: first.stop.id, name: first.stop.name, etaMin: max(0, Int(ceil(tAccSec/60.0)))))

        // 이후: 인접 후보 간 거리 차를 누적 (정렬 기준 key 사용, key가 없으면 dist)
        var prevKeyOrDist = (first.key != 0 ? first.key : first.dist)
        for c in cands.dropFirst().prefix(maxCount - 1) {
            let key = (c.key != 0 ? c.key : c.dist)
            let ds = max(0, key - prevKeyOrDist)
            tAccSec += ds / vForE
            out.append(.init(id: c.stop.id, name: c.stop.name, etaMin: max(0, Int(ceil(tAccSec/60.0)))))
            prevKeyOrDist = key
        }

        // 전방 프리페치(여전히 모자라면)
        if out.count < maxCount {
            Task { await self.prefetchStopsAhead(for: busId) }
        }
        return out
    }








    
    // MapVM 안에 추가
    // MapVM 안에 이미 만든 ensureAndDrawFutureRouteNow 를 아래로 교체
    func ensureAndDrawFutureRouteNow(for busId: String, routeNo: String, coord: CLLocationCoordinate2D) async {
        // 0) routeId 확보
        guard let rid = resolveRouteId(for: routeNo) else {
            print("⚠️ futureRoute: routeId not resolved for \(routeNo)")
            DispatchQueue.main.async { self.clearFutureRoute() }
            return
        }

        // 1) 메타 보장
        await ensureRouteMeta(routeId: rid)

        // 2) 캐시에서 메타
        guard var meta = routeMetaById[rid] else {
            print("⚠️ futureRoute: meta missing for rid=\(rid)")
            DispatchQueue.main.async { self.clearFutureRoute() }
            return
        }

        // 3) 무결성 보정
        if meta.cumul.count != meta.shape.count {
            print("⚠️ futureRoute: cumul len \(meta.cumul.count) != shape len \(meta.shape.count) → rebuild")
            let rebuilt = buildCumul(meta.shape)
            meta = RouteMeta(shape: meta.shape,
                             cumul: rebuilt,
                             stopIds: meta.stopIds,
                             stopCoords: meta.stopCoords,
                             stopS: meta.stopS)
            routeMetaById[rid] = meta
        }

        // 4) shape 검증
        guard meta.shape.count >= 2 else {
            print("⚠️ futureRoute: shape too short (\(meta.shape.count)) → clear")
            DispatchQueue.main.async { self.clearFutureRoute() }
            return
        }

        // 5) 사영
        if let prj = projectOnRoute(coord, shape: meta.shape, cumul: meta.cumul) {
            setFutureRoute(shape: meta.shape, fromSeg: prj.seg, fromPoint: prj.snapped)
            print("✅ futureRoute: set \(futureRouteCoords.count) pts (seg=\(prj.seg))")
        } else {
            // 6) 폴백: 전체 shape
            print("⚠️ futureRoute: projectOnRoute failed → fallback to full shape")
            DispatchQueue.main.async {
                self.futureRouteCoords = meta.shape
                self.futureRouteVersion &+= 1
            }
        }
    }

    // ADD: 미래경로 지우기
    func clearFutureRoute() {
        futureRouteCoords.removeAll()
        futureRouteVersion &+= 1
    }

    // ADD: seg 이후 끝까지 라인 구성
    private func setFutureRoute(shape: [CLLocationCoordinate2D],
                                fromSeg seg: Int,
                                fromPoint snapped: CLLocationCoordinate2D) {
        guard !shape.isEmpty else { return }
        var coords: [CLLocationCoordinate2D] = []
        coords.append(snapped)
        let start = max(seg + 1, 0)
        if start < shape.count {
            coords.append(contentsOf: shape[start..<shape.count])
        }
        if coords.count < 2 { futureRouteCoords = []; futureRouteVersion &+= 1; return }
        // 근접 중복점 제거(2m)
        var cleaned: [CLLocationCoordinate2D] = [coords[0]]
        for c in coords.dropFirst() {
            let d = CLLocation(latitude: cleaned.last!.latitude, longitude: cleaned.last!.longitude)
                .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if d >= 2 { cleaned.append(c) }
        }
        futureRouteCoords = cleaned
        futureRouteVersion &+= 1
    }

    // ADD: s→정류장 순회 라인(정류장 좌표를 “꼭 찍음”)
    private func buildFutureRouteStopToStop(
        meta: RouteMeta,
        prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double),
        nextIdx: Int
    ) -> [CLLocationCoordinate2D] {
        guard !meta.shape.isEmpty, meta.shape.count == meta.cumul.count,
              !meta.stopS.isEmpty, meta.stopS.count == meta.stopIds.count else { return [] }

        var coords: [CLLocationCoordinate2D] = [prj.snapped]
        var curS = prj.s
        var startSeg = prj.seg

        for i in nextIdx ..< meta.stopS.count {
            let targetS = meta.stopS[i]
            if targetS <= curS { continue }
            var j = max(0, startSeg + 1)
            while j < meta.cumul.count && meta.cumul[j] <= targetS {
                if meta.cumul[j] > curS { coords.append(meta.shape[j]) }
                j += 1
            }
            coords.append(meta.stopCoords[i]) // 꺾임 보장
            curS = targetS
            startSeg = max(startSeg, j - 1)
        }
        if coords.count < 2 { return [] }
        var cleaned: [CLLocationCoordinate2D] = [coords[0]]
        for c in coords.dropFirst() {
            let d = CLLocation(latitude: cleaned.last!.latitude, longitude: cleaned.last!.longitude)
                .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if d >= 2 { cleaned.append(c) }
        }
        return cleaned
    }

    


    

    // 팔로우 중일 때만 VM state에 반영
    // MapVM 안의 기존 메서드 교체
    // MapVM 내부 (기존 updateFutureRouteIfFollowed 교체/확장)
    // REPLACE: 팔로우 중일 때만 반영
    private func updateFutureRouteIfFollowed(
        busId: String,
        meta: RouteMeta,
        prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double),
        nextIdx: Int
    ) {
        guard followBusId == busId else { return }
        let coords = buildFutureRouteStopByStop(meta: meta, prj: prj, nextStartIdx: nextIdx)
        guard coords.count >= 2 else {
            futureRouteCoords = []; futureRouteVersion &+= 1
            return
        }
        futureRouteCoords = coords
        futureRouteVersion &+= 1
    }
    // routeId(문자열) 또는 그 안의 숫자ID까지 모두 뒤져서 Meta 찾기
    private func metaFor(routeId rid: String) -> RouteMeta? {
        if let m = routeMetaById[rid] { return m }
        if let num = numericRouteId(from: rid), let m2 = routeMetaById[num] { return m2 }
        return nil
    }

    // 버스 탭 직후 즉시 빨간선(정류장 단위) 그리기
    func trySetFutureRouteImmediately(for bus: BusAnnotation) {
        guard
            let rid  = resolveRouteId(for: bus.routeNo),
            let meta = metaFor(routeId: rid),
            let prj  = projectOnRoute(bus.coordinate, shape: meta.shape, cumul: meta.cumul)
        else {
            print("⚠️ futureRoute: meta or projection missing")
            return
        }

        let nextIdx = max(0, meta.stopS.firstIndex(where: { $0 > prj.s }) ?? (meta.stopS.count - 1))
        setFutureRouteByStops(meta: meta, from: prj, nextIdx: nextIdx, maxAheadStops: 7, includeTerminal: false)
    }

    // ADD: 단순 스냅→shape 끝까지
    private func buildFutureRoute(
        meta: RouteMeta,
        prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double)
    ) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = [prj.snapped]
        let start = min(prj.seg + 1, meta.shape.count)
        if start < meta.shape.count {
            coords.append(contentsOf: meta.shape[start...])
        }
        return coords
    }

    // ADD: segIndex 이후 라인 세터(중복점 제거 포함)
    private func setFutureRoute(from segIndex: Int,
                                snapped: CLLocationCoordinate2D,
                                meta: RouteMeta) {
        var coords: [CLLocationCoordinate2D] = [snapped]
        let i = max(0, min(segIndex + 1, meta.shape.count))
        if i < meta.shape.count {
            coords.append(contentsOf: meta.shape[i...])
        }
        if coords.count >= 2 {
            var cleaned: [CLLocationCoordinate2D] = [coords[0]]
            for c in coords.dropFirst() {
                let d = CLLocation(latitude: cleaned.last!.latitude, longitude: cleaned.last!.longitude)
                    .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                if d >= 2 { cleaned.append(c) }
            }
            futureRouteCoords = cleaned
        } else {
            futureRouteCoords = coords
        }
        futureRouteVersion &+= 1
    }

    // ADD: 현재 하이라이트 정류장 조회
    func highlightedBusStop() -> BusStop? {
        guard let sid = highlightedStopId,
              let fid = followBusId,
              let rno = routeNoById[fid],
              let rid = resolveRouteId(for: rno),
              let arr = routeStopsByRouteId[rid] else { return nil }
        return arr.first { $0.id == sid }
    }

    // ADD: 미래 라인을 업데이트 (간단 버전)
    func updateFutureRoute(
        for busId: String,
        prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double),
        meta: RouteMeta
    ) {
        var coords: [CLLocationCoordinate2D] = []
        coords.append(prj.snapped)
        if prj.seg + 1 < meta.shape.count {
            coords.append(contentsOf: meta.shape[(prj.seg + 1)...])
        }
        DispatchQueue.main.async { [weak self] in
            self?.futureRouteCoords = coords
        }
    }

    // ADD
    func updateHighlightStop(for bus: BusLive) {
        highlightedStopId = bus.nextStopName != nil
            ? stops.first(where: { $0.name == bus.nextStopName })?.id
            : nil
    }

    // ADD: MKPolyline 생성
    func futureRoutePolyline(for busId: String) -> MKPolyline? {
        guard let live = buses.first(where: { $0.id == busId }) else { return nil }
        let here = CLLocationCoordinate2D(latitude: live.lat, longitude: live.lon)

        let routeNo = routeNoById[busId] ?? live.routeNo
        guard let routeId = resolveRouteId(for: routeNo),
              let meta = routeMetaById[routeId],
              meta.shape.count >= 2,
              meta.shape.count == meta.cumul.count else {
            return nil
        }

        if let prj = projectOnRoute(here, shape: meta.shape, cumul: meta.cumul) {
            var coords: [CLLocationCoordinate2D] = []
            coords.append(prj.snapped)
            let nextIdx = max(0, min(prj.seg + 1, meta.shape.count - 1))
            coords.append(contentsOf: meta.shape[nextIdx...])
            let line = MKPolyline(coordinates: coords, count: coords.count)
            line.title = "busFuture"
            return line
        } else {
            let line = MKPolyline(coordinates: meta.shape, count: meta.shape.count)
            line.title = "busFuture"
            return line
        }
    }

    // ADD: ETA→s 관측 변환 (옵션: KF 연계)
    private func etaToSObservation(nextStopS: Double, etaMinutes: Int, vPrior: Double) -> (z: Double, R: Double) {
        let t = max(0.0, Double(etaMinutes) * 60.0)
        let v = max(1.5, min(vPrior, 25.0))
        let z = nextStopS - v * t
        let baseVar = 80.0 * 80.0
        let scale = 1.0 + min(t/240.0, 2.0)
        let R = baseVar * scale
        return (z, R)
    }

    // ADD: 간단 1D 칼만필터 구조체 (옵션)
    private struct KF1D {
        struct State { var s: Double; var v: Double; var P: simd_double2x2 }
        var q_s: Double = 1.0
        var q_v: Double = 0.8
        var v_max: Double = 30.0

        mutating func predict(_ x: inout State, dt: Double) {
            let F = simd_double2x2([SIMD2(1, dt), SIMD2(0, 1)])
            let Q = simd_double2x2([SIMD2(q_s*dt, 0), SIMD2(0, q_v*dt)])
            let sv = SIMD2(x.s, x.v)
            let svp = F * sv
            x.s = svp[0]
            x.v = min(max(svp[1], 0), v_max)
            x.P = F * x.P * F.transpose + Q
        }

        mutating func update(z: Double, R: Double, _ x: inout State) {
            let H = SIMD2(1.0, 0.0)
            let HP = SIMD2( x.P[0,0], x.P[1,0] )
            let S = H[0]*HP[0] + H[1]*HP[1] + R
            let K = SIMD2(HP[0]/S, HP[1]/S)

            let y = z - x.s
            let huber = 25.0
            let yAdj: Double = abs(y) <= huber ? y : (huber * (y >= 0 ? 1 : -1))

            x.s += K[0] * yAdj
            x.v = min(max(x.v + K[1] * yAdj, 0), v_max)

            var I = simd_double2x2(diagonal: SIMD2(1,1))
            let KH = simd_double2x2([SIMD2(K[0]*H[0], K[0]*H[1]),
                                     SIMD2(K[1]*H[0], K[1]*H[1])])
            x.P = (I - KH) * x.P
        }
    }

    // ADD: 스냅샷 타입/유틸
    struct RouteSnapshot {
        let metaById: [String: RouteMeta]
        let stopsByRouteId: [String: [BusStop]]
    }
    private func makeRouteSnapshot() -> RouteSnapshot {
        return RouteSnapshot(metaById: routeMetaById, stopsByRouteId: routeStopsByRouteId)
    }
    private func applyIfCurrent(epoch: UInt64, _ apply: () -> Void) {
        if epoch >= latestAppliedEpoch {
            latestAppliedEpoch = epoch
            apply()
        }
    }
    func prefetchFollowedRouteIfNeeded(routeId: String) {
        Task { [weak self] in
            guard let self else { return }
            if self.routeMetaById[routeId] == nil {
                try? await self.ensureRouteMeta(routeId: routeId)
            }
        }
    }

    // REPLACE: RouteMeta / 캐시
    struct RouteMeta {
        let shape: [CLLocationCoordinate2D]
        let cumul: [Double]
        let stopIds: [String]
        let stopCoords: [CLLocationCoordinate2D]
        let stopS: [Double]
    }
    private var routeMetaById: [String: RouteMeta] = [:]

    // ADD: “엄격” 다음 정류장 판정
    private func nextStopFromRouteStrict(
        busId: String,
        progressS: Double,
        routeStops: [BusStop],
        stopS: [Double],
        lateral: Double
    ) -> BusStop? {
        guard !routeStops.isEmpty, routeStops.count == stopS.count else { return nil }
        let sPrev = lastSByBusId[busId] ?? progressS
        let sNow  = max(progressS, sPrev - 20)
        let AHEAD_GATE = max(18.0, min(50.0, 12.0 + 0.35 * lateral))
        let lastIdx: Int? = {
            guard let sid = lastStopIdByBusId[busId] else { return nil }
            return routeStops.firstIndex(where: { $0.id == sid })
        }()
        var candIdx: Int? = nil
        for i in 0..<stopS.count { if stopS[i] > sNow + AHEAD_GATE { candIdx = i; break } }
        if let li = lastIdx, let ci = candIdx, ci > li + 1 { candIdx = li + 1 }

        if let ci = candIdx {
            let chosen = routeStops[ci]
            lastSByBusId[busId] = max(sPrev, sNow)
            lastStopIdByBusId[busId] = chosen.id
            return chosen
        } else if let li = lastIdx {
            lastSByBusId[busId] = max(sPrev, sNow)
            return routeStops[li]
        } else {
            lastSByBusId[busId] = max(sPrev, sNow)
            return nil
        }
    }

    // ADD: 누적거리 빌더
    private func buildCumul(_ pts: [CLLocationCoordinate2D]) -> [Double] {
        guard !pts.isEmpty else { return [] }
        var out: [Double] = [0]
        for i in 1..<pts.count {
            let d = CLLocation(latitude: pts[i-1].latitude, longitude: pts[i-1].longitude)
                .distance(from: CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude))
            out.append(out.last! + d)
        }
        return out
    }

    // ADD: 폴리라인 사영
    private func projectOnRoute(_ p: CLLocationCoordinate2D,
                                shape: [CLLocationCoordinate2D],
                                cumul: [Double]) -> (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double)? {
        guard shape.count >= 2, shape.count == cumul.count else { return nil }
        var best: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double)? = nil

        for i in 0..<(shape.count-1) {
            let a = shape[i], b = shape[i+1]
            let va = GeoUtil.deltaMeters(from: a, to: p)
            let ab = GeoUtil.deltaMeters(from: a, to: b)
            let abLen2 = max(1e-6, ab.dx*ab.dx + ab.dy*ab.dy)
            var t = (va.dx*ab.dx + va.dy*ab.dy) / abLen2
            t = max(0, min(1, t))
            let px = ab.dx * t, py = ab.dy * t
            let snapped = CLLocationCoordinate2D(
                latitude: a.latitude + (py/GeoUtil.metersPerDegLat(at: a.latitude)),
                longitude: a.longitude + (px/GeoUtil.metersPerDegLon(at: a.latitude))
            )
            let lateral = hypot(va.dx - px, va.dy - py)
            let s = cumul[i] + sqrt(min(abLen2, ab.dx*ab.dx + ab.dy*ab.dy)) * t
            if best == nil || lateral < best!.lateral {
                best = (snapped, s, i, lateral)
            }
        }
        return best
    }

    // ADD: 정류장 → s
    private func stopsProjectedS(_ stops: [BusStop], shape: [CLLocationCoordinate2D], cumul: [Double]) -> [Double] {
        stops.map { s in
            let p = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
            if let prj = projectOnRoute(p, shape: shape, cumul: cumul) { return prj.s }
            return .infinity
        }
    }

    // ADD: 폴백 직선 미래 경로
    func setTemporaryFutureRoute(from coord: CLLocationCoordinate2D, using track: BusTrack?, meters: Double = 1200) {
        var coords: [CLLocationCoordinate2D] = [coord]
        if let tr = track, let dir = tr.dirUnit {
            let mLat = GeoUtil.metersPerDegLat(at: coord.latitude)
            let mLon = GeoUtil.metersPerDegLon(at: coord.latitude)
            let dLat = (meters * dir.y) / mLat
            let dLon = (meters * dir.x) / mLon
            let p2 = CLLocationCoordinate2D(latitude: coord.latitude + dLat, longitude: coord.longitude + dLon)
            coords.append(p2)
        } else {
            let mLat = GeoUtil.metersPerDegLat(at: coord.latitude)
            let p2 = CLLocationCoordinate2D(latitude: coord.latitude + (meters / mLat), longitude: coord.longitude)
            coords.append(p2)
        }
        DispatchQueue.main.async { [weak self] in
            self?.futureRouteCoords = coords
            self?.futureRouteVersion &+= 1
        }
    }

    // ADD: 메타 재시도(백오프)
    @MainActor
    func ensureRouteMetaWithRetry(routeId rawRouteId: String, routeNo: String? = nil) {
        if isCoolingDown(rawRouteId) { return }
        if metaInFlight.contains(rawRouteId) { return }
        metaInFlight.insert(rawRouteId)

        Task { [weak self] in
            guard let self else { return }
            let backoff: [Double] = [0.0, 2.0, 5.0]
            var succeeded = false

            for (i, delay) in backoff.enumerated() {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                let ok = await self.ensureRouteMetaOnce(rawRouteId: rawRouteId, routeNo: routeNo)
                if ok { succeeded = true; break }
                if i == backoff.indices.last {
                    await self.startCooldown(rawRouteId, minutes: 15)
                    print("⚠️ ensureRouteMeta cooldown 15m for \(rawRouteId)")
                }
            }
            await MainActor.run { [weak self] in
                self?.metaInFlight.remove(rawRouteId)
            }
        }
    }

    
    
    
    
    

    
    
   



    let trail = BusTrailStore()
        @Published var trailVersion: Int = 0      // 오버레이 갱신 트리거

        func startTrail(for busId: String, seed: CLLocationCoordinate2D?) {
            trail.start(id: busId, seed: seed); trailVersion &+= 1
        }
        func stopTrail() { trail.stop(); trailVersion &+= 1 }
    // MapVM 안에 추가
  

       // 현재 보유 데이터로 스냅샷 만들기
    
   

    // REPLACE: ensureRouteMeta (호출부 호환)
    private func ensureRouteMeta(routeId: String) async {
        await ensureRouteMeta(routeId: routeId, routeNo: routeNoByRouteId[routeId])
    }
    private func ensureRouteMeta(routeId rawRouteId: String, routeNo: String?) async {
        if let m = routeMetaById[rawRouteId], m.shape.count >= 2, m.shape.count == m.cumul.count { return }
        if let no = routeNo, let num = numericRouteIdByRouteNo[no],
           let m2 = routeMetaById[num], m2.shape.count >= 2, m2.shape.count == m2.cumul.count {
            routeMetaById[rawRouteId] = m2
            return
        }
        let (stops, usedId) = await fetchStopsForRoute(rawRouteId: rawRouteId, routeNo: routeNo)
        let idForCache = usedId ?? (numericRouteId(from: rawRouteId) ?? rawRouteId)
        var shape: [CLLocationCoordinate2D] = []
        do {
            let tryId = numericRouteId(from: rawRouteId) ?? rawRouteId
            shape = try await api.fetchRoutePath(cityCode: CITY_CODE, routeId: tryId)
        } catch { shape = [] }
        if shape.count < 2, stops.count >= 2 {
            shape = stops.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
        let cumul = buildCumul(shape)
        guard shape.count >= 2, cumul.count == shape.count else { return }
        let stopS = stopsProjectedS(stops, shape: shape, cumul: cumul)
        let meta = RouteMeta(
            shape: shape, cumul: cumul,
            stopIds: stops.map { $0.id },
            stopCoords: stops.map { .init(latitude: $0.lat, longitude: $0.lon) },
            stopS: stopS
        )
        routeMetaById[idForCache] = meta
        routeMetaById[rawRouteId] = meta
        if let no = routeNo { if let num = numericRouteId(from: rawRouteId) { numericRouteIdByRouteNo[no] = num } }
    }

    // ADD: DJB30300128 → 30300128
    private func numericRouteId(from rid: String?) -> String? {
        guard let rid else { return nil }
        let digits = rid.filter { $0.isNumber }
        return digits.isEmpty ? nil : digits
    }





    
    // routeNo -> routeId 해석
    // REPLACE: routeNo -> routeId 해석
    private func resolveRouteId(for routeNo: String) -> String? {
        if let id = routeIdByRouteNo[routeNo] { return id }
        if let id = lastKnownRouteIdByRouteNo[routeNo] { return id }
        if let id = latestTopArrivals.first(where: { $0.routeNo == routeNo })?.routeId {
            routeIdByRouteNo[routeNo] = id
            lastKnownRouteIdByRouteNo[routeNo] = id
            return id
        }
        return nil
    }

    // ADD
    func onBusSelected(_ bus: BusAnnotation) async {
        guard let rid = resolveRouteId(for: bus.routeNo) else { return }
        await ensureRouteMeta(routeId: rid)
    }

    // REPLACE: s 기반 다음 정류장(히스테리시스)
    private func nextStopFromRoute(
        busId: String,
        progressS s: Double,
        routeStops: [BusStop],
        stopS: [Double]
    ) -> BusStop? {
        guard routeStops.count == stopS.count, !routeStops.isEmpty, s.isFinite else { return nil }
        let gateMargin: Double = 18
        let holdRadius: Double = 55
        let minAdvance: Double = 6
        let neededStreak: Int = 2

        func initialIndex(for s: Double) -> Int {
            if let idx = stopS.firstIndex(where: { $0 >= s }) { return idx }
            return stopS.count - 1
        }
        var curIdx = lastNextStopIndexByBusId[busId] ?? initialIndex(for: s)
        curIdx = max(0, min(curIdx, stopS.count - 1))
        let lastS   = lastProgressSByBusId[busId] ?? s
        let deltaS  = s - lastS
        lastProgressSByBusId[busId] = s

        if curIdx >= stopS.count - 1 {
            lastNextStopIndexByBusId[busId] = curIdx
            passStreakByBusId[busId] = 0
            return routeStops[curIdx]
        }
        let sJ = stopS[curIdx]
        let distToJ = abs(sJ - s)
        if distToJ <= holdRadius {
            lastNextStopIndexByBusId[busId] = curIdx
            passStreakByBusId[busId] = 0
            return routeStops[curIdx]
        }
        let gate = sJ + gateMargin
        if s >= gate && deltaS >= minAdvance {
            passStreakByBusId[busId] = (passStreakByBusId[busId] ?? 0) + 1
        } else {
            passStreakByBusId[busId] = 0
        }
        if (passStreakByBusId[busId] ?? 0) >= neededStreak {
            curIdx = min(curIdx + 1, stopS.count - 1)
            passStreakByBusId[busId] = 0
        }
        if curIdx < stopS.count - 1 {
            curIdx = min(curIdx, lastNextStopIndexByBusId[busId] ?? curIdx)
            curIdx = max(curIdx, lastNextStopIndexByBusId[busId] ?? curIdx)
        }
        lastNextStopIndexByBusId[busId] = curIdx
        return routeStops[curIdx]
    }


    // REPLACE: ETA 스무딩
    // REPLACE: ETA 스무딩 (컴파일 OK 버전)
    private func smoothETA(rawETA: Int?, busId: String, distToNextStop: Double?) -> Int? {
        guard let raw = rawETA else { return nil }

        let now = Date()
        let farFromStop = (distToNextStop ?? 9_999) > 50
        let speed = tracks[busId]?.speedMps ?? 0
        let isSlow = speed < 1.0

        if isSlow && farFromStop, let prev = lastETA[busId] {
            // 증가만 제한(30초당 +1분), 감소는 즉시 반영
            if raw >= prev.eta {
                let dt = now.timeIntervalSince(prev.at)
                let allowedIncrease = Int(dt / 30.0)
                let capped = min(prev.eta + allowedIncrease, raw)
                lastETA[busId] = (capped, now)
                // ✅ result 미정의 → 실제 값(capped)로 로깅
                Telemetry.shared.mark(.etaSmoothed, tags: ["busId": busId], fields: ["eta": Double(capped)])
                return capped
            } else {
                lastETA[busId] = (raw, now)
                Telemetry.shared.mark(.etaSmoothed, tags: ["busId": busId], fields: ["eta": Double(raw)])
                return raw
            }
        } else {
            lastETA[busId] = (raw, now)
            Telemetry.shared.mark(.etaSmoothed, tags: ["busId": busId], fields: ["eta": Double(raw)])
            return raw
        }
    }


    // ADD
    deinit { autoTask?.cancel(); regionTask?.cancel() }

    // ADD
    private func metersBetween(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> CLLocationDistance {
        guard let a, let b else { return .greatestFiniteMagnitude }
        let la = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let lb = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return la.distance(from: lb)
    }


   
    // REPLACE: 지역 변경시 리로드 트리거
    private func shouldReload(for region: MKCoordinateRegion) -> Bool {
        let threshold: CLLocationDistance = (followBusId == nil) ? 180 : 120
        if lastStopRefreshCenter == nil { return true }
        let moved = metersBetween(lastStopRefreshCenter, region.center)
        if moved >= threshold { return true }
        if let prev = lastRegion {
            let zoomDelta = abs(region.span.latitudeDelta - prev.span.latitudeDelta) /
                            max(prev.span.latitudeDelta, 0.0001)
            if zoomDelta >= 0.20 { return true }
        } else {
            return true
        }
        return false
    }


    // REPLACE: 고스트 팔로우 보강
    private func ensureFollowGhost(_ mergedById: inout [String: BusLive]) {
        guard let fid = followBusId, mergedById[fid] == nil, let tr = tracks[fid] else { return }
        let age = Date().timeIntervalSince(tr.lastAt)
        let dwellHolding = (dwellUntil[fid] ?? .distantPast) > Date()
        let maxGhostAge: TimeInterval = dwellHolding ? 3600 : 300
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

    // REPLACE: 진행방향 기반 nextStop + ETA (메타 미존재시 Fallback)
    private func nextStopAndETA(
        busId: String,
        coord: CLLocationCoordinate2D,
        track: BusTrack,
        fallbackByName: String?
    ) -> (BusStop?, Int?) {

        let searchRadius: Double = 320
        let aheadProjMin: Double = -8
        let lateralBias: Double = 2.2
        let switchMarginMeters: Double = 22
        let passBehindProj: Double = -18
        let keepSameIfNearMeters: Double = 60

        let here = coord
        let nearby = stops
            .map { stop -> (s: BusStop, dx: Double, dy: Double, dist: Double) in
                let v = GeoUtil.deltaMeters(from: here, to: .init(latitude: stop.lat, longitude: stop.lon))
                return (stop, v.dx, v.dy, v.dist)
            }
            .filter { $0.dist < searchRadius }

        guard !nearby.isEmpty else {
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

        let dir = track.dirUnit
        struct Cand { let s: BusStop; let proj: Double; let lateral: Double; let dist: Double; let score: Double }
        let ranked: [Cand] = nearby.map { c in
            if let d = dir {
                let proj = c.dx*d.x + c.dy*d.y
                let lat  = abs(-c.dy*d.x + c.dx*d.y)
                let score = proj - lateralBias*lat
                return Cand(s: c.s, proj: proj, lateral: lat, dist: c.dist, score: score)
            } else {
                return Cand(s: c.s, proj: 0, lateral: c.dist, dist: c.dist, score: -c.dist)
            }
        }
        .sorted { $0.score == $1.score ? $0.dist < $1.dist : $0.score > $1.score }

        let ahead = (dir != nil) ? ranked.filter { $0.proj >= aheadProjMin } : ranked

        let lastId = lastPredictedStopId[busId]
        var chosen: Cand? = ahead.first
        if let lastId,
           let cur = ahead.first(where: { $0.s.id == lastId }) {
            let passed = cur.proj <= passBehindProj
            let keepByNear = cur.dist <= keepSameIfNearMeters
            let best = ahead.first
            let betterByMargin = (best != nil) && ((best!.score - cur.score) >= switchMarginMeters)
            if !passed && (keepByNear || !betterByMargin) {
                chosen = cur
            } else {
                chosen = best
            }
        }
        if chosen == nil, let name = fallbackByName {
            if let found = ranked.first(where: { name.contains($0.s.name) || $0.s.name.contains(name) }) {
                chosen = found
            }
        }
        guard let pick = chosen else { return (nil, nil) }

        let vObs = max(0.1, track.speedMps)
        let vForETA = max(1.5, vObs)
        let forwardMeters = max(0, pick.proj > 0 ? pick.proj : pick.dist)
        var etaSec = Int(forwardMeters / vForETA)
        if vObs < 1.2 && pick.dist < 25 { etaSec = 0 }
        let etaMin = max(0, Int((Double(etaSec)/60.0).rounded(.toNearestOrEven)))

        lastPredictedStopId[busId] = pick.s.id
        return (pick.s, etaMin)
    }



    // REPLACE: region 커밋 트리거
    func onRegionCommitted(_ region: MKCoordinateRegion) {
        regionTask?.cancel()
        regionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard let self else { return }
            if self.shouldReload(for: region) {
                self.lastRegion = region
                self.lastReloadAt = Date()
                self.reloadTask?.cancel()
                self.reloadTask = Task { [weak self] in
                    await self?.reload(center: region.center)
                }
            }
        }
    }

    // ADD: 근처 정류장 후보
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

    // ADD: routeStops 가져오기(숫자ID 우선)
    private func fetchStopsForRoute(rawRouteId: String, routeNo: String?) async -> (stops: [BusStop], usedId: String?) {
        if let no = routeNo, let num = numericRouteIdByRouteNo[no] {
            do {
                let s = try await api.fetchStopsByRoute(cityCode: CITY_CODE, routeId: num)
                if !s.isEmpty { return (s, num) }
            } catch { }
        }
        if let num2 = numericRouteId(from: rawRouteId) {
            do {
                let s = try await api.fetchStopsByRoute(cityCode: CITY_CODE, routeId: num2)
                if !s.isEmpty { return (s, num2) }
            } catch { }
        }
        do {
            let s = try await api.fetchStopsByRoute(cityCode: CITY_CODE, routeId: rawRouteId)
            if !s.isEmpty { return (s, rawRouteId) }
        } catch { }
        return ([], nil)
    }

    // ADD: 메타 1회 시도 버전
    private func ensureRouteMetaOnce(rawRouteId: String, routeNo: String?) async -> Bool {
        if let m = routeMetaById[rawRouteId], m.shape.count >= 2, m.shape.count == m.cumul.count {
            Telemetry.shared.mark(.ensureRouteMetaHit, tags:["rid": rawRouteId])

            return true
        }
        if let no = routeNo, let num = numericRouteIdByRouteNo[no],
           let m2 = routeMetaById[num], m2.shape.count >= 2, m2.shape.count == m2.cumul.count {
            routeMetaById[rawRouteId] = m2
            Telemetry.shared.mark(.ensureRouteMetaHit, tags:["rid": rawRouteId])

            return true
        }
        let (stops, usedId) = await fetchStopsForRoute(rawRouteId: rawRouteId, routeNo: routeNo)
        let idForCache = usedId ?? (numericRouteId(from: rawRouteId) ?? rawRouteId)
        var shape: [CLLocationCoordinate2D] = []
        if let num = numericRouteId(from: rawRouteId) {
            shape = (try? await api.fetchRoutePath(cityCode: CITY_CODE, routeId: num)) ?? []
        }
        if shape.count < 2 {
            shape = (try? await api.fetchRoutePath(cityCode: CITY_CODE, routeId: rawRouteId)) ?? []
        }
        if shape.count < 2, stops.count >= 2 {
            shape = stops.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
        let cumul = buildCumul(shape)
        guard shape.count >= 2, cumul.count == shape.count else {
            Telemetry.shared.mark(.ensureRouteMetaFail, tags:["rid": rawRouteId])

            return false
        }

        let stopS = stopsProjectedS(stops, shape: shape, cumul: cumul)
        let meta = RouteMeta(
            shape: shape, cumul: cumul,
            stopIds: stops.map { $0.id },
            stopCoords: stops.map { .init(latitude: $0.lat, longitude: $0.lon) },
            stopS: stopS
        )
        routeMetaById[idForCache] = meta
        routeMetaById[rawRouteId] = meta
        if let no = routeNo, let num = numericRouteId(from: rawRouteId) {
            numericRouteIdByRouteNo[no] = num
        }
        clearCooldown(rawRouteId); clearCooldown(idForCache)
        
        // ✅ 성공 로그
        Telemetry.shared.mark(.ensureRouteMetaMiss, tags:["rid": rawRouteId])
        return true
    }

    // ADD
    private func integrateKnownStops(_ arr: [BusStop]) {
        for s in arr { knownStopsIndex[s.id] = s }
    }

    
    // REPLACE: 메인 리로드
    @MainActor
    func reload(center: CLLocationCoordinate2D) async {
        Telemetry.shared.mark(.mapReloadBegin)
        defer { Telemetry.shared.mark(.mapReloadEnd) }

        epochCounter &+= 1
        let epoch = epochCounter
        self.lastStopRefreshCenter = center

        // 1) 정류장
        do {
            let stops = try await api.fetchStops(lat: center.latitude, lon: center.longitude)
            applyIfCurrent(epoch: epoch) {
                self.stops = stops
                self.integrateKnownStops(stops)
            }
            // ✅ 요청 완료 마크
            Telemetry.shared.mark(.fetchStopsEnd)
        } catch {
            let ns = error as NSError
            if !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) {
                print("❌ stops error: \(error)")
            }
            applyIfCurrent(epoch: epoch) {
                self.latestTopArrivals = []
                self.buses = []
            }
            return
        }

        // 2) 도착정보
        do {
            let candidates = nearestStops(from: center, limit: 4, within: 500)
            guard !candidates.isEmpty else {
                applyIfCurrent(epoch: epoch) {
                    self.latestTopArrivals = []
                    self.buses = []
                }
                return
            }
            var allArrivals: [ArrivalInfo] = []
            try await withThrowingTaskGroup(of: [ArrivalInfo].self) { group in
                for s in candidates {
                    group.addTask { try await self.api.fetchArrivalsDetailed(cityCode: CITY_CODE, nodeId: s.id) }
                }
                while let arr = try await group.next() {
                    allArrivals.append(contentsOf: arr)
                    
                }
            }
            // ✅ 요청 완료 마크
            Telemetry.shared.mark(.fetchArrivalsEnd)
            let top = computeTopArrivals(allArrivals: allArrivals,
                                         followedRouteNo: (followBusId.flatMap { routeNoById[$0] }))
            applyIfCurrent(epoch: epoch) { self.latestTopArrivals = top }
            guard !top.isEmpty else {
                applyIfCurrent(epoch: epoch) { self.buses = [] }
                return
            }

            // 3) 버스 위치
            let snap = makeRouteSnapshot()
            let etaByRoute: [String: Int] = Dictionary(
                top.map { ($0.routeNo, $0.etaMinutes) },
                uniquingKeysWith: { min($0, $1) }
            )

            var mergedById: [String: BusLive] = [:]
            try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in top {
                    group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) }
                }
                while let arr = try await group.next() {
                    let enriched = arr.map { var m = $0; m.etaMinutes = etaByRoute[m.routeNo]; return m }
                    let filtered = self.mergeAndFilter(enriched, snap: snap)
                    for b in filtered { self.routeNoById[b.id] = b.routeNo; mergedById[b.id] = b }
                    self.ensureFollowGhost(&mergedById)
                    applyIfCurrent(epoch: epoch) { self.buses = Array(mergedById.values) }
                    // ✅ 요청 완료 마크(누적 요청 수 카운트용)
                    Telemetry.shared.mark(.fetchBusLocEnd)
                }
            }
            startAutoRefresh()
        } catch {
            let ns = error as NSError
            if ns.domain != NSURLErrorDomain || ns.code != NSURLErrorCancelled {
                print("❌ arrivals/busloc error: \(error)")
            }
            applyIfCurrent(epoch: epoch) {
                self.buses = []
                self.latestTopArrivals = []
            }
        }
        Telemetry.shared.mark(.mapReloadBegin)
        defer { Telemetry.shared.mark(.mapReloadEnd) }

    }

    // ADD: 오토 리프레시 루프
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
    private var lastRefreshAt: Date = .distantPast
    private let minRefreshInterval: TimeInterval = 0.5

    

   
    // REPLACE: 버스만 리프레시
    private func refreshBusesOnly() async {
        if Date().timeIntervalSince(lastRefreshAt) < minRefreshInterval { return }
        lastRefreshAt = Date()
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        epochCounter &+= 1
        let epoch = epochCounter

        var top = computeTopArrivals(allArrivals: latestTopArrivals,
                                     followedRouteNo: (followBusId.flatMap { routeNoById[$0] }))

        if let fid = followBusId,
           let rno = routeNoById[fid],
           let rid = resolveRouteId(for: rno),
           top.first(where: { $0.routeId == rid }) == nil {
            top.append(ArrivalInfo(routeId: rid, routeNo: rno, etaMinutes: 5))
        }
        guard !top.isEmpty else { return }

        let snap = makeRouteSnapshot()
        let etaByRoute: [String: Int] =
            Dictionary(top.map { ($0.routeNo, $0.etaMinutes) },
                       uniquingKeysWith: { min($0, $1) })
        var mergedById: [String: BusLive] = Dictionary(uniqueKeysWithValues: self.buses.map { ($0.id, $0) })

        do {
            try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in top {
                    group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) }
                }
                while let arr = try await group.next() {
                    let enriched = arr.map { var m = $0; m.etaMinutes = etaByRoute[m.routeNo]; return m }
                    let filtered = self.mergeAndFilter(enriched, snap: snap)
                    for b in filtered { self.routeNoById[b.id] = b.routeNo; mergedById[b.id] = b }
                    self.ensureFollowGhost(&mergedById)
                    applyIfCurrent(epoch: epoch) {
                        self.buses = Array(mergedById.values)
                    }
                }
            }
        } catch { /* 무음 */ }

        if let fid = followBusId,
           self.buses.first(where: { $0.id == fid }) == nil,
           let rno = routeNoById[fid] {

            let cand = self.buses
                .filter { $0.routeNo == rno }
                .min { lhs, rhs in
                    let a = CLLocation(latitude: lhs.lat, longitude: lhs.lon)
                    let b = CLLocation(latitude: rhs.lat, longitude: rhs.lon)
                    let last = tracks[fid]?.lastLoc
                    guard let last else { return false }
                    let la = CLLocation(latitude: last.latitude, longitude: last.longitude)
                    return la.distance(from: a) < la.distance(from: b)
                }
            if let c = cand { followBusId = c.id }
        }
    }

    // ADD: 통과/단조 증가 유틸 (필요시)
    private var lastPassedStopIndex: [String: Int] = [:]
    private func hasPassedStop(bus: CLLocationCoordinate2D,
                               stop: CLLocationCoordinate2D,
                               direction: CGPoint) -> Bool {
        if abs(direction.x) > abs(direction.y) {
            if direction.x > 0 { return bus.longitude > stop.longitude }
            else { return bus.longitude < stop.longitude }
        } else {
            if direction.y > 0 { return bus.latitude > stop.latitude }
            else { return bus.latitude < stop.latitude }
        }
    }
    private var busRouteIdByBusId: [String: String] = [:]
    private func monotonicNextStopIndex(
        busId: String,
        routeId: String,
        progressS: Double,
        lateralMeters: Double,
        stopsCount: Int,
        stopS: [Double]
    ) -> Int {
        let lateralMax: Double = 120.0
        if lateralMeters > lateralMax, let keep = lastNextStopIndexByBusId[busId] {
            return keep
        }
        let currentIdx: Int = {
            if let cached = lastNextStopIndexByBusId[busId] { return cached }
            let j = stopS.enumerated().min(by: { abs($0.element - progressS) < abs($1.element - progressS) })?.offset ?? 0
            let gate: Double = 20.0
            return min(j + (progressS > stopS[j] + gate ? 1 : 0), stopsCount - 1)
        }()
        var idx = currentIdx
        let gate: Double = 20.0
        while idx < stopsCount - 1, progressS >= stopS[idx] + gate { idx += 1 }
        lastNextStopIndexByBusId[busId] = idx
        busRouteIdByBusId[busId] = routeId
        return idx
    }
    
    
    
    
    

   

    // MapVM
    // REPLACE: 병합/필터(스냅·ETA·미래경로 포함)
    private func mergeAndFilter(_ incoming: [BusLive], snap: RouteSnapshot) -> [BusLive] {
        var out: [BusLive] = []

        let LATERAL_MAX_M: Double = 60
        let PASS_GATE_M: Double   = 18
        let SPEED_FLOOR_MPS: Double = 1.5
        let NEAR_STOP_M: Double   = 25
        let MAX_STEP_M: Double    = 300
        let EMA_ALPHA: Double     = 0.35
        let MAX_PLAUSIBLE_MPS: Double = 40.0
        let FOLLOW_STEP_ALLOW_METERS: CLLocationDistance = 1200

        for var b in incoming {
            let now = Date()
            let rawC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)

            guard let rid = resolveRouteId(for: b.routeNo) else { continue }
            let cid = compoundBusId(routeId: rid, rawVehId: b.id)
            var bus = BusLive(
                id: cid, routeNo: b.routeNo,
                lat: b.lat, lon: b.lon,
                etaMinutes: b.etaMinutes,
                nextStopName: b.nextStopName
            )
            let isFollowed = (followBusId == bus.id)

            // 1) 트랙
            let nowC = CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
            if tracks[bus.id] == nil {
                tracks[bus.id] = BusTrack(prevLoc: nil, prevAt: nil, lastLoc: nowC, lastAt: now)
                out.append(bus)
                continue
            }
            var tr = tracks[bus.id]!

            // 2) 점프/EMA
            let step = CLLocation(latitude: tr.lastLoc.latitude, longitude: tr.lastLoc.longitude)
                .distance(from: CLLocation(latitude: nowC.latitude, longitude: nowC.longitude))
            let dt = max(0.01, now.timeIntervalSince(tr.lastAt))
            let instMps = step / dt

            var acceptAsJump = false
            if step > MAX_STEP_M {
                if isFollowed && step <= FOLLOW_STEP_ALLOW_METERS { acceptAsJump = true }
                else if instMps <= MAX_PLAUSIBLE_MPS { acceptAsJump = true }
            }
            if step > MAX_STEP_M && !acceptAsJump {
                out.append(bus); continue
            }

            let alpha = acceptAsJump ? 0.9 : EMA_ALPHA
            let smooth = CLLocationCoordinate2D(
                latitude:  tr.lastLoc.latitude  * (1 - alpha) + nowC.latitude  * alpha,
                longitude: tr.lastLoc.longitude * (1 - alpha) + nowC.longitude * alpha
            )
            tr.prevLoc = tr.lastLoc
            tr.prevAt  = tr.lastAt
            tr.lastLoc = smooth
            tr.lastAt  = now
            tr.updateKinematics()
            tracks[bus.id] = tr

            // 3) 메타/사영
            guard let meta = snap.metaById[rid],
                  let rStops = snap.stopsByRouteId[rid],
                  let prj = projectOnRoute(smooth, shape: meta.shape, cumul: meta.cumul)
            else {
                let pred = tr.coastPredict(at: now.addingTimeInterval(0.6),
                                           decay: COAST_DECAY_PER_SEC, minSpeed: COAST_MIN_SPEED)
                bus.lat = pred.latitude
                bus.lon = pred.longitude
                if let prev = lastETAMinByBusId[bus.id] { bus.etaMinutes = prev }
                if followBusId == bus.id {
                    let c = CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
                    trail.appendIfNeeded(c); trailVersion &+= 1
                }
                out.append(bus)
                continue
            }

            if prj.lateral > LATERAL_MAX_M {
                if let prev = lastETAMinByBusId[bus.id] { bus.etaMinutes = prev }
                if followBusId == bus.id {
                    let c = CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
                    trail.appendIfNeeded(c); trailVersion &+= 1
                }
                out.append(bus)
                continue
            }

            // 사영 스냅
            bus.lat = prj.snapped.latitude
            bus.lon = prj.snapped.longitude

            // 4) 다음 정류장/ETA
            let stopS = meta.stopS
            let count = min(stopS.count, rStops.count)
            guard count > 0 else { out.append(bus); continue }

            var passed = lastPassedStopIndex[bus.id] ?? -1
            while passed + 1 < count && (prj.s - stopS[passed + 1]) >= PASS_GATE_M {
                passed += 1
            }
            if let last = lastPassedStopIndex[bus.id] { passed = max(passed, last) }
            lastPassedStopIndex[bus.id] = passed

            let nextIdx = min(passed + 1, count - 1)
            let nextStop = rStops[nextIdx]
            bus.nextStopName = nextStop.name

            let remaining = max(0, stopS[nextIdx] - prj.s)
            let vObs = max(0.1, tr.speedMps)
            let vForETA = max(SPEED_FLOOR_MPS, vObs)
            var sec = Int(remaining / vForETA)
            if vObs < 1.2 && remaining < NEAR_STOP_M { sec = 0 }
            let rawETA = max(0, Int((Double(sec)/60.0).rounded(.toNearestOrEven)))
            if let e = smoothETA(rawETA: rawETA, busId: bus.id, distToNextStop: remaining) {
                bus.etaMinutes = e
                lastETAMinByBusId[bus.id] = e
            } else if let prev = lastETAMinByBusId[bus.id] {
                bus.etaMinutes = prev
            }

            // 정류장 스냅
            maybeSnapToStop(&bus)

            // 팔로우: 트레일/하이라이트/미래경로
            if followBusId == bus.id {
                let c = CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
                trail.appendIfNeeded(c); trailVersion &+= 1
                highlightedStopId = nextStop.id
                setFutureRouteByStops(meta: meta, from: prj, nextIdx: nextIdx, maxAheadStops: 7, includeTerminal: false)
            }

            out.append(bus)
        }
        return out
    }

    // ADD: 컴파운드 ID
    private func compoundBusId(routeId: String, rawVehId: String) -> String {
        return "\(routeId)#\(rawVehId)"
    }

    // -------------- 세 번째 코드 뭉치에 있던 추가 메서드들 --------------

    // ADD: 정류장 경유 꺾은선(중복 2m 제거)
    private func buildFutureRouteStopByStop(
        meta: RouteMeta,
        prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double),
        nextStartIdx: Int
    ) -> [CLLocationCoordinate2D] {
        guard meta.shape.count >= 2, meta.shape.count == meta.cumul.count else { return [] }
        guard nextStartIdx < meta.stopS.count else { return [prj.snapped] }

        var coords: [CLLocationCoordinate2D] = [prj.snapped]
        var curSeg = prj.seg
        var curS   = prj.s

        for j in nextStartIdx ..< meta.stopS.count {
            let targetS = meta.stopS[j]
            var i = max(curSeg + 1, 0)
            while i < meta.cumul.count, meta.cumul[i] < targetS {
                coords.append(meta.shape[i]); i += 1
            }
            coords.append(meta.stopCoords[j])
            curSeg = min(max(i - 1, 0), meta.shape.count - 2)
            curS   = targetS
        }
        if coords.count >= 2 {
            var cleaned: [CLLocationCoordinate2D] = [coords[0]]
            for c in coords.dropFirst() {
                let d = CLLocation(latitude: cleaned.last!.latitude, longitude: cleaned.last!.longitude)
                    .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                if d >= 2 { cleaned.append(c) }
            }
            return cleaned
        } else {
            return coords
        }
    }

    // ADD: 국토부 routeId 판별
    private func isMotieRouteId(_ id: String) -> Bool {
        return Int(id) != nil || id.hasPrefix("DJB")
    }

    // ADD: 다가오는 정류장 기반 빨간선 재그리기
    func redrawFutureRouteFromUpcoming(busId: String, maxCount: Int = 7) {
        guard let live = buses.first(where: { $0.id == busId }) else { return }
        let here = CLLocationCoordinate2D(latitude: live.lat, longitude: live.lon)

        let routeNo = routeNoById[busId] ?? live.routeNo
        guard let rid = resolveRouteId(for: routeNo),
              let meta = routeMetaById[rid],
              meta.shape.count >= 2,
              meta.shape.count == meta.cumul.count,
              let prj = projectOnRoute(here, shape: meta.shape, cumul: meta.cumul) else {
            setTemporaryFutureRouteFromBus(busId: busId, coordinate: here, meters: 1200)
            return
        }

        let raw = upcomingStops(for: busId, maxCount: maxCount)
        var seen = Set<String>()
        let nexts = raw.filter { seen.insert($0.id).inserted }

        var coords: [CLLocationCoordinate2D] = [prj.snapped]
        for it in nexts {
            if let j = meta.stopIds.firstIndex(of: it.id) {
                coords.append(meta.stopCoords[j])
            }
        }
        if coords.count >= 2 { futureRouteCoords = coords } else { futureRouteCoords.removeAll() }
        futureRouteVersion &+= 1
    }
    
    
   

    // REPLACE: 도착정보 → 상위 리스트(최소 ETA/정렬/캐시 채움)
    private func computeTopArrivals(
        allArrivals: [ArrivalInfo],
        followedRouteNo: String?
    ) -> [ArrivalInfo] {
        var bestByRoute: [String: ArrivalInfo] = [:]
        for a in allArrivals {
            routeIdByRouteNo[a.routeNo] = a.routeId
            lastKnownRouteIdByRouteNo[a.routeNo] = a.routeId
            routeNoByRouteId[a.routeId] = a.routeNo
            if let num = numericRouteId(from: a.routeId) { numericRouteIdByRouteNo[a.routeNo] = num }

            if let cur = bestByRoute[a.routeId] {
                if a.etaMinutes < cur.etaMinutes { bestByRoute[a.routeId] = a }
            } else {
                bestByRoute[a.routeId] = a
            }
        }
        var top = Array(bestByRoute.values)
        if let fr = followedRouteNo {
            top.sort { lhs, rhs in
                if lhs.routeNo == fr { return true }
                if rhs.routeNo == fr { return false }
                return lhs.etaMinutes < rhs.etaMinutes
            }
        } else {
            top.sort { $0.etaMinutes < $1.etaMinutes }
        }
        return top
    }
    
    




    // REPLACE: 정류장 스냅(드웰/ETA=0)
    private func maybeSnapToStop(_ b: inout BusLive) {
        guard let rid = resolveRouteId(for: b.routeNo),
              let meta = routeMetaById[rid],
              let idxPassed = lastPassedStopIndex[b.id] else {
            if let until = dwellUntil[b.id], until < Date() { dwellUntil.removeValue(forKey: b.id) }
            return
        }

        let nextIdx = min(idxPassed + 1, meta.stopS.count - 1)
        let targetLat = meta.stopCoords[nextIdx].latitude
        let targetLon = meta.stopCoords[nextIdx].longitude

        let d = CLLocation(latitude: b.lat, longitude: b.lon)
            .distance(from: CLLocation(latitude: targetLat, longitude: targetLon))

        if d < snapRadius {
            let until = dwellUntil[b.id] ?? .distantPast
            if until < Date() { dwellUntil[b.id] = Date().addingTimeInterval(dwellSec) }

            b.lat = targetLat
            b.lon = targetLon
            b.nextStopName = stops.first(where: { $0.id == meta.stopIds[nextIdx] })?.name ?? b.nextStopName
            b.etaMinutes = 0
            // ✅ 스냅 성공 로그
                Telemetry.shared.mark(.etaSnapToStop, tags:["busId": b.id, "stopId": meta.stopIds[nextIdx]])

        } else {
            if let until = dwellUntil[b.id], until < Date() { dwellUntil.removeValue(forKey: b.id) }
        }
    }

    
    
    
}

extension BusAPI {
    /// 국토부: 노선번호로 routeId 목록 조회 (숫자 routeId 확보용) + 상세 로그
    func fetchRouteIdsByRouteNo(cityCode: Int, routeNo: String) async throws -> [String] {
        let url = try urlWithEncodedKey(
            base: "https://apis.data.go.kr/1613000/BusRouteInfoInqireService/getRouteNoList",
            items: [
                .init(name: "pageNo", value: "1"),
                .init(name: "numOfRows", value: "300"),
                .init(name: "_type", value: "json"),
                .init(name: "type", value: "json"),
                .init(name: "cityCode", value: String(cityCode)),
                .init(name: "routeNo", value: routeNo)
            ])

        struct Root: Decodable {
            struct Resp: Decodable { let body: Body? }
            struct Body: Decodable { let items: ItemsFlex<Item>? }
            struct Item: Decodable {
                let routeid: FlexString?
                let routeno: FlexString?
            }
            let response: Resp?
        }

        let (data, http) = try await send("RouteNoList", url: url)

        // 원본 일부 덤프
        if let s = String(data: data, encoding: .utf8) {
            print("🔎 RouteNoList raw(\(http.statusCode)): \(min(240, s.count)) chars → \(s.prefix(240))")
        }

        if isLikelyXML(data) {
            let arr = try parseXMLItems(data)
            let out = arr.compactMap { $0["routeid"] }
            print("🔎 RouteNoList(XML) for routeNo=\(routeNo) → \(out.count) ids: \(out.prefix(5))")
            return out
        } else {
            let r = try JSONDecoder().decode(Root.self, from: data)
            let items = r.response?.body?.items?.values ?? []
            let out = items.compactMap { $0.routeid?.value }
            let nums = out.filter { Int($0) != nil }
            print("🔎 RouteNoList(JSON) for routeNo=\(routeNo) → total=\(out.count), numeric=\(nums.count), sample=\(out.prefix(5))")
            return out
        }
    }
}



enum BusProvider { case motie /*국토부*/, daejeon }
private let provider: BusProvider = .daejeon   // ← 임시로 대전 active

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
    
    // ✅ 추가: 콜백
       var onAskAlarmForStop: ((BusStop) -> Void)? = nil
       var onToggleSelectStop: ((BusStop) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true

        // ✅ 무조건 대전 시청에서 시작
        let startCenter = CLLocationCoordinate2D(latitude: 36.351, longitude: 127.385)

        map.region = MKCoordinateRegion(
            center: startCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.045, longitudeDelta: 0.045)
        )
        map.pointOfInterestFilter = .includingAll
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "stop")
        map.register(BusMarkerView.self, forAnnotationViewWithReuseIdentifier: "bus")
        map.register(ClusterView.self,
                     forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)

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
        var desiredStops = vm.stops
        // ✅ 하이라이트 정류장을 강제로 포함(화면 반경 밖이어도 색 바뀌도록)
        if let hs = vm.highlightedBusStop(),
           !desiredStops.contains(where: { $0.id == hs.id }) {
            desiredStops.append(hs)
        }
        let desiredBuses = vm.buses
        let desiredStopIds = Set(desiredStops.map { $0.id })

        // add/remove
        let stopsToAdd    = desiredStops.filter { !currentStopIds.contains($0.id) }.map { BusStopAnnotation($0) }
        let stopsToRemove = currentStops.filter { !desiredStopIds.contains($0.stop.id) }

        var busAnnoById = Dictionary(uniqueKeysWithValues: currentBuses
            .filter { !$0.id.isEmpty }
            .map { ($0.id, $0) })
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
            if let sel = vm.followBusId, sel == leftover.id { continue } // ✅ 팔로우 삭제 금지
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
        if let followId = vm.followBusId, vm.stickToFollowedBus {
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
        // updateUIView 내 배치 후
        context.coordinator.updateTrailOverlay(uiView)       // 주황(지나온) 갱신
        context.coordinator.updateFutureRouteOverlay(uiView) // 빨강(미래) 갱신
        // 정류장 색상 안전망
        context.coordinator.recolorStops(uiView)



    }

    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, MKMapViewDelegate {
        let parent: ClusteredMapView
        private let deb = Debouncer()
        private var isAutoRecentering = false
        private var isApplyingDiff = false
        private var isTweakingFollowAppearance = false    // 재진입/중복 호출 가드


        init(_ p: ClusteredMapView) { parent = p }
        
        
        // ADD: 미래경로 오버레이 갱신
        func updateFutureRouteOverlay(_ mapView: MKMapView) {
            let olds = mapView.overlays.compactMap { $0 as? MKPolyline }.filter { ($0.title ?? "") == "futureRoute" }
            if !olds.isEmpty { mapView.removeOverlays(olds) }
            let coords = parent.vm.futureRouteCoords
            guard coords.count >= 2 else { return }
            let line = MKPolyline(coordinates: coords, count: coords.count)
            line.title = "futureRoute"
            mapView.addOverlay(line)
        }
        // ClusteredMapView.Coord 내부에 추가
      



        // REPLACE: 팔로우 틴트/클러스터 예외 일괄 반영
        func updateFollowTints(_ mapView: MKMapView) {
            if isApplyingDiff || isTweakingFollowAppearance {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak mapView] in
                    guard let self, let mapView else { return }
                    self.updateFollowTints(mapView)
                }
                return
            }
            isTweakingFollowAppearance = true
            let annoSnapshot: [MKAnnotation] = Array(mapView.annotations)

            UIView.performWithoutAnimation {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let followed = parent.vm.followBusId

                for anno in annoSnapshot {
                    guard let a = anno as? BusAnnotation,
                          let v = mapView.view(for: a) as? BusMarkerView else { continue }

                    let isFollowed = (a.id == followed)
                    let newClusterId = isFollowed ? "bus-\(a.id)" : "bus"
                    if v.clusteringIdentifier != newClusterId { v.clusteringIdentifier = newClusterId }
                    v.configureTint(isFollowed: isFollowed)
                    v.displayPriority = .required
                    v.layer.zPosition = 10
                }
                CATransaction.commit()
            }
            isTweakingFollowAppearance = false
        }
        
        // REPLACE: add/remove + 모델업데이트 + 뷰후처리
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
                let present = Set(mapView.annotations.map { ObjectIdentifier($0) })
                let updatingBusIds = Set(busUpdates.map { $0.0.id })
                let followedId = self.parent.vm.followBusId
                let selectedIds = Set(mapView.selectedAnnotations.compactMap { ($0 as? BusAnnotation)?.id })

                let safeStopsToRemove = stopsToRemove.filter { present.contains(ObjectIdentifier($0)) }
                let safeBusesToRemove: [MKAnnotation] = busesToRemove.compactMap { a in
                    guard present.contains(ObjectIdentifier(a)) else { return nil }
                    guard let b = a as? BusAnnotation else { return a }
                    if let fid = followedId, fid == b.id { return nil }
                    if selectedIds.contains(b.id) { return nil }
                    if updatingBusIds.contains(b.id) { return nil }
                    return b
                }

                UIView.performWithoutAnimation {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    if !safeStopsToRemove.isEmpty || !safeBusesToRemove.isEmpty {
                        mapView.removeAnnotations(safeStopsToRemove + safeBusesToRemove)
                    }
                    if !stopsToAdd.isEmpty || !busesToAdd.isEmpty {
                        mapView.addAnnotations(stopsToAdd + busesToAdd)
                    }
                    CATransaction.commit()
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak mapView] in
                    guard let self, let mapView else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    for (anno, live) in busUpdates { anno.applyModelOnly(live) }
                    CATransaction.commit()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak mapView] in
                        guard let self, let mapView else { return }
                        for (anno, _) in busUpdates {
                            if let mv = mapView.view(for: anno) as? BusMarkerView { mv.updateAlwaysOnBubble() }
                        }
                        self.updateFollowTints(mapView)
                        self.recolorStops(mapView)
                        self.safeDeconflictAll(mapView)
                        self.isApplyingDiff = false
                    }
                }
            }
        }

        // ADD: 겹침 해소(가장 가까운 정류장 기준으로 6pt 밀어내기)
        func safeDeconflictAll(_ mapView: MKMapView) {
            DispatchQueue.main.async {
                let buses = mapView.annotations.compactMap { $0 as? BusAnnotation }
                let stops = mapView.annotations.compactMap { $0 as? BusStopAnnotation }

                for bus in buses {
                    guard let v = mapView.view(for: bus) else { continue }
                    let defaultOffset = CGPoint(x: 0, y: -10)

                    guard let nearest = stops.min(by: { lhs, rhs in
                        let dl = CLLocation(latitude: lhs.coordinate.latitude, longitude: lhs.coordinate.longitude)
                            .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))
                        let dr = CLLocation(latitude: rhs.coordinate.latitude, longitude: rhs.coordinate.longitude)
                            .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))
                        return dl < dr
                    }) else {
                        (v as? MKAnnotationView)?.centerOffset = defaultOffset
                        continue
                    }

                    let dist = CLLocation(latitude: nearest.coordinate.latitude, longitude: nearest.coordinate.longitude)
                        .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))

                    let threshold: CLLocationDistance = 8.0
                    guard dist <= threshold else {
                        (v as? MKAnnotationView)?.centerOffset = defaultOffset
                        continue
                    }

                    let dx = bus.coordinate.longitude - nearest.coordinate.longitude
                    let dy = bus.coordinate.latitude  - nearest.coordinate.latitude
                    let mag = max(1e-9, sqrt(dx*dx + dy*dy))
                    let bump: CGFloat = 6.0
                    let px = CGFloat(dx / mag) * bump
                    let py = CGFloat(-dy / mag) * bump
                    (v as? MKAnnotationView)?.centerOffset = CGPoint(x: defaultOffset.x + px, y: defaultOffset.y + py)
                }
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
        // ClusteredMapView.Coord
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let s = annotation as? BusStopAnnotation {
                print("▶ STOP CALLOUT TAPPED:")  // 🔍 꼭 찍히는지 확인

                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "stop", for: s) as! MKMarkerAnnotationView
                v.canShowCallout = true          // ✅ 이게 빠져서 버튼이 안 보였던 것

                v.clusteringIdentifier = nil
                v.glyphText = "🚏"
                v.titleVisibility = .visible
                v.subtitleVisibility = .hidden
                v.displayPriority = .required
                v.layer.zPosition = 100

              
                
                // === ✅ 왼쪽 액세서리: 아이콘 + 접근성 라벨 ===
                let left = UIButton(type: .system)
                let selected = parent.vm.isStopSelected(s.stop.id)
//                left.setImage(UIImage(systemName: selected ? "checkmark.circle.fill" : "circle"), for: .normal)
//                left.accessibilityLabel = selected ? "선택해제" : "선택"
//                left.tintColor = .label
//                left.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
//                left.sizeToFit()                               // ✅ 크기 확보
//                v.leftCalloutAccessoryView = left
//
//                // === ✅ 오른쪽 액세서리: 종 아이콘(텍스트보다 안전) ===
//                let right = UIButton(type: .system)
//                right.setImage(UIImage(systemName: "bell.badge.fill"), for: .normal)
//                right.accessibilityLabel = "알람"
//                right.tintColor = .label
//                right.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
//                right.sizeToFit()                              // ✅ 크기 확보
//                v.rightCalloutAccessoryView = right

                // 색상: 하이라이트(노랑) > 내가 고정한 정류장(주황) > 일반(빨강)
                // ClusteredMapView.Coord - viewFor annotation 정류소 분기 내 색상 로직 교체
                let isAlarmed = parent.vm.alarmedStopIds.contains(s.stop.id)
                let isHighlighted = (parent.vm.highlightedStopId == s.stop.id) // 쓰지 않으면 제거

                if isAlarmed {
                    v.markerTintColor = .systemYellow        // ← 알람이 최우선
                } else if parent.vm.isStopSelected(s.stop.id) {
                    v.markerTintColor = .systemOrange
                } else {
                    v.markerTintColor = .systemRed
                }

                return v
            } else if let b = annotation as? BusAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "bus", for: b) as! BusMarkerView
                let isFollowed = (parent.vm.followBusId == b.id)
                v.clusteringIdentifier = isFollowed ? "bus-\(b.id)" : "bus" // 클러스터 예외
                v.configureTint(isFollowed: isFollowed)
                v.displayPriority = .required
                v.layer.zPosition = 100
                v.canShowCallout = true
                let btn = UIButton(type: .system)
                btn.setTitle(isFollowed ? "해제" : "추적", for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
                v.rightCalloutAccessoryView = btn
                v.updateAlwaysOnBubble()

                // CRASH FIX: 여기서 다른 annotation에 접근/열거 금지
                // (겹침 해소는 배치 후 safeDeconflictAll에서 수행)

                return v
            } else if let cluster = annotation as? MKClusterAnnotation {
                let cv = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                    for: cluster
                )
                cv.layer.zPosition = 80
                return cv
            }
            return nil
        }

        // ClusteredMapView.Coord
        /// 정류소와 매우 가까울 때, '좌표'는 건드리지 않고 '뷰'만 살짝 비켜놓아 겹침을 피한다.
        /// - 주의: centerOffset(포인트 단위)을 쓰므로 추적/계산/클러스터링에 영향 없음.
        private func applyVisualDeconflictIfNearStop(_ mapView: MKMapView,
                                                    view v: MKAnnotationView,
                                                    bus: BusAnnotation) {
            // 기본 오프셋(버스 마커의 원래 시각적 위치)
            let defaultOffset = CGPoint(x: 0, y: -10)

            // 맵에 현재 보이는 정류소들 스냅샷
            let stopAnnos = mapView.annotations.compactMap { $0 as? BusStopAnnotation }
            guard let nearest = stopAnnos.min(by: { lhs, rhs in
                let dl = CLLocation(latitude: lhs.coordinate.latitude, longitude: lhs.coordinate.longitude)
                    .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))
                let dr = CLLocation(latitude: rhs.coordinate.latitude, longitude: rhs.coordinate.longitude)
                    .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))
                return dl < dr
            }) else {
                // 정류소가 없으면 기본값 유지
                v.centerOffset = defaultOffset
                return
            }

            // 버스-정류소 거리(m)
            let dist = CLLocation(latitude: nearest.coordinate.latitude, longitude: nearest.coordinate.longitude)
                .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))

            // 임계값(겹친다고 보기): 8m
            let threshold: CLLocationDistance = 8.0
            guard dist <= threshold else {
                v.centerOffset = defaultOffset
                return
            }

            // 가까우면 '뷰'를 살짝(포인트 기준) 비켜놓는다.
            // 지도 스케일을 몰라도 시각적으로 충분한 미세 오프셋: 6pt 정도
            // 정류소→버스 방향을 대략 반영하여 살짝 치우치게 표시
            let dx = bus.coordinate.longitude - nearest.coordinate.longitude
            let dy = bus.coordinate.latitude  - nearest.coordinate.latitude
            let mag = max(1e-9, sqrt(dx*dx + dy*dy))
            let ux = dx / mag
            let uy = dy / mag

            // 지도의 위쪽(-y)이 시각적으로 위로 올라가므로 y는 반대로 준다
            let bump: CGFloat = 6.0
            let px = CGFloat(ux) * bump
            let py = CGFloat(-uy) * bump

            v.centerOffset = CGPoint(x: defaultOffset.x + px, y: defaultOffset.y + py)
        }


        
        // **탭 토글**: 같은 버스를 다시 누르면 해제, 아니면 추적 시작
        // ClusteredMapView.Coord
        // ClusteredMapView.Coord
        // ClusteredMapView.Coord
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {

            // 1) 버스 탭: 기존 추적 토글 로직 유지
            if let bus = view.annotation as? BusAnnotation {
                let already = (parent.vm.followBusId == bus.id)
                if already {
                    parent.vm.followBusId = nil
                    Telemetry.shared.mark(.busFollowStart, tags:["busId": bus.id, "routeNo": bus.routeNo])

                    if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: false) }
                } else {
                    parent.vm.followBusId = bus.id
                    Telemetry.shared.mark(.busFollowStop, tags:["busId": bus.id])

                    if parent.vm.stickToFollowedBus { follow(bus, on: mapView) }
                    if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: true); mv.updateAlwaysOnBubble() }
                    parent.vm.startTrail(for: bus.id, seed: bus.coordinate)
                    parent.vm.clearFutureRoute()
                    parent.vm.setTemporaryFutureRouteFromBus(busId: bus.id, coordinate: bus.coordinate)
                    self.updateFutureRouteOverlay(mapView)
                    if let rid = parent.vm.routeId(forRouteNo: bus.routeNo) {
                        parent.vm.ensureRouteMetaWithRetry(routeId: rid)
                        parent.vm.trySetFutureRouteImmediately(for: bus)
                        self.updateFutureRouteOverlay(mapView)
                    }
                    if let live = parent.vm.buses.first(where: { $0.id == bus.id }) {
                        parent.vm.updateHighlightStop(for: live)
                        self.recolorStops(mapView)
                    }
                    Task { await self.parent.vm.onBusSelected(bus) }
                }
                // UX: 셀렉션 하이라이트는 바로 해제
                mapView.deselectAnnotation(bus, animated: false)
                return
            }

            // 2) 정류소 탭: 포커스 세팅 + ETA 로드
            if let stop = view.annotation as? BusStopAnnotation {
                Task { [weak self, weak mapView] in
                    guard let self, let mapView else { return }

                    // 패널 포커스 + ETA
                    await MainActor.run { self.parent.vm.setFocusStop(stop.stop) }
                    await self.parent.vm.refreshFocusStopETA()

                    // ✅ 같은 정류소를 다시 눌러도 didSelect가 또 호출되도록 즉시 해제
                    DispatchQueue.main.async {
                        mapView.deselectAnnotation(stop, animated: false)
                    }
                }
                return
            }
//            if let stop = view.annotation as? BusStopAnnotation {
//                Task { [weak self] in
//                    guard let self else { return }
//                    await MainActor.run { self.parent.vm.setFocusStop(stop.stop) }   // 패널 표시 트리거
//                    await self.parent.vm.refreshFocusStopETA()                        // ETA 채우기
//                }
//                return
//            }
        }




        // 콜아웃 버튼으로도 토글
        // ClusteredMapView.Coord
        // ClusteredMapView.Coord
        func mapView(_ mapView: MKMapView,
                     annotationView view: MKAnnotationView,
                     calloutAccessoryControlTapped control: UIControl) {

            // ① 버스: 기존 추적 토글 로직 그대로 유지
            if let bus = view.annotation as? BusAnnotation {
                if parent.vm.followBusId == bus.id {
                    Telemetry.shared.mark(.busFollowStop, tags:["busId": bus.id])

                    // 추적 해제
                    parent.vm.followBusId = nil
                    mapView.deselectAnnotation(bus, animated: true)
                    if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: false) }
                    if let mv = view as? BusMarkerView,
                       let btn = mv.rightCalloutAccessoryView as? UIButton {
                        btn.setTitle("추적", for: .normal)
                    }
                    parent.vm.stopTrail()
                    parent.vm.clearFutureRoute()
                    self.updateFutureRouteOverlay(mapView)
                    parent.vm.highlightedStopId = nil
                } else {
                    // 추적 시작
                    Telemetry.shared.mark(.busFollowStart, tags:["busId": bus.id, "routeNo": bus.routeNo])

                    parent.vm.followBusId = bus.id
                    if parent.vm.stickToFollowedBus {
                        follow(bus, on: mapView)
                    }
                    if let mv = view as? BusMarkerView {
                        mv.configureTint(isFollowed: true)
                        mv.updateAlwaysOnBubble()
                    }
                    if let mv = view as? BusMarkerView,
                       let btn = mv.rightCalloutAccessoryView as? UIButton {
                        btn.setTitle("해제", for: .normal)
                    }
                    parent.vm.startTrail(for: bus.id, seed: bus.coordinate)
                    DispatchQueue.main.async { [weak self, weak mapView] in
                        guard let self, let mapView else { return }
                        self.updateFollowTints(mapView)
                    }
                }
                return
            }

            // ② 정류소: 알람 처리만 (선택/해제 버튼 제거)
            if let stop = view.annotation as? BusStopAnnotation {
                if control === view.rightCalloutAccessoryView {
                    parent.onAskAlarmForStop?(stop.stop)
                }
                return
            }
        }



        // 지도가 움직였을 때: 사용자 제스처가 아니더라도, 팔로우 중이면 주기적으로 정류장 재로딩
        // ClusteredMapView.Coord
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // CRASH FIX: 내부 열거 직후 연쇄 호출 경합 완화 (0.30s)
            deb.call(after: 0.30) {
                self.parent.vm.onRegionCommitted(mapView.region)
            }
        }

        
        
        // REPLACE: renderer
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: line)
            if line.title == "busTrail" {
                r.strokeColor = .systemOrange
                r.lineWidth = 4
                r.lineJoin = .round
                r.lineCap  = .round
                return r
            } else if line.title == "futureRoute" {
                r.strokeColor = .systemRed
                r.lineWidth = 4
                r.lineJoin = .round
                r.lineCap  = .round
                return r
            } else {
                r.strokeColor = .systemGray
                r.lineWidth = 3
                return r
            }
        }
        
        
        
        // REPLACE: 정류장 컬러 동기화
        func recolorStops(_ mapView: MKMapView) {
            for a in mapView.annotations {
                guard let s = a as? BusStopAnnotation,
                      let v = mapView.view(for: s) as? MKMarkerAnnotationView else { continue }

                if parent.vm.alarmedStopIds.contains(s.stop.id) {
                    v.markerTintColor = .systemYellow
                } else if parent.vm.isStopSelected(s.stop.id) {
                    v.markerTintColor = .systemOrange
                } else {
                    v.markerTintColor = .systemRed
                }
            }
        }




        // 트레일 업데이트 유틸
        func updateTrailOverlay(_ mapView: MKMapView) {
            // 기존 트레일 제거
            let olds = mapView.overlays.filter { ($0 as? MKPolyline)?.title == "busTrail" }
            mapView.removeOverlays(olds)
            // 새 트레일 추가
            if let line = parent.vm.trail.polyline() {
                mapView.addOverlay(line)
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
    // BusMapScreen
    @State private var noticeText: String? = nil      // 서버 문자열(또는 "공지 없음")
    @State private var hideNoticeThisSession = false  // 세션 전용 닫힘 상태

    @StateObject private var vm = MapVM()
    @StateObject private var loc = LocationAuth()
    @State private var recenterRequest = false
    
    @State private var showBanner = false     // 노출 여부
    @State private var debugText = ""
        @State private var bannerMounted = false
        @StateObject private var banner = BannerAdController()
    
    // ✅ 알람 시트 상태
       @State private var showAlarmSheet = false
       @State private var alarmTargetStop: BusStop? = nil

       // 시트에 넘길 기본값
       @State private var alarmDate: Date = Date().addingTimeInterval(5*60)
       @State private var repeatMinutesText: String = ""
    
    // ✅ 상단 버튼에 표시할 “예약 알림 개수”
        @State private var pendingAlertCount: Int = 0
    
    var body: some View {
            ZStack {
                ClusteredMapView(
                    vm: vm,
                    recenterRequest: $recenterRequest,
                    onAskAlarmForStop: { stop in
                        Task {
                            // 1) 패널 포커스 + ETA 최신화
                            await MainActor.run { vm.setFocusStop(stop) }
                            await vm.refreshFocusStopETA()

                            // 2) 권한 확인
                            let ok = await LocalAlertCenter.shared.requestPermissionIfNeeded()
                            guard ok else { return }

                            // 3) ETA 요약 (예: "101 3분 · 612 5분 · …")
                            let summary = vm.focusStopETAs
                                .sorted { $0.etaMinutes < $1.etaMinutes }
                                .prefix(6)
                                .map { "\($0.routeNo) \($0.etaMinutes)분" }
                                .joined(separator: " · ")

                            // 4) 5분 뒤 단발 알림 예약 (본문에 ETA 요약 포함)
                            let fire = Date().addingTimeInterval(5 * 60)
                            LocalAlertCenter.shared.scheduleOneTime(
                                stop: stop,
                                routes: nil,
                                at: fire,
                                etaSummary: summary   // ← extraBody 아님!
                            )
                            // ✅ 예약 로그
                            Telemetry.shared.mark(.localAlertScheduled, tags:["stopId": stop.id])
                            // 5) 알람 표시(노란색) 유지
                            vm.setAlarmed(true, stopId: stop.id)

                            // 6) 카운트 갱신
                            pendingAlertCount = await LocalAlertCenter.shared.pendingCount()
                        }
                    }
                    // 선택 패널은 더이상 쓰지 않으면 파라미터 자체를 제거해도 됩니다.
                    // , onToggleSelectStop: { stop in vm.toggleStopSelection(stop.id) }
                )
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
                .padding(.top, 24)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

//            // 고정 “추적 중” 배지
//            .overlay(alignment: .topLeading) {
//                TrackingBadgeView(vm: vm)
//                    .padding(.top, 8)
//                    .padding(.leading, 8)
//                    .padding(.trailing, 8)
//            }

            // 왼쪽 하단 다가오는 정류장 패널(버스 추적 중)
            .overlay(alignment: .bottomLeading) {
                UpcomingPanelView(vm: vm)
                    .padding(.leading, 8)
                    .padding(.bottom, 12)
            }

            // 왼쪽 중간 ETA 패널 (정류소 탭 시)
            .overlay(alignment: .leading) {
                StopETAInfoPanel(vm: vm, onTapAlarm: {
                    if let s = vm.focusStop {
                        alarmTargetStop = s
                        showAlarmSheet = true
                    }
                })
                .padding(.leading, 8)
                .padding(.top, 120)     // "왼쪽 중간쯤" 위치 보정
                .allowsHitTesting(true)
            }

            // 상단 왼쪽 전체 알람 끄기
        // 기존:
        // .overlay(alignment: .topLeading) { TrackingBadgeView(vm: vm) ... }
        // .overlay(alignment: .topLeading) { Button { ... } label: { ... } ... }

        // 교체:
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                // 🎯 추적 중 배지 (없으면 자동으로 빈 뷰)
                TrackingBadgeView(vm: vm)
                    .padding(.trailing, 8)

                // 🔔 알람 끄기 버튼 (항상 표시)
                Button {
                    Task {
                        await LocalAlertCenter.shared.cancelAll()
                        vm.clearAllAlarms()
                        pendingAlertCount = await LocalAlertCenter.shared.pendingCount()
                        Telemetry.shared.mark(.localAlertCanceledAll)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.slash.fill")
                        Text(pendingAlertCount > 0 ? "알람 끄기 (\(pendingAlertCount))" : "알람 끄기")
                            .font(.caption).bold()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 2)
                }
            }
            .padding(.top, 8)
            .padding(.leading, 8)
        }

//            .overlay(alignment: .bottomTrailing) {
//                DebugHUD().padding([.trailing, .bottom], 8)
//            }

        // BusMapScreen.body 어딘가

        // BusMapScreen.body 의 modifier 체인 어딘가
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { @MainActor in
                await NoticeCenter.shared.fetchOnce()
            }
        }




            // 최초 진입 시/재진입 시 개수 동기화
            .task {
                pendingAlertCount = await LocalAlertCenter.shared.pendingCount()
            }

            // 상단 배너
//            .safeAreaInset(edge: .top) {
//                VStack(spacing: 6) {
//                    // 1) 광고
//                    AdFitVerboseBannerView(
//                        clientId: "DAN-0pxnvDh8ytVm0EsZ",
//                        adUnitSize: "320x50",
//                        timeoutSec: 8,
//                        maxRetries: 2
//                    ) { event in
//                        switch event {
//                        case .begin(let n):  debugText = "BEGIN \(n)"
//                        case .willLoad:      debugText = "WILL_LOAD"
//                        case .success(let ms):
//                            showBanner = true
//                            debugText = "SUCCESS \(ms)ms"
//                        case .fail(let err, let n):
//                            showBanner = false
//                            debugText = "FAIL(\(n)): \(err.localizedDescription)"
//                        case .timeout(let sec, let n):
//                            showBanner = false
//                            debugText = "TIMEOUT \(sec)s (attempt \(n))"
//                        case .retryScheduled(let after, let next):
//                            debugText = "RETRY in \(after)s → \(next)"
//                        case .disposed:
//                            debugText = "disposed"
//                        }
//                    }
//                    .frame(width: 320, height: 50)
//                    .opacity(showBanner ? 1 : 0)
//                    .allowsHitTesting(showBanner)
//
//                    // 공지 바 (광고 바로 아래)
//                    NoticeBarView()
//                                        .fixedSize(horizontal: false, vertical: true)
//                                        .padding(.horizontal, 8)
//                }
////                .padding(.vertical, 8)                 // 위아래 살짝 여백
////                .frame(maxWidth: .infinity, alignment: .top)
////                .animation(.easeInOut(duration: 0.2), value: showBanner)
//            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 6) {
                   
                    BannerAdView(controller: banner)
                        .frame(height: 50)              // 일반 배너 높이
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial) // 구분감
                        .shadow(radius: 1)
                    // 공지 바 (광고 바로 아래)
                            NoticeBarView()
                                .fixedSize(horizontal: false, vertical: true)   // 줄바꿈 시 높이만 늘어나게
                                .padding(.horizontal, 8)
                }
                .padding(.vertical, 8)                 // 위아래 살짝 여백
                .frame(maxWidth: .infinity, alignment: .top)
                .animation(.easeInOut(duration: 0.2), value: showBanner)
            }
            .task {
                        NoticeCenter.shared.startAutoRefresh()
                    }
                    // ✅ 포그라운드 복귀 시 갱신
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                        Task {
                            await NoticeCenter.shared.startAutoRefresh()
                        }
                    }

            // 알람 설정 시트
            .sheet(isPresented: $showAlarmSheet) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("정류장 알림").font(.title3).bold()
                    if let s = alarmTargetStop {
                        Text("정류장: \(s.name)").font(.subheadline)
                    }

                    Group {
                        Text("특정 시각에 한 번 울리기").font(.footnote).foregroundStyle(.secondary)
                        DatePicker("시간", selection: $alarmDate, displayedComponents: [.hourAndMinute, .date])
                    }

                    Divider()

                    Group {
                        Text("반복 알림 (분 단위)").font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            TextField("예: 10", text: $repeatMinutesText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                            Text("분마다")
                        }
                    }

                    HStack {
                        Button("닫기") { showAlarmSheet = false }
                        Spacer()
                        Button("저장") {
                            Task {
                                guard let s = alarmTargetStop else { return }
                                let ok = await LocalAlertCenter.shared.requestPermissionIfNeeded()
                                guard ok else { return }

                                // 현재 포커스 ETA 요약문
                                let summary = vm.focusETACompactSummary()

                                if let m = Int(repeatMinutesText), m >= 1 {
                                    LocalAlertCenter.shared.scheduleRepeating(
                                        stop: s,
                                        routes: nil,
                                        every: m,
                                        etaSummary: summary
                                    )
                                } else {
                                    LocalAlertCenter.shared.scheduleOneTime(
                                        stop: s,
                                        routes: nil,
                                        at: alarmDate,
                                        etaSummary: summary
                                    )
                                }
                                // ✅ 예약 로그
                                Telemetry.shared.mark(.localAlertScheduled, tags:["stopId": s.id])
                                // 알람 표식(노란색) 유지
                                vm.setAlarmed(true, stopId: s.id)

                                // 닫고 카운트 갱신
                                showAlarmSheet = false
                                pendingAlertCount = await LocalAlertCenter.shared.pendingCount()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .presentationDetents([.height(360), .medium])
            }
        // BusMapScreen.swift  (body의 modifier 체인 어딘가, 예: .safeAreaInset 아래나 위)
        .onReceive(NotificationCenter.default.publisher(for: .stopAlertOpened)) { note in
            guard let stopId = note.userInfo?["stopId"] as? String,
                  let stop = vm.stopById(stopId) else { return }

            Task {
                // 포커스 세팅 + ETA 로딩
                await MainActor.run { vm.setFocusStop(stop) }
                await vm.refreshFocusStopETA()

                // (선택) 지도도 그 정류소로 부드럽게 이동시키고 싶으면:
                // vm.recenter(to: stop.coordinate) 같은 메서드가 있으면 호출
                // 없으면, 지도 센터 이동 로직을 vm→Coordinator로 흘려보내는 작은 파이프를 하나 만들어도 OK
            }
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


// 새 파일 or MapVM 내부
import MapKit

/// 과거 이동경로(트레일) 저장소
final class BusTrailStore {
    
    private(set) var currentBusId: String?
        private var points: [CLLocationCoordinate2D] = []
        private let maxCount: Int = 800
        private let minStepMeters: CLLocationDistance = 6

        func start(id: String, seed: CLLocationCoordinate2D?) {
            currentBusId = id
            points.removeAll()
            if let s = seed, CLLocationCoordinate2DIsValid(s) { points.append(s) }
        }
        func stop() { currentBusId = nil; points.removeAll() }

        func appendIfNeeded(_ c: CLLocationCoordinate2D) {
            guard CLLocationCoordinate2DIsValid(c) else { return }
            if let last = points.last {
                let d = CLLocation(latitude: last.latitude, longitude: last.longitude)
                    .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                if d < minStepMeters { return }
            }
            points.append(c)
            if points.count > maxCount { points.removeFirst(points.count - maxCount) }
        }

        func polyline() -> MKPolyline? {
            guard points.count >= 2 else { return nil }
            let line = MKPolyline(coordinates: points, count: points.count)
            line.title = "busTrail"
            return line
        }
    
    
    
    

}


// 새 파일로 두거나, 같은 파일 하단에 추가

import SwiftUI

struct UpcomingStopsPanel: View {
    @ObservedObject var vm: MapVM
    let maxCount: Int = 7

    // 계산 프로퍼티로 분리 (ViewBuilder 바깥)
    // 기존
    // private var items: [UpcomingStopETA] {
    //     guard let fid = vm.followBusId else { return [] }
    //     return vm.upcomingStops(for: fid, maxCount: maxCount)
    // }

    // 변경
    private var items: [UpcomingStopETA] {
        guard let fid = vm.followBusId else { return [] }
        let arr = vm.upcomingStops(for: fid, maxCount: maxCount)
        var seen = Set<String>()
        // ▶ id 기준, 최초 1회만 통과 (안정적인 순서 유지)
        return arr.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        Group {
            if vm.followBusId != nil {
                if items.isEmpty {
                    // 메타/경로 로딩 중인 상태도 패널이 보이게
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("경로 불러오는 중…")
                            .font(.caption)
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(radius: 2)
                    .frame(maxWidth: 260)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("🧭 다음 정류장").font(.caption).bold()
                            Text("(\(items.count))").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(items) { it in
                            HStack(spacing: 10) {
                                Text(it.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                Text("\(it.etaMin)분")
                                    .font(.caption).monospacedDigit()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(radius: 2)
                    .frame(maxWidth: 260)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.bottom, 10)
        .allowsHitTesting(false)     // 맵 제스처 방해 X
        .transition(.move(edge: .leading).combined(with: .opacity))
        .zIndex(999)                 // 다른 오버레이 위로
    }
}

// 새 파일 또는 같은 파일 하단
struct UpcomingPanelView: View {
    @ObservedObject var vm: MapVM

    var body: some View {
        Group {
            if let fid = vm.followBusId {
                if let live = vm.buses.first(where: { $0.id == fid }) {
                    UpcomingPanelContent(vm: vm, fid: fid, live: live)
                }
            }
        }
    }
}

private struct UpcomingPanelContent: View {
    @ObservedObject var vm: MapVM
    let fid: String
    let live: BusLive

    var body: some View {
        // 목록 생성
        let itemsRaw = vm.upcomingStops(for: fid, maxCount: 7)
        let items: [UpcomingStopETA] = {
            var seen = Set<String>()
            return itemsRaw.filter { seen.insert($0.id).inserted }
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("🗺️ \(live.routeNo)")
                    .font(.caption).bold()
                Text(live.nextStopName ?? "다음 정류장 추정중…")
                    .font(.caption)
                    .lineLimit(1)
            }

            ForEach(items, id: \.id) { it in
                HStack {
                    Circle().frame(width: 6, height: 6)
                    Text(it.name).font(.caption).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(it.etaMin)분").font(.caption2).monospacedDigit()
                }
            }

            if items.isEmpty {
                Text("경로 메타 없음 — 근처/방향 기반으로 추정중")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 2)
        // 빨간 라인 갱신
        .onAppear {
            vm.redrawFutureRouteFromUpcoming(busId: fid, maxCount: 7)
        }
        .onChange(of: vm.upcomingTick) { _ in
            vm.redrawFutureRouteFromUpcoming(busId: fid, maxCount: 7)
        }
        .onChange(of: vm.followBusId) { _ in
            if let fid2 = vm.followBusId {
                vm.redrawFutureRouteFromUpcoming(busId: fid2, maxCount: 7)
            }
        }
        .onChange(of: items.map(\.id).joined(separator: "|")) { _ in
            vm.redrawFutureRouteFromUpcoming(busId: fid, maxCount: 7)
        }
    }
}
import Foundation
import UserNotifications

import UIKit

@MainActor
final class LocalAlertCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalAlertCenter()
       private override init() {
           super.init()
           let center = UNUserNotificationCenter.current()
           center.delegate = self
           registerCategories()
       }

       func requestPermissionIfNeeded() async -> Bool {
           let center = UNUserNotificationCenter.current()
           let settings = await center.notificationSettings()
           if settings.authorizationStatus == .authorized { return true }
           do { return try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
           catch { return false }
       }

       func scheduleOneTime(stop: BusStop, routes: [String]?, at date: Date, etaSummary: String? = nil) {
           let content = buildContent(stop: stop, routes: routes, bodyPrefix: "도착 알림", etaSummary: etaSummary)
           let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
           let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
           let id = "one-\(stop.id)-\(UUID().uuidString)"
           let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
           UNUserNotificationCenter.current().add(req)
       }

       func scheduleRepeating(stop: BusStop, routes: [String]?, every minutes: Int, etaSummary: String? = nil) {
           let content = buildContent(stop: stop, routes: routes, bodyPrefix: "주기적 알림", etaSummary: etaSummary)
           let interval = max(60, minutes * 60)
           let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(interval), repeats: true)
           let id = "rep-\(stop.id)-\(minutes)m"
           let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
           UNUserNotificationCenter.current().add(req)
       }

       func cancelAll() async {
           UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
           UIApplication.shared.applicationIconBadgeNumber = 0
       }

       func pendingCount() async -> Int {
           await withCheckedContinuation { cont in
               UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
                   cont.resume(returning: reqs.count)
               }
           }
       }

       func pendingCount(for stopId: String) async -> Int {
           await withCheckedContinuation { cont in
               UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
                   let n = reqs.filter { $0.identifier.contains(stopId) }.count
                   cont.resume(returning: n)
               }
           }
       }

       func cancel(for stopId: String) async {
           await withCheckedContinuation { cont in
               UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
                   let ids = reqs.filter { $0.identifier.contains(stopId) }.map(\.identifier)
                   UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
                   cont.resume()
               }
           }
       }

       nonisolated
       func userNotificationCenter(_ center: UNUserNotificationCenter,
                                   willPresent notification: UNNotification,
                                   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
           completionHandler([.banner, .list, .sound])
       }

       nonisolated
       func userNotificationCenter(_ center: UNUserNotificationCenter,
                                   didReceive response: UNNotificationResponse,
                                   withCompletionHandler completionHandler: @escaping () -> Void) {
           DispatchQueue.main.async {
               defer { completionHandler() }
               let userInfo = response.notification.request.content.userInfo
               guard let stopId = userInfo["stopId"] as? String else { return }
               NotificationCenter.default.post(name: .stopAlertOpened, object: nil, userInfo: ["stopId": stopId])
           }
       }

       private func buildContent(stop: BusStop,
                                 routes: [String]?,
                                 bodyPrefix: String,
                                 etaSummary: String?) -> UNMutableNotificationContent {
           let c = UNMutableNotificationContent()
           c.title = "🚌 \(stop.name)"
           var parts: [String] = [bodyPrefix]
           if let rs = routes, !rs.isEmpty { parts.append("노선 \(rs.joined(separator: ", "))") }
           if let s = etaSummary, !s.isEmpty { parts.append(s) }
           c.body = parts.joined(separator: " • ")
           c.sound = .default
           c.userInfo = ["stopId": stop.id, "stopName": stop.name]
           c.categoryIdentifier = "STOP_ETA"
           return c
       }

       private func registerCategories() {
           let cat = UNNotificationCategory(identifier: "STOP_ETA",
                                            actions: [],
                                            intentIdentifiers: [],
                                            options: [])
           UNUserNotificationCenter.current().setNotificationCategories([cat])
       }
    
    
    
    
    
 
}


struct StopETAInfoPanel: View {
    @ObservedObject var vm: MapVM
    var onTapAlarm: () -> Void
    
    var body: some View {
        if let s = vm.focusStop {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("🚏 \(s.name)")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button { withAnimation { vm.setFocusStop(nil) } } label: {
                        Image(systemName: "xmark")
                    }
                }
                
                if vm.focusStopLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("ETA 불러오는 중…").font(.caption)
                    }
                } else if vm.focusStopETAs.isEmpty {
                    Text("도착 정보 없음")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    etaList()   // ✅ 여기
                }
                
                HStack {
                    Button {
                        Task { await vm.refreshFocusStopETA() }
                    } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                    
                    Spacer()
                    
                    Button { onTapAlarm() } label: {
                        Label("알람", systemImage: "bell.badge.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .font(.caption)
            }
            .padding(10)
            .frame(maxWidth: 280)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 2)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
        
    }
    
    
    // ✅ 에러 없이 컴파일 잘 되는 리스트 렌더링
    @ViewBuilder
    private func etaList() -> some View {
        let etas: [ArrivalInfo] = self.vm.focusStopETAs   // ✅ self.vm 사용
        
        VStack(alignment: .leading, spacing: 6) {
            // ✅ id 명시해서 Binding 오버로드가 아니라 값 오버로드를 강제
            ForEach(etas, id: \.id) { a in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(a.routeNo)
                        .bold()
                        .frame(minWidth: 44, alignment: .leading)
                    
                    Text("\(a.etaMinutes)분")
                        .font(.callout)
                        .monospacedDigit()
                    
                    Spacer(minLength: 8)
                    
                    if let dest = a.destination, !dest.isEmpty {
                        Text(dest)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }
    
    
    
    
    
}


// AppDelegate.swift
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Telemetry.shared.start()
        Telemetry.shared.setCommonTags(Telemetry.defaultTags())   // ✅ 이 줄 필수

        if let url = URL(string: "http://13.124.208.108:8899/metrics") {
//        if let url = URL(string: "http://localhost:8899/metrics") {
            Telemetry.shared.use(HTTPSink(endpoint: url))
        }
        UNUserNotificationCenter.current().delegate = self
        return true
    }

       func userNotificationCenter(_ center: UNUserNotificationCenter,
                                   didReceive response: UNNotificationResponse,
                                   withCompletionHandler completionHandler: @escaping () -> Void) {

           let userInfo = response.notification.request.content.userInfo
           DispatchQueue.main.async {
               defer { completionHandler() }
               guard let stopId = userInfo["stopId"] as? String,
                     let stop = MapVM.shared.stopById(stopId) else { return }

               MapVM.shared.setFocusStop(stop)
               Task { @MainActor in
                   await MapVM.shared.refreshFocusStopETA()
               }
           }
       }

       func userNotificationCenter(_ center: UNUserNotificationCenter,
                                   willPresent notification: UNNotification,
                                   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
           completionHandler([.banner, .list, .sound])
       }
    

}
// AppNavigator.swift (작은 브릿지)
final class AppNavigator {
    static let shared = AppNavigator()
        weak var vm: MapVM?

        func bind(vm: MapVM) { self.vm = vm }

        func handleNotification(stopId: String) {
            guard let vm else { return }
            DispatchQueue.main.async {
                if let s = vm.stopById(stopId) {
                    Task { @MainActor in
                        vm.setFocusStop(s)
                        await vm.refreshFocusStopETA()
                    }
                }
                vm.setAlarmed(true, stopId: stopId)
            }
        }
}
