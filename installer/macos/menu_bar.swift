import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var serverProcess: Process?
    private var healthTimer: Timer?
    private var isConnected = false
    private let bundleID = "com.popsall.redactproof.accelerator"
    private let loginPrefKey = "rp.loginItemPreferenceSet"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        migrateFromLegacy()
        setupStatusItem()
        startServer()
        registerLoginItemIfFirstLaunch()
        scheduleHealthCheck()
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        serverProcess?.terminate()
    }

    // MARK: - Legacy migration

    private func migrateFromLegacy() {
        // Kill any orphaned server.mjs processes from previous installation
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "server.mjs"]
        try? kill.run(); kill.waitUntilExit()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacyPlist = home.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
        let legacyApp  = URL(fileURLWithPath: "/Applications/RedactProofAccelerator.app")

        if FileManager.default.fileExists(atPath: legacyPlist.path) {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            t.arguments = ["unload", legacyPlist.path]
            try? t.run(); t.waitUntilExit()
            try? FileManager.default.removeItem(at: legacyPlist)
        }
        if FileManager.default.fileExists(atPath: legacyApp.path) {
            try? FileManager.default.trashItem(at: legacyApp, resultingItemURL: nil)
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            if let img = NSImage(named: "MenuBarTemplate") {
                img.isTemplate = true
                btn.image = img
            } else {
                btn.title = "RP"
            }
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let s = NSMenuItem(title: isConnected ? "\u{25CF} Connected" : "\u{25CB} Not connected",
                           action: nil, keyEquivalent: "")
        s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Open RedactProof", action: #selector(openApp), keyEquivalent: "")
        menu.addItem(.separator())

        let li = NSMenuItem(title: "Start at Login",
                            action: #selector(toggleLogin), keyEquivalent: "")
        li.state = loginEnabled() ? .on : .off
        menu.addItem(li)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Uninstall\u{2026}", action: #selector(confirmUninstall), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")

        statusItem.menu = menu
    }

    // MARK: - Server

    private func startServer() {
        guard let res = Bundle.main.resourceURL else { return }
        let node   = res.appendingPathComponent("node")
        let server = res.appendingPathComponent("server.mjs")
        guard FileManager.default.fileExists(atPath: node.path),
              FileManager.default.fileExists(atPath: server.path) else { return }

        let proc = Process()
        proc.executableURL = node
        proc.arguments     = [server.path]
        proc.currentDirectoryURL = res
        proc.environment = ProcessInfo.processInfo.environment
            .merging(["NODE_ENV": "production"]) { $1 }

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".redactproof")
        try? FileManager.default.createDirectory(at: logDir,
                                                  withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("bridge.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: logURL) {
            proc.standardOutput = fh
            proc.standardError  = fh
        }

        try? proc.run()
        serverProcess = proc
    }

    private func scheduleHealthCheck() {
        checkHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    private func checkHealth() {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RedactProof/accelerator.json")
        var port = 47821
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = json["port"] as? Int { port = p }

        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        URLSession.shared.dataTask(with: url) { [weak self] _, resp, err in
            let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                if self?.isConnected != ok { self?.isConnected = ok; self?.rebuildMenu() }
            }
        }.resume()
    }

    // MARK: - Login item (SMAppService, macOS 13+)

    private func loginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func registerLoginItemIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: loginPrefKey) else { return }
        // First launch - register and mark preference as set
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }
        UserDefaults.standard.set(true, forKey: loginPrefKey)
    }

    @objc private func toggleLogin() {
        if #available(macOS 13.0, *) {
            let svc = SMAppService.mainApp
            if svc.status == .enabled { try? svc.unregister() }
            else                       { try? svc.register()   }
        }
        // Mark that user has explicitly set a preference - won't be overridden on next launch
        UserDefaults.standard.set(true, forKey: loginPrefKey)
        rebuildMenu()
    }

    // MARK: - Actions

    @objc private func openApp() {
        let url = URL(string: "https://app.redactproof.com")!
        // Safari blocks localhost connections from HTTPS - prefer Chromium-based browsers
        let chromiumBundleIDs = [
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "org.chromium.Chromium",
            "com.brave.Browser",
            "company.thebrowser.Browser",  // Arc
        ]
        for bundleID in chromiumBundleIDs {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                        configuration: config, completionHandler: nil)
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func confirmUninstall() {
        let a = NSAlert()
        a.messageText     = "Uninstall RedactProof Accelerator?"
        a.informativeText = "This will stop the Accelerator and remove it from your Mac. Your RedactProof account and documents are not affected."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        performUninstall()
    }

    private func performUninstall() {
        healthTimer?.invalidate()
        serverProcess?.terminate()

        if #available(macOS 13.0, *) { try? SMAppService.mainApp.unregister() }

        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            t.arguments = ["unload", plist.path]
            try? t.run(); t.waitUntilExit()
            try? FileManager.default.removeItem(at: plist)
        }

        UserDefaults.standard.removeObject(forKey: loginPrefKey)

        try? FileManager.default.trashItem(
            at: URL(fileURLWithPath: Bundle.main.bundlePath),
            resultingItemURL: nil)

        NSApp.terminate(nil)
    }

    @objc private func quit() {
        healthTimer?.invalidate()
        serverProcess?.terminate()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()