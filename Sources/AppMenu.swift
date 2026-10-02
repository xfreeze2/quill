import AppKit

/// The menu bar at the top of the screen while the Quill window is in front.
/// Quill is a menu-bar app first, but once there's a window it should behave like
/// any other Mac app: ⌘N, ⌘W, ⌘, and the editing shortcuts all work.
final class AppMenu: NSObject {

    static let shared = AppMenu()

    private let model = AppModel.shared

    func install() {
        let main = NSMenu()

        main.addItem(submenu(named: "Quill") { menu in
            menu.addItem(item("About Quill", #selector(showAbout)))
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
            menu.addItem(.separator())
            menu.addItem(item("Settings…", #selector(openSettings), key: ","))
            menu.addItem(.separator())
            let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            let servicesMenu = NSMenu(title: "Services")
            services.submenu = servicesMenu
            NSApp.servicesMenu = servicesMenu
            menu.addItem(services)
            menu.addItem(.separator())
            menu.addItem(system("Hide Quill", #selector(NSApplication.hide(_:)), key: "h"))
            let hideOthers = system("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h")
            hideOthers.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(hideOthers)
            menu.addItem(system("Show All", #selector(NSApplication.unhideAllApplications(_:))))
            menu.addItem(.separator())
            menu.addItem(system("Quit Quill", #selector(NSApplication.terminate(_:)), key: "q"))
        })

        main.addItem(submenu(named: "File") { menu in
            menu.addItem(item("New Meeting Notes", #selector(newMeeting), key: "n"))
            menu.addItem(item("Start Dictation", #selector(dictate), key: "d", modifiers: [.command, .shift]))
            menu.addItem(item("Search Everything…", #selector(searchAll), key: "k"))
            menu.addItem(.separator())
            menu.addItem(system("Close Window", #selector(NSWindow.performClose(_:)), key: "w"))
        })

        main.addItem(submenu(named: "Edit") { menu in
            menu.addItem(system("Undo", Selector(("undo:")), key: "z"))
            let redo = system("Redo", Selector(("redo:")), key: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(redo)
            menu.addItem(.separator())
            menu.addItem(system("Cut", #selector(NSText.cut(_:)), key: "x"))
            menu.addItem(system("Copy", #selector(NSText.copy(_:)), key: "c"))
            menu.addItem(system("Paste", #selector(NSText.paste(_:)), key: "v"))
            menu.addItem(system("Select All", #selector(NSText.selectAll(_:)), key: "a"))
            menu.addItem(.separator())
            let find = system("Find…", #selector(NSResponder.performTextFinderAction(_:)), key: "f")
            find.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
            menu.addItem(find)
        })

        main.addItem(submenu(named: "View") { menu in
            for section in AppModel.Section.allCases where section != .settings {
                let entry = item(section.title, #selector(openSection(_:)), key: String(section.shortcut))
                entry.representedObject = section.rawValue
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            menu.addItem(system("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f",
                                modifiers: [.command, .control]))
        })

        let window = submenu(named: "Window") { menu in
            menu.addItem(system("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
            menu.addItem(system("Zoom", #selector(NSWindow.performZoom(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Quill", #selector(showWindow), key: "0"))
        }
        NSApp.windowsMenu = window.submenu
        main.addItem(window)

        let help = submenu(named: "Help") { menu in
            menu.addItem(item("Setup Guide…", #selector(openSetup)))
            menu.addItem(item("Quill on GitHub", #selector(openGitHub)))
            menu.addItem(item("Show Data in Finder", #selector(revealData)))
        }
        NSApp.helpMenu = help.submenu
        main.addItem(help)

        NSApp.mainMenu = main
    }

    // MARK: Building

    private func submenu(named title: String, _ fill: (NSMenu) -> Void) -> NSMenuItem {
        let menu = NSMenu(title: title)
        fill(menu)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func item(_ title: String, _ action: Selector, key: String = "",
                      modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        if !key.isEmpty { entry.keyEquivalentModifierMask = modifiers }
        return entry
    }

    /// An item the responder chain answers (nil target), such as Copy or Close.
    private func system(_ title: String, _ action: Selector, key: String = "",
                        modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { entry.keyEquivalentModifierMask = modifiers }
        return entry
    }

    // MARK: Actions

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Quill",
            .applicationVersion: Build.version,
            .version: "",
            .credits: NSAttributedString(
                string: "Dictate anywhere. Translate anything you hear. Keep notes of every meeting.\nYour words stay on this Mac.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func checkForUpdates() { model.bridge.checkForUpdates() }
    @objc private func openSettings() { MainWindow.shared.show(.settings) }
    @objc private func newMeeting() { MainWindow.shared.show(); model.newMeeting() }
    @objc private func dictate() { model.bridge.toggleDictation() }
    @objc private func searchAll() { MainWindow.shared.show(); model.showingSearch = true }
    @objc private func showWindow() { MainWindow.shared.show() }
    @objc private func openSetup() { model.bridge.openSetup() }
    @objc private func revealData() { model.revealDataFolder() }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/xfreeze2/quill") { NSWorkspace.shared.open(url) }
    }

    @objc private func openSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let section = AppModel.Section(rawValue: raw) else { return }
        MainWindow.shared.show(section)
    }
}
