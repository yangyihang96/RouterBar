import SwiftUI
import UserNotifications

struct RouterBarApp: App {
    @NSApplicationDelegateAdaptor(RouterBarDelegate.self) private var delegate
    @State private var store = RouterStore()
    var body: some Scene {
        WindowGroup("路由器面板", id: "dashboard") {
            DashboardView().environment(store).environment(\.locale, Locale(identifier: "zh_CN")).tint(.teal)
        }.defaultSize(width: 1280, height: 860)
         .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra {
            MenuPanel().environment(store).environment(\.locale, Locale(identifier: "zh_CN")).tint(.teal)
        } label: {
            Image(systemName: store.hasLiveSession ? "wifi.router.fill" : "wifi.router")
            if store.hasLiveSession { Text(store.onlineCount).monospacedDigit() }
        }.menuBarExtraStyle(.window)
    }
}

@MainActor
final class RouterBarDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Deliberate menu-bar utility: closing the dashboard leaves its status item running.
        NSApp.setActivationPolicy(.accessory)
        // `--background` starts without taking the foreground from the app in use.
        if !CommandLine.arguments.contains("--background") { NSApp.activate(ignoringOtherApps: true) }
        UNUserNotificationCenter.current().delegate = self
        KeyPressEvent.startTracking()
        // `--screen NAME` opens the main window on the display of that name, e.g. a virtual display used for testing.
        if let index = CommandLine.arguments.firstIndex(of: "--screen"), index + 1 < CommandLine.arguments.count {
            WindowPlacement.move(toScreenNamed: CommandLine.arguments[index + 1])
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
}
