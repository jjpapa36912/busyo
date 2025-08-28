import SwiftUI
import GoogleMobileAds
import UIKit

class BannerAdController: NSObject, ObservableObject, GADBannerViewDelegate {
    let bannerView: GADBannerView

    override init() {
        self.bannerView = GADBannerView(adSize: GADAdSizeBanner)
        super.init()

        self.bannerView.adUnitID = {
            #if DEBUG
            return "ca-app-pub-3940256099942544/2934735716" // 테스트용
            #else
            return "ca-app-pub-2190585582842197/2371518986" // 실제 광고 ID
            #endif
        }()

        self.bannerView.delegate = self // ✅ 반드시 설정
        self.bannerView.load(GADRequest())
    }

    func reload() {
        print("🔄 Reloading Ad...")
        bannerView.load(GADRequest())
    }

    // ✅ 광고 로딩 성공
    func bannerViewDidReceiveAd(_ bannerView: GADBannerView) {
        print("✅ 배너 광고 로딩 성공")
    }

    // ❌ 광고 로딩 실패
    func bannerView(_ bannerView: GADBannerView, didFailToReceiveAdWithError error: Error) {
        print("❌ 배너 광고 로딩 실패: \(error.localizedDescription)")
    }
}
struct BannerAdView: UIViewRepresentable {
    @ObservedObject var controller: BannerAdController

    func makeUIView(context: Context) -> GADBannerView {
        controller.bannerView.rootViewController = UIApplication.shared
            .connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
        return controller.bannerView
    }

    func updateUIView(_ uiView: GADBannerView, context: Context) {
        // 광고는 controller에서 직접 제어
    }
}
