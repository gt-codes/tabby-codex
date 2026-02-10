import SwiftUI
import UIKit

// MARK: - AppDelegate for Push Notifications

class SPLTAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Don't request notification permission here — it will be requested
        // after onboarding completes so the system dialog doesn't block the flow.
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationManager.shared.didRegisterForRemoteNotifications(withDeviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationManager.shared.didFailToRegisterForRemoteNotifications(withError: error)
    }
}

// MARK: - App Entry Point

@main
struct SPLTApp: App {
    @UIApplicationDelegateAdaptor(SPLTAppDelegate.self) private var appDelegate
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
                    SPLTOnboardingView(
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
                                print("[SPLT] Apple sign in failed: \(error)")
                                return false
                            }
                        },
                        onFinish: { hasOnboarded = true }
                    )
                }
            }
            .environmentObject(linkRouter)
            .environmentObject(NotificationManager.shared)
            .onOpenURL { url in
                linkRouter.handle(url: url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                linkRouter.handle(url: url)
            }
            .preferredColorScheme(preferredColorScheme)
            .onChange(of: hasOnboarded) { _, onboarded in
                if onboarded {
                    NotificationManager.shared.requestPermissionAndRegister()
                }
            }
            .onAppear {
                // For users who already completed onboarding, register on launch.
                if hasOnboarded {
                    NotificationManager.shared.requestPermissionAndRegister()
                }
            }
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
