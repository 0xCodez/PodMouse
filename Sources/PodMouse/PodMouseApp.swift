import AppKit
import PodMouseCore
import SwiftUI

@main
struct PodMouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.menuBarSymbol)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var welcomeWindow: NSWindow?
    private var diagnostics: Diagnostics?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        if let tool = Diagnostics(arguments: CommandLine.arguments, model: model) {
            diagnostics = tool
            tool.run()
            return
        }
        if !model.prefs.hasSeenWelcome { showWelcome() }
    }

    private func showWelcome() {
        let view = WelcomeView(model: model) { [weak self] in
            self?.model.prefs.hasSeenWelcome = true
            self?.welcomeWindow?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow = window
    }
}
