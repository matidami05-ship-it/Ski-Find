import SwiftUI
import BackgroundTasks
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshId = "com.skistudio.find.refresh"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Self.scheduleRefresh()
            let work = Task { @MainActor in
                await LocationSharer.shared.checkEvents(force: true)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        // iOS relaunches the app in the background when you move; keep sharing.
        LocationSharer.shared.resume()
        Self.scheduleRefresh()
        return true
    }

    /// Asks iOS to wake the app now and then to check for arrive/leave alerts.
    static func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: refreshId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Show alerts even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

@main
struct SkiFindApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(LocationSharer.shared)
                .preferredColorScheme(.dark)
                .tint(Color.brand)
        }
        .onChange(of: phase) { _, newPhase in
            model.setActive(newPhase == .active)
        }
    }
}

extension Color {
    static let brand = Color(red: 0.30, green: 0.58, blue: 0.96)
    static let card = Color(red: 0.09, green: 0.11, blue: 0.17)
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.circle == nil {
                SetupView()
            } else {
                MainView()
            }
        }
        .animation(.default, value: model.circle == nil)
    }
}
