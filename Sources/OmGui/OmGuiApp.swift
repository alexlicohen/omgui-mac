import AppKit
import Combine
import OmApi
import OmGuiCore
import SwiftUI

/// SwiftUI `App` lifecycle. The main window itself is an `NSWindow` hosting the SwiftUI view tree:
/// the SwiftUI `Window` scene does not reliably materialise for this app (see
/// `refs/05-phase2-notes.md`), and an `NSWindow` also gives exact control over the 1056x590
/// content size and the `MainForm` title, so the AppKit route is both safer and more faithful.
@main
struct OmGuiApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window is created in the delegate; this scene exists only because `App`
        // requires one, and it opens nothing at launch.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let options = LaunchOptions(arguments: CommandLine.arguments)
    private(set) lazy var model = AppModel(options: options)
    private var menuController: MainMenuController?
    private var window: NSWindow?
    private var titleObserver: AnyCancellable?

    /// `MainForm.ClientSize`.
    static let defaultContentSize = NSSize(width: 1056, height: 590)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let controller = MainMenuController(model: model)
        menuController = controller
        NSApp.mainMenu = controller.buildMenu()

        makeMainWindow()
        model.start()
        NSApp.activate(ignoringOtherApps: true)

        if let directory = options.selfTestDirectory {
            SelfTest.run(model: model, directory: directory) {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    private func makeMainWindow() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: AppDelegate.defaultContentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = model.windowTitle
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(model))
        window.setContentSize(AppDelegate.defaultContentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        SelfTest.window = window

        titleObserver = model.$windowTitle.sink { [weak window] title in
            window?.title = title
        }
    }
}

/// `menuStripMain` — File / Edit / View / Tools / Help with OMGUI's exact item titles.
@MainActor
final class MainMenuController: NSObject, NSMenuDelegate {

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    private var viewMenu: NSMenu?
    private var recentMenu: NSMenu?

    func buildMenu() -> NSMenu {
        let main = NSMenu()

        // Application menu (macOS requires one; OMGUI has no equivalent).
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About OmGui", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Options...", action: #selector(showOptions), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        let services = NSMenu()
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide OmGui", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OmGui", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        main.addItem(makeSubmenu("File", fileMenu()))
        main.addItem(makeSubmenu("Edit", editMenu()))
        main.addItem(makeSubmenu("View", makeViewMenu()))
        main.addItem(makeSubmenu("Tools", toolsMenu()))
        main.addItem(makeSubmenu("Help", helpMenu()))
        return main
    }

    private func makeSubmenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    /// A phase-3 item: present and visible, but disabled and carrying the promised tooltip.
    private func disabled(_ menu: NSMenu, _ title: String) {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = PhaseThree.tooltip
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Choose Working Folder...", action: #selector(chooseFolder), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Open Working Folder", action: #selector(openFolder), keyEquivalent: "").target = self

        let recent = NSMenu()
        recent.delegate = self
        recentMenu = recent
        let recentItem = menu.addItem(withTitle: "Recent Folders", action: nil, keyEquivalent: "")
        recentItem.submenu = recent

        menu.addItem(.separator())
        disabled(menu, "Export Resampled WAV...")
        disabled(menu, "Export Resampled CSV...")
        disabled(menu, "Export Raw CSV...")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Exit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAllDevices), keyEquivalent: "a").target = self
        return menu
    }

    private func makeViewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        viewMenu = menu
        for (index, title) in ["Toolbar", "Status Bar", "Preview", "Device Properties",
                               "File Properties", "Log"].enumerated() {
            let item = menu.addItem(withTitle: title, action: #selector(toggleView(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
        }
        return menu
    }

    private func toolsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        disabled(menu, "Calculate SVM...")
        disabled(menu, "Calculate Cut Points...")
        disabled(menu, "Calculate Wear Time...")
        disabled(menu, "Calculate Sleep Time...")
        menu.addItem(.separator())
        disabled(menu, "Plugins...")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Options...", action: #selector(showOptions), keyEquivalent: "").target = self
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "About...", action: #selector(showAbout), keyEquivalent: "").target = self
        return menu
    }

    // MARK: Actions

    @objc private func chooseFolder() { model.chooseWorkingFolder() }
    @objc private func openFolder() { model.openWorkingFolderInFinder() }
    @objc private func showOptions() { model.showOptions = true }
    @objc private func showAbout() { model.showAbout = true }

    @objc private func selectAllDevices() {
        model.selectedDeviceIds = Set(model.rows.map(\.deviceId))
        model.selectionChanged()
    }

    @objc private func toggleView(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: model.showToolbar.toggle()
        case 1: model.showStatusBar.toggle()
        case 2: model.showPreview.toggle()
        case 3: model.showDeviceProperties.toggle(); model.selectionChanged()
        case 4: model.showFileProperties.toggle(); model.fileSelectionChanged()
        default: model.showLog.toggle()
        }
        model.persistViewFlags()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        model.setWorkingFolder(sender.title)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === viewMenu {
            let flags = [model.showToolbar, model.showStatusBar, model.showPreview,
                         model.showDeviceProperties, model.showFileProperties, model.showLog]
            for item in menu.items where item.tag < flags.count {
                item.state = flags[item.tag] ? .on : .off
            }
        } else if menu === recentMenu {
            menu.removeAllItems()
            for folder in model.recentFolders {
                let item = menu.addItem(withTitle: folder, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
            }
            if menu.items.isEmpty {
                menu.addItem(withTitle: "(none)", action: nil, keyEquivalent: "").isEnabled = false
            }
        }
    }
}
