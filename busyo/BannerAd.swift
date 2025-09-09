import SwiftUI
import GoogleMobileAds
import UIKit

// v11 대응: GADBannerViewDelegate -> BannerViewDelegate
final class BannerAdController: NSObject, ObservableObject, BannerViewDelegate {
    // v11 대응: GADBannerView -> BannerView
    let bannerView: BannerView

    override init() {
        // v11 대응: GADAdSizeBanner -> AdSizeBanner
        self.bannerView = BannerView(adSize: AdSizeBanner)
        super.init()

        // ⚠️ App 시작 시 한 번은 반드시 초기화 (App.swift 등)
        // GADMobileAds.sharedInstance().start(completionHandler: nil)

        self.bannerView.adUnitID = {
            #if DEBUG
            return "ca-app-pub-3940256099942544/2934735716" // 테스트용
            #else
            return "ca-app-pub-2190585582842197/1921225714" // 실제 광고 ID
            #endif
        }()

        self.bannerView.delegate = self
        // ✅ v11도 load 전 rootViewController 반드시 지정
        self.bannerView.rootViewController = Self.topViewController()

        // v11 대응: GADRequest() -> Request()
        self.bannerView.load(Request())
    }

    func reload() {
        print("🔄 Reloading Ad...")
        bannerView.load(Request())
    }

    // MARK: - BannerViewDelegate (v11)

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        print("✅ 배너 광고 로딩 성공")
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        print("❌ 배너 광고 로딩 실패: \(error.localizedDescription)")
    }

    // 현재 최상단 VC 탐색 (rootViewController 설정용)
    private static func topViewController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
    ) -> UIViewController? {
        if let nav = base as? UINavigationController { return topViewController(base: nav.visibleViewController) }
        if let tab = base as? UITabBarController { return topViewController(base: tab.selectedViewController) }
        if let presented = base?.presentedViewController { return topViewController(base: presented) }
        return base
    }
}

// SwiftUI 래퍼 (구조 유지)
struct BannerAdView: UIViewRepresentable {
    @ObservedObject var controller: BannerAdController

    // v11 대응: 반환 타입 GADBannerView -> BannerView
    func makeUIView(context: Context) -> BannerView {
        // 혹시 컨트롤러에서 아직 못 넣었을 때 대비
        if controller.bannerView.rootViewController == nil {
            controller.bannerView.rootViewController = UIApplication.shared
                .connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                .first
        }
        return controller.bannerView
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        // 광고 제어는 controller가 담당
    }
}
