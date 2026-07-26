import UIKit
import SwiftUI

/// 用顶层 UIViewController present 系统分享面板（避开 SwiftUI .sheet 白板问题）
struct ShareSheet {
    static func present(items: [Any]) {
        guard let vc = topViewController() else { return }
        let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = ac.popoverPresentationController {
            pop.sourceView = vc.view
            pop.sourceRect = CGRect(x: UIScreen.main.bounds.width / 2,
                                    y: UIScreen.main.bounds.height / 2,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        vc.present(ac, animated: true)
    }

    static func topViewController(_ vc: UIViewController? = nil) -> UIViewController? {
        let base: UIViewController? = vc ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows
            .first { $0.isKeyWindow }?
            .rootViewController

        if let nav = base as? UINavigationController {
            return topViewController(nav.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            return topViewController(tab.selectedViewController)
        }
        if let presented = base?.presentedViewController {
            return topViewController(presented)
        }
        return base
    }
}
