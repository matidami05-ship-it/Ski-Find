import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // iOS relaunches the app in the background when you move; keep sharing.
        LocationSharer.shared.resume()
        return true
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
