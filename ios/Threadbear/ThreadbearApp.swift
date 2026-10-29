import SwiftUI
import ThreadbearKit
import UserNotifications

@main
struct ThreadbearApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var quick = QuickAskModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(quick)
                .onAppear {
                    delegate.model = model
                    quick.keep = { [model] record in try await model.keepQuickAsk(record) }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in quick.scenePhaseChanged(to: phase) }
                // Ask for notifications once paired, including straight
                // after pairing, not only on a launch that was already paired.
                .onChange(of: model.isPaired, initial: true) { _, paired in
                    if paired, !model.isFake { delegate.askForNotifications() }
                }
                // The Camera opens threadbear://pair links from the QR code, and
                // threadbear://quickask ones with the archive server for quick ask.
                .onOpenURL { url in
                    if quick.settings.apply(link: url) { quick.settingsChanged(); return }
                    Task { await model.pair(with: url) }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(QuickAskModel.self) private var quick

    var body: some View {
        @Bindable var quick = quick
        Group {
            if model.isPaired {
                InboxView()
            } else {
                PairView()
            }
        }
        // Quick ask goes over whatever's showing, from the Action button or the inbox's mic.
        .fullScreenCover(isPresented: $quick.isPresented) {
            QuickAskView { threadId in
                quick.close()
                model.openThreadId = threadId
            }
            .environment(quick)
        }
    }
}

/// Push: asks once it's paired, hands the APNs token to the model, and
/// opens the thread a notification is about.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func askForNotifications() {
        Task { @MainActor in
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in model?.didRegister(apnsToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in model?.report(error) }
    }

    /// Banners show while the app's open too, since the push is usually
    /// about a thread other than the one on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let threadId = response.notification.request.content.userInfo["threadId"] as? String else { return }
        await MainActor.run { model?.openThreadId = threadId }
    }
}
