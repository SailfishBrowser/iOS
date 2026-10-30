import SwiftUI

@main
struct SailBrowserApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    private let env: AppEnvironment?
    private let hapticSink: LiveHapticSink?

    init() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            env = nil
            hapticSink = nil
            return
        }
        let directories = AppDirectories.live()
        #if DEBUG
        DebugLaunchOptions.current().prepare(directories)
        #endif
        let hapticSink = LiveHapticSink()
        let env = AppEnvironment(directories: directories, ruleStore: .default(), hapticSink: hapticSink)
        env.launch()
        self.env = env
        self.hapticSink = hapticSink
    }

    var body: some Scene {
        WindowGroup {
            if let env, let hapticSink {
                RootView(hapticSink: hapticSink)
                    .environment(env)
                    .onOpenURL { url in
                        SharePresenter.dismiss()
                        env.openLink(url)
                    }
                    // Four independent steps: the inactive step on the way back from the background is a foreground,
                    // not a resign, and a background to active jump runs the foreground and then the active call, so
                    // the resign's assertion never outlives the return.
                    .onChange(of: scenePhase) { old, new in
                        if new == .background {
                            env.sceneDidEnterBackground()
                        }
                        if old == .background {
                            env.sceneWillEnterForeground()
                        }
                        if old == .active, new == .inactive {
                            env.sceneWillResignActive()
                        }
                        if new == .active {
                            env.sceneDidBecomeActive()
                        }
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
                    ) { _ in
                        env.memoryWarning()
                    }
            } else {
                Color.clear
            }
        }
    }
}
