import Foundation
import os
import UIKit
extension TelemetryEvent {
    /// 이 이벤트가 속한 타이머 쌍의 begin/end를 돌려준다.
    var beginEvent: TelemetryEvent {
        switch self {
        case .fetchStopsBegin, .fetchStopsEnd:         return .fetchStopsBegin
        case .fetchArrivalsBegin, .fetchArrivalsEnd:   return .fetchArrivalsBegin
        case .fetchBusLocBegin, .fetchBusLocEnd:       return .fetchBusLocBegin
        case .mapReloadBegin, .mapReloadEnd:           return .mapReloadBegin
        default:                                       return self   // 단독 이벤트는 자기 자신
        }
    }

    var endEvent: TelemetryEvent {
        switch self {
        case .fetchStopsBegin, .fetchStopsEnd:         return .fetchStopsEnd
        case .fetchArrivalsBegin, .fetchArrivalsEnd:   return .fetchArrivalsEnd
        case .fetchBusLocBegin, .fetchBusLocEnd:       return .fetchBusLocEnd
        case .mapReloadBegin, .mapReloadEnd:           return .mapReloadEnd
        default:                                       return self   // 단독 이벤트는 자기 자신
        }
    }
}
enum TelemetryEvent: String {
    case appLaunch, mapReloadBegin, mapReloadEnd, busFollowStart, busFollowStop
    case fetchStopsBegin, fetchStopsEnd, fetchArrivalsBegin, fetchArrivalsEnd, fetchBusLocBegin, fetchBusLocEnd
    case ensureRouteMetaHit, ensureRouteMetaMiss, ensureRouteMetaFail
    case etaObserved, etaSmoothed, etaSnapToStop
    case localAlertScheduled, localAlertCanceledAll
    case error
}

struct Metric: Codable {
    let t: Date
    let name: String
    let tags: [String: String]
    let fields: [String: Double]
}

protocol MetricsSink {
    func send(_ payload: [Metric])
}

final class ConsoleSink: MetricsSink {
    func send(_ payload: [Metric]) {
        payload.forEach { m in
            print("📊 \(m.name) tags=\(m.tags) fields=\(m.fields)")
        }
    }
}

final class FileSink: MetricsSink {
    private let url: URL
    init(filename: String = "telemetry.ndjson") {
        url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }
    func send(_ payload: [Metric]) {
        guard let h = try? FileHandle(forWritingTo: url) ?? { try? "".data(using: .utf8)?.write(to: url); return try! FileHandle(forWritingTo: url) }() else { return }
        defer { try? h.close() }
        for m in payload {
            if let d = try? JSONEncoder().encode(m),
               let line = String(data: d, encoding: .utf8)?.appending("\n").data(using: .utf8) {
                h.seekToEndOfFile()
                h.write(line)
            }
        }
    }
}

final class HTTPSink: MetricsSink {
    private let endpoint: URL
    init(endpoint: URL) { self.endpoint = endpoint }
    func send(_ payload: [Metric]) {
        guard !payload.isEmpty else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(payload)
        URLSession.shared.dataTask(with: req).resume()
    }
}

final class Telemetry {
    static let shared = Telemetry()
    private var buffer: [Metric] = []
    private let lock = NSLock()
    private var sinks: [MetricsSink] = [ConsoleSink()]
    private var timer: Timer?
    private var commonTags: [String:String] = [:]

    func use(_ sink: MetricsSink) { sinks.append(sink) }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.flush()
        }
    }
   

       // 공통 태그 세팅
       func setCommonTags(_ tags: [String:String]) {
           lock.lock(); defer { lock.unlock() }
           commonTags = tags
       }

       // 앱/빌드/OS 정보 자동 수집
       static func defaultTags() -> [String:String] {
           var tags: [String:String] = [:]
           let info = Bundle.main.infoDictionary
           let bundle = Bundle.main.bundleIdentifier ?? "unknown.bundle"
           tags["app"] = bundle                           // ← 서버가 이 키를 폴더명으로 씀
           tags["app_version"] = (info?["CFBundleShortVersionString"] as? String) ?? "0"
           tags["build"] = (info?["CFBundleVersion"] as? String) ?? "0"
           tags["os"] = "iOS"
           tags["os_version"] = UIDevice.current.systemVersion
           tags["device"] = UIDevice.current.model
           return tags
       }
    func stop() { timer?.invalidate(); timer = nil; flush() }

    func mark(_ evt: TelemetryEvent,
              tags: [String:String] = [:],
              fields: [String:Double] = [:]) {
        let m = Metric(t: Date(), name: evt.rawValue, tags: tags, fields: fields)
        lock.lock(); buffer.append(m); lock.unlock()

        // ✅ 디버그 HUD 카운터도 업데이트
        if evt == .error {
            DispatchQueue.main.async {
                DebugCounter.shared.errors += 1
            }
        }
        if evt == .fetchStopsEnd || evt == .fetchArrivalsEnd || evt == .fetchBusLocEnd {
            DispatchQueue.main.async {
                DebugCounter.shared.requests += 1
            }
        }
    }

    

    // time 측정 래퍼에도 동일 병합(있다면)
        func time<T>(_ evt: TelemetryEvent,
                     tags: [String:String] = [:],
                     _ block: () async throws -> T) async rethrows -> T {
            let begin = Date()
            let mergedBegin = mergeCommonTags(tags)
            mark(evt.beginEvent, tags: mergedBegin)
            do {
                let result = try await block()
                let ms = Date().timeIntervalSince(begin) * 1000
                let mergedEnd = mergeCommonTags(tags.merging(["status":"ok"]) { $1 })
                mark(evt.endEvent, tags: mergedEnd, fields: ["ms": ms])
                return result
            } catch {
                let ms = Date().timeIntervalSince(begin) * 1000
                let mergedEnd = mergeCommonTags(tags.merging(["status":"error"]) { $1 })
                mark(evt.endEvent, tags: mergedEnd, fields: ["ms": ms])
                throw error
            }
        }

        private func mergeCommonTags(_ tags: [String:String]) -> [String:String] {
            lock.lock(); let base = commonTags; lock.unlock()
            return base.merging(tags) { _, new in new }
        }
    private func flush() {
        lock.lock()
        let batch = buffer
        buffer.removeAll()
        lock.unlock()
        guard !batch.isEmpty else { return }
        sinks.forEach { $0.send(batch) }
    }
}
