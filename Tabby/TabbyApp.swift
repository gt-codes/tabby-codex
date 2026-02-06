import SwiftUI
import UIKit

@main
struct TabbyApp: App {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("shouldShowCameraPermissionNudge") private var shouldShowCameraPermissionNudge = false
    @AppStorage("appTheme") private var appTheme = "auto"
    @StateObject private var linkRouter = AppLinkRouter()

    var body: some Scene {
        WindowGroup {
            Group {
                if hasOnboarded {
                    ContentView()
                } else {
                    TabbyOnboardingView(
                        onSignInWithApple: {
                            do {
                                try await ConvexService.shared.signInWithApple()
                                _ = try? await ConvexService.shared.migrateGuestDataToSignedInAccount()
                                await MainActor.run {
                                    shouldShowCameraPermissionNudge = true
                                    hasOnboarded = true
                                }
                                return true
                            } catch {
                                print("[Tabby] Apple sign in failed: \(error)")
                                return false
                            }
                        },
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
            .preferredColorScheme(preferredColorScheme)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appTheme {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }
}
