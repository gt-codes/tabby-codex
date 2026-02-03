import SwiftUI

@main
struct TabbyApp: App {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showDemo = false

    var body: some Scene {
        WindowGroup {
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
    }
}
