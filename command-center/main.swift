// Command Center — one menu-bar icon for your whole Mac setup:
//   • Your apps & dashboards, quick actions, recent Claude Code projects        (AppsSection)
//   • Your T7 / external SSD: move, copy, bring back, free up space, sync…      (DriveSection)
//   • iPhone Bridge: clipboard sync with your iPhone via Back Tap               (PhoneSection)
//   • Clean Dev Caches: Xcode, Gradle, CocoaPods, npm…                          (CleanerSection)
//   • Update All (rebuild from the repo) and Check Everything (health check)
// ⌃⌥Space opens the menu from anywhere. Only built-in macOS frameworks.

import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, Hub {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let apps = AppsSection()
    let drive = DriveSection()
    let phone = PhoneSection()
    let cleaner = CleanerSection()
    var cleanerRow: NSMenuItem?
    var flashing = false

    func applicationDidFinishLaunching(_ n: Notification) {
        migrateOldSettings()
        menu.delegate = self
        menu.autoenablesItems = false
        status.menu = menu
        // Drag files onto the icon → move/copy to the T7
        status.button?.window?.registerForDraggedTypes([.fileURL])
        status.button?.window?.delegate = self
        apps.hub = self; drive.hub = self; phone.hub = self; cleaner.hub = self
        apps.start(); drive.start(); phone.start()
        registerHotKey(10, key: 49 /* Space */) { [weak self] in self?.status.button?.performClick(nil) }
        if Bundle.main.bundleIdentifier != nil && !UserDefaults.standard.bool(forKey: "loginSetupDone") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginSetupDone")
        }
        updateStatus()
        log("Command Center started")
    }

    func applicationWillTerminate(_ n: Notification) { apps.stopOwnedApps() }

    /// Carry settings over from the separate apps this one replaces (T7 Helper, iPhone Bridge).
    func migrateOldSettings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedOldApps") else { return }
        for key in ["syncFolders", "autoSync", "lastSync", "driveUUID", "leaveAliases", "sleepUnmount"] {
            if d.object(forKey: key) == nil, let v = oldPref(key, app: "com.local.t7helper") { d.set(v, forKey: key) }
        }
        _ = secretKey   // pulls the iPhone Bridge key across
        d.set(true, forKey: "migratedOldApps")
    }

    // MARK: Hub

    func updateStatus() {
        guard let b = status.button, !flashing else { return }
        let symbol = drive.busy != nil ? "arrow.triangle.2.circlepath"
                   : apps.anyCrashed ? "exclamationmark.triangle.fill" : "command.square.fill"
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Command Center")
        b.image?.isTemplate = true
        b.imagePosition = .imageLeading
        let t = drive.titleText()
        b.title = t.isEmpty ? "" : " " + t
    }

    func flash(_ text: String) {
        flashing = true
        status.button?.title = " " + text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.flashing = false; self.updateStatus() }
    }

    // MARK: drag & drop (forwarded to the drive section)

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { drive.draggingEntered(sender) }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool { drive.performDragOperation(sender) }

    // MARK: menu

    func menuWillOpen(_ m: NSMenu) {
        guard m === menu else { return }
        rebuild()
        apps.refreshProjects()
    }

    @discardableResult
    func add(_ m: NSMenu, _ title: String, _ action: Selector?, symbol: String? = nil, enabled: Bool = true) -> NSMenuItem {
        let i = menuItem(title, action, target: self, enabled: enabled, symbol: symbol)
        m.addItem(i); return i
    }

    func rebuild() {
        cleanerRow?.submenu = nil          // detach the persistent cleaner submenu before clearing
        menu.removeAllItems()

        apps.buildMain(menu)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Devices & Clean-up"))
        let driveRow = add(menu, drive.rowTitle(), nil, symbol: currentDrive() != nil ? "externaldrive.fill" : "externaldrive")
        driveRow.isEnabled = true
        let dsub = NSMenu(); dsub.autoenablesItems = false
        drive.buildMenu(dsub)
        driveRow.submenu = dsub

        let phoneRow = add(menu, phone.rowTitle(), nil, symbol: "iphone")
        phoneRow.isEnabled = true
        let psub = NSMenu(); psub.autoenablesItems = false
        phone.buildMenu(psub)
        phoneRow.submenu = psub

        let c = add(menu, cleaner.rowTitle(), nil, symbol: "bubbles.and.sparkles")
        c.isEnabled = true
        c.submenu = cleaner.menu
        cleanerRow = c

        apps.buildExtras(menu)

        menu.addItem(.separator())
        add(menu, "Check Everything…", #selector(healthCheck), symbol: "stethoscope")
        add(menu, "Update All", #selector(updateAll), symbol: "arrow.down.circle")
        let settings = add(menu, "Settings", nil, symbol: "gearshape")
        settings.isEnabled = true
        let st = NSMenu(); st.autoenablesItems = false
        st.addItem(menuItem("Edit Apps & Links…", #selector(AppsSection.editConfig), target: apps, symbol: "slider.horizontal.3"))
        st.addItem(menuItem("Reload Apps & Links", #selector(AppsSection.reloadConfigAction), target: apps, symbol: "arrow.triangle.2.circlepath"))
        let login = add(st, "Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        add(st, "Open Logs Folder", #selector(openLogs), symbol: "doc.text")
        st.addItem(.separator())
        add(st, "⌃⌥Space opens this menu · ⌃⌥M/C move/copy to T7 · ⌃⌥E eject", nil)
        settings.submenu = st
        menu.addItem(NSMenuItem(title: "Quit Command Center", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Update All

    /// Repo folder recorded by install.sh, so the app can rebuild itself.
    var repoPath: String? {
        (Bundle.main.object(forInfoDictionaryKey: "RepoPath") as? String).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    @objc func updateAll() {
        guard let repo = repoPath else {
            showAlert("Can't find the source folder", "Re-run command-center/install.sh from your mac-dev-tools folder once, then Update All will work.")
            return
        }
        guard showAlert("Update all tools?",
                        "Pulls the latest code from GitHub (if any), then rebuilds ClaudeHere and Command Center from\n\(tildify(repo)).\n\nCommand Center restarts by itself in about a minute. Your apps keep running settings, and permissions are kept.",
                        buttons: ["Update", "Cancel"]) == .alertFirstButtonReturn else { return }
        let logFile = logDir.appendingPathComponent("update.log").path
        // Runs detached so it survives this app being restarted by its own installer.
        let script = """
        exec >\(shellQuote(logFile)) 2>&1
        cd \(shellQuote(repo)) || exit 1
        echo "== $(date) update"
        git pull --ff-only || echo "(no pull — offline or local changes; building local code)"
        [ -f claude-here/install.sh ] && zsh claude-here/install.sh
        zsh command-center/install.sh
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "nohup zsh -c \(shellQuote(script)) >/dev/null 2>&1 &"]
        try? p.run()
        flash("Updating…")
        log("Update All started (log: \(logFile))")
    }

    // MARK: Check Everything

    @objc func healthCheck() {
        var lines: [String] = []
        var fixes: [String] = []

        // ClaudeHere (reads its own log for the permission state)
        let chRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.claudehere").isEmpty
        let chLog = (try? String(contentsOfFile: home + "/Library/Logs/ClaudeHere.log", encoding: .utf8)) ?? ""
        let lastState = chLog.split(separator: "\n").last(where: { $0.contains("listening") || $0.contains("waiting for permission") }).map(String.init) ?? ""
        if !chRunning { lines.append("🔴 ClaudeHere isn't running"); fixes.append("restartClaudeHere") }
        else if lastState.contains("waiting for permission") {
            lines.append("🟠 ClaudeHere is waiting for Input Monitoring / Accessibility permission"); fixes.append("privacy")
        } else {
            lines.append("✅ ClaudeHere: double-tap shortcuts active")
            if lastState.contains("screenRecording=false") { lines.append("🟠 ClaudeHere: Screen Recording is off (Right ⌘⌘ screenshot won't work)"); fixes.append("privacy") }
        }

        // iPhone Bridge
        lines.append(phone.ready ? "✅ iPhone Bridge ready at \(localHostName())" : "🔴 iPhone Bridge not running (\(phone.serverState))")

        // Drive
        if let d = currentDrive() { lines.append("✅ \(d.name) connected — \(fmt(freeSpace(d.url))) free") }
        else { lines.append("⚪️ T7 not connected") }

        // Mac space
        let mf = drive.macFree
        lines.append(mf < drive.macLowBytes ? "🟠 Mac is low on space: \(fmt(mf)) free — try T7 › Free Up Space or Clean Dev Caches"
                                            : "✅ Mac: \(fmt(mf)) free")

        // Your apps
        for a in apps.apps {
            switch a.state() {
            case .crashed: lines.append("🔴 \(a.def.name) keeps crashing — \(a.lastError?.split(separator: "\n").first ?? "see its log")"); fixes.append("restartApps")
            case .running, .external: lines.append("✅ \(a.def.name) running")
            case .starting: lines.append("🟡 \(a.def.name) starting…")
            case .stopped: lines.append("⚪️ \(a.def.name) stopped\(a.def.autoStart == true ? " (should auto-start)" : "")")
                if a.def.autoStart == true { fixes.append("restartApps") }
            }
        }
        if apps.configError != nil { lines.append("🟠 Apps config has an error — Settings › Edit Apps & Links") }

        // Login item
        if Bundle.main.bundleIdentifier != nil && SMAppService.mainApp.status != .enabled {
            lines.append("🟠 Command Center won't start at login"); fixes.append("login")
        }

        var buttons = ["OK"]
        if fixes.contains("restartApps") { buttons.append("Restart Stopped Apps") }
        if fixes.contains("restartClaudeHere") { buttons.append("Restart ClaudeHere") }
        if fixes.contains("privacy") { buttons.append("Open Privacy Settings") }
        if fixes.contains("login") { buttons.append("Start at Login") }
        let r = showAlert(fixes.isEmpty ? "Everything looks good ✅" : "\(fixes.count) thing\(fixes.count == 1 ? "" : "s") need attention",
                          lines.joined(separator: "\n"), buttons: buttons)
        let chosen = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard chosen > 0, chosen < buttons.count else { return }
        switch buttons[chosen] {
        case "Restart Stopped Apps":
            for a in apps.apps where a.crashed || (a.def.autoStart == true && a.state() == .stopped) { a.crashed = false; a.restarts = []; a.start() }
        case "Restart ClaudeHere":
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["kickstart", "-k", "gui/\(getuid())/com.local.claudehere"]; try? p.run()
        case "Open Privacy Settings":
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
        case "Start at Login":
            try? SMAppService.mainApp.register()
        default: break
        }
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    }

    @objc func openLogs() {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logDir)
    }
}

// MARK: - Testing aids (command line)

let args = CommandLine.arguments
if args.contains("--dump") {
    let (c, e) = loadConfig()
    print("config error:", e ?? "none")
    print("PATH has node:", userPATH.split(separator: ":").contains { FileManager.default.fileExists(atPath: "\($0)/node") })
    for a in c.apps { print("app", a.name, "dir exists:", FileManager.default.fileExists(atPath: expand(a.dir)), "port", a.port ?? 0, "listening:", !pidsListening(on: a.port ?? 0).isEmpty) }
    for p in claudeProjects().prefix(5) { print("claude", tildify(p.path), p.lastUsed) }
    for l in devListeners(hidden: []) { print("port", l.port, l.command, l.pid, tildify(l.cwd)) }
    print("drives:", externalDrives().map { "\($0.name) [\($0.model)]" })
    print("iPhone key set:", !secretKey.isEmpty, "· cache items:", cacheItems.count)
    exit(0)
}
if args.contains("--make-shortcuts") {
    do { try makeShortcuts().forEach { print($0.path) } } catch { print("error:", error.localizedDescription) }
    exit(0)
}
if let i = args.firstIndex(of: "--t7"), i + 1 < args.count {
    let a = Array(args.dropFirst(i + 1))
    let vol = a.count > 1 ? URL(fileURLWithPath: a[1]) : URL(fileURLWithPath: "/")
    let rest = Array(a.dropFirst(2))
    switch a[0] {
    case "list": externalDrives().forEach { print("\($0.name)\t\($0.model)\t\($0.url.path)\t\(fsType($0.url))") }
    case "move": let o = moveToDrive(rest, vol: vol); print("done:", o.done, "bytes:", o.bytes, "failed:", o.failed)
    case "quick": let o = quickCopyToDrive(rest, vol: vol); print("done:", o.done, "bytes:", o.bytes, "failed:", o.failed)
    case "records": loadRecords(vol).forEach { print("\($0.name)\t\($0.drivePath)") }
    case "restore": for r in loadRecords(vol) where rest.contains(r.name) { print(r.name, bringBack(r, vol: vol) ?? "ok") }
    case "scan": for c in scanCandidates(vol: vol).prefix(10) { print(fmt(c.bytes), c.title) }
    default: print("unknown")
    }
    exit(0)
}

// Only one copy at a time
let me = ProcessInfo.processInfo.processIdentifier
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "-")
    .contains(where: { $0.processIdentifier != me }) { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
