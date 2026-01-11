//
//  Notice.swift
//  busyo
//
//  Created by 김동준 on 10/14/25.
//

import Foundation
import os.log

// 로깅 카테고리 정의
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "busyo", category: "NoticeCenter")

struct RemoteNotice: Codable, Equatable {
    struct Body: Codable, Equatable {
        let message: String
        let level: String   // "info" | "warn" | "urgent"
        let link: String?
        let startAt: String?
        let endAt: String?
    }
    let notice: Body?
}

@MainActor
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()

    @Published var notice: RemoteNotice.Body?
    @Published var lastFetchError: String?
    @Published var hideThisSession: Bool = false   // ← 이번 앱 실행 동안만 숨김

    private let endpoint = URL(string: "http://13.124.208.108:1213/notice")!
    private let etagKey = "notice.etag"
    private var timer: Task<Void, Never>?

    func startAutoRefresh() {
        logger.info("🔄 NoticeCenter: startAutoRefresh 호출됨")
        timer?.cancel()
        timer = Task {
            var wait: Double = 0 // 즉시 1회
            var fetchCount = 0
            while !Task.isCancelled {
                if wait > 0 {
                    logger.debug("⏰ NoticeCenter: \(wait)초 대기 중...")
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                
                fetchCount += 1
                logger.info("📡 NoticeCenter: fetch 시작 (횟수: \(fetchCount))")
                await fetchOnce()
                
                // 정상/304 → 10분, 에러 → 지수 백오프 상한 30분
                wait = (lastFetchError == nil) ? 600 : min((wait == 0 ? 30 : wait * 2), 1800)
                logger.debug("⏱️ NoticeCenter: 다음 fetch까지 \(wait)초 대기 설정 (에러: \(self.lastFetchError ?? "없음"))")
            }
            logger.warning("⚠️ NoticeCenter: Task가 취소됨")
        }
    }

    func stopAutoRefresh() {
        logger.info("⏹️ NoticeCenter: stopAutoRefresh 호출됨")
        timer?.cancel()
        timer = nil
    }

    /// 이번 앱 실행에서만 공지를 숨김 (앱 재시작 시 다시 보임)
    func dismissForThisSession() {
        logger.info("👋 NoticeCenter: 공지를 이번 세션에서 숨김 처리")
        hideThisSession = true
    }

    func fetchOnce() async {
        logger.info("🌐 NoticeCenter: fetchOnce 시작 - URL: \(self.endpoint.absoluteString)")
        
        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 8
        if let etag = UserDefaults.standard.string(forKey: etagKey) {
            logger.debug("🏷️ NoticeCenter: 저장된 ETag 사용: \(etag)")
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        } else {
            logger.debug("🏷️ NoticeCenter: 저장된 ETag 없음 (첫 요청)")
        }

        do {
            logger.debug("📤 NoticeCenter: URLSession 요청 시작...")
            let (data, resp) = try await URLSession.shared.data(for: req)
            logger.info("📥 NoticeCenter: 응답 수신 완료 (데이터 크기: \(data.count) bytes)")
            
            // ⬇️ 원본 문자열 찍기
               if let raw = String(data: data, encoding: .utf8) {
                   logger.debug("🧾 NoticeCenter: raw response=\(raw)")
               } else {
                   logger.debug("🧾 NoticeCenter: raw response (non-UTF8, size=\(data.count))")
               }
            
            guard let http = resp as? HTTPURLResponse else {
                logger.error("❌ NoticeCenter: HTTPURLResponse로 캐스팅 실패")
                return
            }

            logger.info("📊 NoticeCenter: HTTP 상태 코드: \(http.statusCode)")

            if http.statusCode == 304 {
                // 변경 없음
                logger.info("✅ NoticeCenter: 304 Not Modified - 공지 변경 없음")
                self.lastFetchError = nil
                return
            }
            guard http.statusCode == 200 else {
                logger.error("❌ NoticeCenter: HTTP 에러 - 상태 코드: \(http.statusCode)")
                self.lastFetchError = "HTTP \(http.statusCode)"
                // 실패 시에도 플레이스홀더로 표시
                self.notice = RemoteNotice.Body(message: "공지 없음", level: "info", link: nil, startAt: nil, endAt: nil)
                return
            }

            if let et = http.value(forHTTPHeaderField: "ETag") {
                logger.debug("🏷️ NoticeCenter: 새 ETag 저장: \(et)")
                UserDefaults.standard.set(et, forKey: etagKey)
            }

            logger.debug("🔍 NoticeCenter: JSON 디코딩 시작...")
            let decoded = try JSONDecoder().decode(RemoteNotice.self, from: data)
            logger.info("✅ NoticeCenter: JSON 디코딩 성공")
            
            // 기간 필터
            let validated = Self.validated(decoded.notice)
            self.notice = validated
            self.lastFetchError = nil
            
            if let v = validated {
                logger.info("📢 NoticeCenter: 유효한 공지 설정됨 - 레벨: \(v.level), 메시지 길이: \(v.message.count)")
            } else {
                logger.info("⏰ NoticeCenter: 공지가 기간 필터링으로 제외됨")
            }

            // 새로운 공지가 들어오면 이번 세션 숨김 해제(다시 보여주기)
            self.hideThisSession = false
            logger.debug("👁️ NoticeCenter: hideThisSession = false (새 공지로 인한 재표시)")

        } catch let error as URLError {
            logger.error("❌ NoticeCenter: URLError 발생 - 코드: \(error.code.rawValue), 설명: \(error.localizedDescription)")
            self.lastFetchError = error.localizedDescription
            // 네트워크 실패 → '공지 없음' 플레이스홀더
            self.notice = RemoteNotice.Body(message: "공지 없음", level: "info", link: nil, startAt: nil, endAt: nil)
        } catch let error as DecodingError {
            logger.error("❌ NoticeCenter: JSON 디코딩 에러 - \(error.localizedDescription)")
            self.lastFetchError = "디코딩 실패: \(error.localizedDescription)"
            self.notice = RemoteNotice.Body(message: "공지 없음", level: "info", link: nil, startAt: nil, endAt: nil)
        } catch {
            logger.error("❌ NoticeCenter: 알 수 없는 에러 - \(error.localizedDescription)")
            self.lastFetchError = error.localizedDescription
            // 네트워크 실패 → '공지 없음' 플레이스홀더
            self.notice = RemoteNotice.Body(message: "공지 없음", level: "info", link: nil, startAt: nil, endAt: nil)
        }
    }

    private static func validated(_ n: RemoteNotice.Body?) -> RemoteNotice.Body? {
        guard let n else {
            logger.debug("⚪ NoticeCenter: validated - notice가 nil")
            return nil
        }
        let iso = ISO8601DateFormatter()
        let now = Date()
        
        if let s = n.startAt, let d = iso.date(from: s), now < d {
            logger.info("⏰ NoticeCenter: validated - 아직 시작 전 (startAt: \(s), 현재: \(now))")
            return nil
        }
        if let e = n.endAt, let d = iso.date(from: e), now > d {
            logger.info("⏰ NoticeCenter: validated - 이미 종료됨 (endAt: \(e), 현재: \(now))")
            return nil
        }
        
        logger.debug("✅ NoticeCenter: validated - 공지 유효함")
        return n
    }
}


import SwiftUI

struct NoticeBarView: View {
    @ObservedObject var center = NoticeCenter.shared

    @State private var isExpanded: Bool = false
    private let maxExpandedHeight: CGFloat = 160   // 펼쳤을 때 최대 높이(스크롤)

    var body: some View {
        if !center.hideThisSession, let n = center.notice {
            HStack(alignment: .top, spacing: 10) {
                // 아이콘
                Image(systemName: n.message == "공지 없음"
                      ? "info.circle"
                      : (n.level == "urgent" ? "exclamationmark.triangle.fill"
                        : n.level == "warn" ? "exclamationmark.circle.fill"
                        : "megaphone.fill"))
                    .font(.system(size: 14, weight: .bold))
                    .padding(.top, 2)

                // 본문(접기/펼치기)
                VStack(alignment: .leading, spacing: 6) {
                    if isExpanded {
                        ScrollView(showsIndicators: true) {
                            Text(n.message)
                                .font(.footnote).bold()
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, 4)
                        }
                        .frame(maxHeight: maxExpandedHeight)
                        .transition(.opacity)
                    } else {
                        Text(n.message)
                            .font(.footnote).bold()
                            .lineLimit(2)
                            .transition(.opacity)
                    }

                    // 액션들 (플레이스홀더는 행동 버튼 숨김)
                    if n.message != "공지 없음" {
                        HStack(spacing: 8) {
                            Button(isExpanded ? "접기" : "더보기") {
                                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                            }
                            .font(.caption2).bold()
                            .buttonStyle(.bordered)
//
//                            if let link = n.link, let url = URL(string: link), !link.isEmpty {
//                                Button("열기") {
//                                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
//                                }
//                                .font(.caption2).bold()
//                                .buttonStyle(.bordered)
//                            }

                            Spacer(minLength: 8)
                        }
                        .padding(.top, 2)
                    }
                }

                // 닫기(X) — 플레이스홀더일 땐 X 숨김(기존 정책 유지)
                if n.message != "공지 없음" {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            center.dismissForThisSession()  // 이번 앱 실행에서만 숨김
                        }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("공지 닫기")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(background(for: n), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .fixedSize(horizontal: false, vertical: true) // 줄바꿈 시 높이 자연 확장
            .animation(.easeInOut(duration: 0.2), value: isExpanded)
        }
    }

    private func background(for n: RemoteNotice.Body) -> Color {
        if n.message == "공지 없음" { return .gray }
        switch n.level {
        case "urgent": return .red
        case "warn":   return .orange
        default:       return .blue
        }
    }
}
