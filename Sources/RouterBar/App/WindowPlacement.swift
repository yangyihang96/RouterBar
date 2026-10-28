import AppKit

/// Places the main window on a named display once it exists.
@MainActor
enum WindowPlacement {
    static func move(toScreenNamed name: String, attempts: Int = 30) {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName == name }) else { return }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else {
            // SwiftUI creates the window shortly after launch.
            if attempts > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { move(toScreenNamed: name, attempts: attempts - 1) } }
            return
        }
        let area = screen.visibleFrame
        let size = NSSize(width: min(window.frame.width, area.width), height: min(window.frame.height, area.height))
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
