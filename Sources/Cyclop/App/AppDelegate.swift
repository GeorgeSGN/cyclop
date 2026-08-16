import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var clearVaultItem: NSMenuItem?
    private var sweepTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.install()
        installStatusItem()
        startSweep()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sweepTimer?.invalidate()
        controller?.teardown()
    }

    // MARK: - Screenshot sweep

    /// At launch and once a day after. The daily beat is for the Mac that is
    /// never restarted — left to launch alone, the sweep on such a machine would
    /// run once and then never again.
    private func startSweep() {
        sweep()
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        // An hour of slack: nothing here is due at a particular minute, and the
        // slack lets the system fold this wake-up into others it was making.
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    private func sweep() {
        let removed = ScreenshotVault.prune()
        guard removed > 0 else { return }
        NSLog("Cyclop: swept \(removed) screenshot(s) older than 14 days")
        // Cards pointing at the files that just went have to go with them.
        controller?.reloadShelf()
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "eye.fill",
            accessibilityDescription: "Cyclop"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        // Enabling is decided here, not guessed from the responder chain: the
        // clear item below is disabled exactly when the folder is empty.
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: "Cyclop \(Bundle.main.shortVersion)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: localized("Open Panel"),
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let login = NSMenuItem(
            title: localized("Launch at Login"),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(login)

        let saveShots = NSMenuItem(
            title: localized("Save Clipboard Screenshots"),
            action: #selector(toggleSaveClipboardImages),
            keyEquivalent: ""
        )
        saveShots.target = self
        saveShots.state = NotchViewModel.saveClipboardImagesEnabled ? .on : .off
        menu.addItem(saveShots)

        let saveFiles = NSMenuItem(
            title: localized("Add Copied Files to Shelf"),
            action: #selector(toggleSaveClipboardFiles),
            keyEquivalent: ""
        )
        saveFiles.target = self
        saveFiles.state = NotchViewModel.saveClipboardFilesEnabled ? .on : .off
        menu.addItem(saveFiles)

        let openFolder = NSMenuItem(
            title: localized("Show Screenshots Folder"),
            action: #selector(revealScreenshots),
            keyEquivalent: ""
        )
        openFolder.target = self
        menu.addItem(openFolder)

        // Deliberately wider than the two-week sweep: this one empties the whole
        // folder, the sweep takes only files this app wrote. That is not an
        // inconsistency to fix but the difference between a press and a schedule
        // — an explicit "clear the folder" that left half of it behind would be
        // the puzzling one, and the Trash keeps it reversible. The size sits in
        // the title so the offer names its price.
        let clearVault = NSMenuItem(
            title: localized("Clear Screenshots Folder"),
            action: #selector(clearScreenshots),
            keyEquivalent: ""
        )
        clearVault.target = self
        menu.addItem(clearVault)
        clearVaultItem = clearVault

        let openSnippets = NSMenuItem(
            title: localized("Show Snippets File"),
            action: #selector(revealSnippets),
            keyEquivalent: ""
        )
        openSnippets.target = self
        menu.addItem(openSnippets)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: localized("Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        controller?.toggle()
    }

    /// The size is measured when the menu opens, not kept fresh in between: a
    /// folder nobody is looking at deserves no bookkeeping.
    func menuWillOpen(_ menu: NSMenu) {
        guard let clearVaultItem else { return }
        let usage = ScreenshotVault.usage()
        if usage.files == 0 {
            clearVaultItem.title = localized("Clear Screenshots Folder")
            clearVaultItem.isEnabled = false
        } else {
            let size = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
            clearVaultItem.title = localized("Clear Screenshots Folder (%@)", size)
            clearVaultItem.isEnabled = true
        }
    }

    @objc private func clearScreenshots() {
        ScreenshotVault.clear()
        // The cards pointing into that folder just went to the Trash with it.
        controller?.reloadShelf()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleSaveClipboardImages(_ sender: NSMenuItem) {
        UserDefaults.standard.set(
            !NotchViewModel.saveClipboardImagesEnabled,
            forKey: NotchViewModel.saveClipboardImagesKey
        )
        sender.state = NotchViewModel.saveClipboardImagesEnabled ? .on : .off
    }

    @objc private func toggleSaveClipboardFiles(_ sender: NSMenuItem) {
        UserDefaults.standard.set(
            !NotchViewModel.saveClipboardFilesEnabled,
            forKey: NotchViewModel.saveClipboardFilesKey
        )
        sender.state = NotchViewModel.saveClipboardFilesEnabled ? .on : .off
    }

    @objc private func revealScreenshots() {
        ScreenshotVault.reveal()
    }

    @objc private func revealSnippets() {
        SnippetStore.reveal()
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Cyclop: launch-at-login failed: \(error.localizedDescription)")
        }
        sender.state = launchAtLoginEnabled ? .on : .off
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

