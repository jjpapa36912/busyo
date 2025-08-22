////
////  Service.swift
////  busyo
////
////  Created by 김동준 on 8/12/25.
////
//
//import Foundation
//import SwiftUI
//import MapKit
//import CoreLocation
//import Combine
//struct Stop: Identifiable, Hashable {
//    let id: String          // 정류장 ID
//    let name: String
//    let coordinate: CLLocationCoordinate2D
//
//    static func == (lhs: Stop, rhs: Stop) -> Bool {
//        lhs.id == rhs.id &&
//        lhs.name == rhs.name &&
//        lhs.coordinate.latitude == rhs.coordinate.latitude &&
//        lhs.coordinate.longitude == rhs.coordinate.longitude
//    }
//    func hash(into hasher: inout Hasher) {
//        hasher.combine(id); hasher.combine(name)
//        hasher.combine(coordinate.latitude); hasher.combine(coordinate.longitude)
//    }
//}
//
//struct Vehicle: Identifiable, Hashable {
//    let id: String          // 차량 ID
//    let route: String       // 노선 번호 (예: 402)
//    var coordinate: CLLocationCoordinate2D
//    var heading: CLLocationDirection
//    var etaMinutes: Int?    // 선택된/가까운 정류장까지 남은 분
//
//    static func == (lhs: Vehicle, rhs: Vehicle) -> Bool {
//        lhs.id == rhs.id && lhs.route == rhs.route &&
//        lhs.coordinate.latitude == rhs.coordinate.latitude &&
//        lhs.coordinate.longitude == rhs.coordinate.longitude &&
//        lhs.heading == rhs.heading && lhs.etaMinutes == rhs.etaMinutes
//    }
//    func hash(into hasher: inout Hasher) {
//        hasher.combine(id); hasher.combine(route)
//        hasher.combine(coordinate.latitude); hasher.combine(coordinate.longitude)
//        hasher.combine(heading); hasher.combine(etaMinutes)
//    }
//}
//
//// 통합 annotation 아이템 (iOS16 Map annotationItems 용)
//struct MapItem: Identifiable, Hashable {
//    let id: String
//    let coordinate: CLLocationCoordinate2D
//    let title: String?          // 정류장명 또는 노선번호
//    let isVehicle: Bool
//    let heading: CLLocationDirection?
//    let etaMinutes: Int?
//
//    static func == (lhs: MapItem, rhs: MapItem) -> Bool {
//        lhs.id == rhs.id &&
//        lhs.coordinate.latitude == rhs.coordinate.latitude &&
//        lhs.coordinate.longitude == rhs.coordinate.longitude &&
//        lhs.title == rhs.title && lhs.isVehicle == rhs.isVehicle &&
//        lhs.heading == rhs.heading && lhs.etaMinutes == rhs.etaMinutes
//    }
//    func hash(into hasher: inout Hasher) {
//        hasher.combine(id)
//        hasher.combine(coordinate.latitude)
//        hasher.combine(coordinate.longitude)
//        hasher.combine(title)
//        hasher.combine(isVehicle)
//        hasher.combine(heading)
//        hasher.combine(etaMinutes)
//    }
//}
//
//// MARK: - Bus API
//protocol BusAPI {
//    func fetchNearbyStops(center: CLLocationCoordinate2D, radiusMeters: Double) async throws -> [Stop]
//    func fetchVehicles(around center: CLLocationCoordinate2D, near stops: [Stop]) async throws -> [Vehicle]
//}
//
//// 서울 실데이터용 API 어댑터 (키 필요). 키 없으면 모크로 폴백
//final class SeoulBusAPI: BusAPI {
//    // TODO: 여기에 본인 키를 넣으세요 (서울 열린데이터 or ODsay 중 택1)
//    // 아래는 형식 예시일 뿐입니다.
//    private let SEOUL_API_KEY: String = "" // ← 키 입력
//
//    // 시청 근처 테스트 좌표 (GPS 고정)
//    private let fixedCenter = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
//
//    // MARK: 주변 정류장
//    func fetchNearbyStops(center: CLLocationCoordinate2D, radiusMeters: Double) async throws -> [Stop] {
//        // 키 없으면 모크로 반환 (시청 인근 대표 정류장 4곳)
//        guard !SEOUL_API_KEY.isEmpty else {
//            return [
//                Stop(id: "10188", name: "서울시청앞", coordinate: .init(latitude: 37.566002, longitude: 126.978388)),
//                Stop(id: "10037", name: "광화문", coordinate: .init(latitude: 37.571404, longitude: 126.976889)),
//                Stop(id: "10157", name: "을지로입구", coordinate: .init(latitude: 37.566930, longitude: 126.982266)),
//                Stop(id: "10246", name: "덕수궁", coordinate: .init(latitude: 37.565331, longitude: 126.975154))
//            ]
//        }
//        // 실제 호출 예시 (엔드포인트는 사용하는 제공처에 맞게 교체)
//        // 예: ODsay "nearByBusStation" 또는 서울시 "getStationByPos" 등
//        // 여기서는 키 보안/가용성 때문에 모크 경로를 유지합니다.
//        return []
//    }
//
//    // MARK: 차량/도착정보
//    func fetchVehicles(around center: CLLocationCoordinate2D, near stops: [Stop]) async throws -> [Vehicle] {
//        // 키 없으면 임시 가짜 차량 3대(노선번호 포함) 생성해 애니메이션용으로 반환
//        guard !SEOUL_API_KEY.isEmpty else {
//            let base = fixedCenter
//            let routes = ["402", "172", "150"]
//            return routes.enumerated().map { i, r in
//                let angle = Double(i)/3 * 2 * .pi
//                let lat = base.latitude + 0.002 * sin(angle)
//                let lon = base.longitude + 0.002 * cos(angle)
//                return Vehicle(
//                    id: "mockVeh_\(i)",
//                    route: r,
//                    coordinate: .init(latitude: lat, longitude: lon),
//                    heading: angle * 180 / .pi,
//                    etaMinutes: Int.random(in: 2...12)
//                )
//            }
//        }
//        // 실제 구현 시: 정류장 ID들로 도착정보/차량위치 API 호출 → Vehicle 배열 구성
//        return []
//    }
//}
//
//// MARK: - ViewModel
//@MainActor
//final class TransitViewModel: ObservableObject {
//    @Published var region: MKCoordinateRegion
//    @Published var stops: [Stop] = []
//    @Published var vehicles: [Vehicle] = []
//    @Published var selectedStop: Stop?
//
//    private let api: BusAPI
//    private var timer: AnyCancellable?
//
//    // 서울 시청으로 고정 시작
//    init(api: BusAPI = SeoulBusAPI()) {
//        let center = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
//        self.api = api
//        self.region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
//    }
//
//    func load() {
//        Task { await refreshStopsAndStartPolling() }
//    }
//
//    private func refreshStopsAndStartPolling() async {
//        do {
//            let center = region.center
//            let s = try await api.fetchNearbyStops(center: center, radiusMeters: 1000)
//            self.stops = s
//            self.selectedStop = s.first
//        } catch { print("Stops error:", error) }
//
//        startPolling()
//    }
//
//    private func startPolling() {
//        timer?.cancel()
//        timer = Timer.publish(every: 12, on: .main, in: .common)
//            .autoconnect()
//            .prepend(Date())
//            .sink { [weak self] _ in
//                guard let self = self else { return }
//                Task { await self.refreshVehicles() }
//            }
//    }
//
//    private func refreshVehicles() async {
//        do {
//            let vs = try await api.fetchVehicles(around: region.center, near: stops)
//            withAnimation(.linear(duration: 0.25)) { self.vehicles = vs }
//        } catch { print("Vehicles error:", error) }
//    }
//}
