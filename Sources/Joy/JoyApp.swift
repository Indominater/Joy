import AppKit

@main
enum JoyApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var panelController: JoyPanelController?
    private let store = MonitorStore()
    private var monitoringActivity: NSObjectProtocol?
    private var statusItem: NSStatusItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = JoyApplicationIcon.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        monitoringActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Joy is monitoring configured ChatGPT and Codex tasks"
        )
        panelController = JoyPanelController(store: store)
        configureStatusItem()
        panelController?.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        panelController?.showWindow(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitoringActivity {
            ProcessInfo.processInfo.endActivity(monitoringActivity)
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Joy")
        appMenu.addItem(withTitle: "Quit Joy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undoItem = editMenu.addItem(
            withTitle: "Undo",
            action: #selector(undoLastClear(_:)),
            keyEquivalent: "z"
        )
        undoItem.target = self
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func undoLastClear(_ sender: Any?) {
        store.undoLastClear()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoLastClear(_:)) {
            return store.canUndoLastClear
        }
        return true
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = JoyApplicationIcon.makeStatusItemIcon()
            button.toolTip = "Joy"
        }

        let menu = NSMenu()
        let showItem = menu.addItem(
            withTitle: "Show Joy",
            action: #selector(showPanel(_:)),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(
            withTitle: "Quit Joy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        item.menu = menu
        statusItem = item
    }

    @objc private func showPanel(_ sender: Any?) {
        panelController?.showWindow(sender)
    }
}
