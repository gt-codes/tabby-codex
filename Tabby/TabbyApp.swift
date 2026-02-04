import SwiftUI
import UIKit

@main
struct TabbyApp: App {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showDemo = false
    @StateObject private var linkRouter = AppLinkRouter()

    var body: some Scene {
        WindowGroup {
            Group {
                if hasOnboarded || showDemo {
                    ContentView()
                } else {
                    TabbyOnboardingView(
                        onTryDemo: { showDemo = true },
                        onScanReceipt: { hasOnboarded = true },
                        onFinish: { hasOnboarded = true }
                    )
                }
            }
            .environmentObject(linkRouter)
            .onOpenURL { url in
                linkRouter.handle(url: url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                linkRouter.handle(url: url)
            }
        }
    }
}
