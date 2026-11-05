// DevCleaner — menu-bar app that shows and clears ONLY rebuildable developer caches.
// Never touches projects, Xcode Archives, emulators/simulators, SDKs, or ML model caches.
// Uses no CPU in the background: sizes are measured only when you open the menu.

import Cocoa
import ServiceManagement

let home = NSHomeDirectory()
let xcodeID = "com.apple.dt.Xcode"
let studioID = "com.google.android.studio"

final class CacheItem {
    let name: String, group: String, note: String
    let blockingApp: String?          // must be closed before cleaning
    let targets: () -> [String]       // folders whose CONTENTS get deleted
    var bytes: Int64 = -1             // -1 = not measured yet
    var menuItem: NSMenuItem?
    init(_ name: String, _ group: String, _ note: String, blocking: String? = nil, _ targets: @escaping () -> [String]) {
        self.name = name; self.group = group; self.note = note; self.blockingApp = blocking; self.targets = targets
    }
}

func p(_ rel: String) -> () -> [String] { { [home + "/" + rel] } }
func glob(_ dir: String, prefix: String) -> () -> [String] {
    { ((try? FileManager.default.contentsOfDirectory(atPath: home + "/" + dir)) ?? [])
        .filter { $0.hasPrefix(prefix) }.map { home + "/" + dir + "/" + $0 } }
}

let items: [CacheItem] = [
    CacheItem("Xcode build files", "iOS / Xcode", "Rebuilt automatically next time you build.", blocking: xcodeID, p("Library/Developer/Xcode/DerivedData")),
    CacheItem("Xcode caches", "iOS / Xcode", "Recreated automatically by Xcode.", blocking: xcodeID, p("Library/Caches/com.apple.dt.Xcode")),
    CacheItem("Simulator caches", "iOS / Xcode", "Recreated automatically. Your simulators are kept.", blocking: xcodeID, p("Library/Developer/CoreSimulator/Caches")),
    CacheItem("iPhone debug symbols", "iOS / Xcode", "Re-copied the next time you plug in an iPhone.", blocking: xcodeID, p("Library/Developer/Xcode/iOS DeviceSupport")),
    CacheItem("CocoaPods cache", "iOS / Xcode", "Pods are re-downloaded on the next pod install.", p("Library/Caches/CocoaPods")),
    CacheItem("Gradle caches", "Android", "Libraries are re-downloaded on the next build (needs internet, first build is slower).", blocking: studioID, p(".gradle/caches")),
    CacheItem("Old Gradle versions", "Android", "The version a project needs is re-downloaded automatically.", blocking: studioID, p(".gradle/wrapper/dists")),
    CacheItem("Gradle daemon logs", "Android", "Just log files.", blocking: studioID, p(".gradle/daemon")),
    CacheItem("Android caches", "Android", "Recreated automatically. Your emulators are kept.", blocking: studioID, p(".android/cache")),
    CacheItem("Android Studio caches", "Android", "Android Studio re-indexes on next launch.", blocking: studioID, glob("Library/Caches/Google", prefix: "AndroidStudio")),
    CacheItem("npm cache", "Other", "Packages are re-downloaded when needed.", p(".npm/_cacache")),
    CacheItem("Flutter/Dart packages", "Other", "Re-downloaded by flutter pub get (runs automatically).", p(".pub-cache/hosted")),
    CacheItem("Homebrew downloads", "Other", "Old installer files only.", p("Library/Caches/Homebrew")),
    CacheItem("pip cache", "Other", "Re-downloaded when needed.", p("Library/Caches/pip")),
    CacheItem("Yarn cache", "Other", "Re-downloaded when needed.", p("Library/Caches/Yarn")),
    CacheItem("node-gyp headers", "Other", "Re-downloaded when needed.", p("Library/Caches/node-gyp")),
]

func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

func diskUsage(_ path: String) -> Int64 {
    guard FileManager.default.fileExists(atPath: path) else { return 0 }
    let proc = Process(); let pipe = Pipe()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    proc.arguments = ["-sk", path]
    proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return 0 }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    proc.waitUntilExit()
    return (Int64(out.split(separator: "\t").first ?? "0") ?? 0) * 1024
}

func emptyFolder(_ path: String) {
    let fm = FileManager.default
    guard let children = try? fm.contentsOfDirectory(atPath: path) else { return }
    for c in children { try? fm.removeItem(atPath: path + "/" + c) }
}

func isRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}
func appName(_ bundleID: String) -> String { bundleID == xcodeID ? "Xcode" : "Android Studio" }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let header = NSMenuItem(title: "Measuring…", action: nil, keyEquivalent: "")
    let cleanAll = NSMenuItem(title: "Clean Everything", action: #selector(cleanEverything), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    var scanning = false, cleaning = false

    func applicationDidFinishLaunching(_ n: Notification) {
        status.button?.image = NSImage(systemSymbolName: "bubbles.and.sparkles", accessibilityDescription: "DevCleaner")
        status.button?.image?.isTemplate = true
        buildMenu()
        status.menu = menu
        // Start at login automatically the first time it's run.
        if !UserDefaults.standard.bool(forKey: "loginSetupDone") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginSetupDone")
        }
    }

    func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        cleanAll.target = self
        cleanAll.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(cleanAll)
        var lastGroup = ""
        for (i, item) in items.enumerated() {
            if item.group != lastGroup {
                menu.addItem(.separator())
                menu.addItem(NSMenuItem.sectionHeader(title: item.group))
                lastGroup = item.group
            }
            let mi = NSMenuItem(title: item.name, action: #selector(cleanOne(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = i; mi.toolTip = item.note
            item.menuItem = mi
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let safe = NSMenuItem(title: "Never touches: projects, Archives, simulators, emulators, SDKs", action: nil, keyEquivalent: "")
        safe.isEnabled = false
        menu.addItem(safe)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        let quit = NSMenuItem(title: "Quit DevCleaner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        refreshTitles()
    }

    func menuWillOpen(_ m: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        rescan()
    }

    func rescan() {
        guard !scanning, !cleaning else { return }
        scanning = true
        refreshTitles()
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.concurrentPerform(iterations: items.count) { i in
                let size = items[i].targets().reduce(Int64(0)) { $0 + diskUsage($1) }
                DispatchQueue.main.async { items[i].bytes = size; self.refreshTitles() }
            }
            DispatchQueue.main.async { self.scanning = false; self.refreshTitles() }
        }
    }

    func row(_ left: String, _ right: String, dim: Bool = false) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.tabStops = [NSTextTab(textAlignment: .right, location: 290)]
        let color: NSColor = dim ? .secondaryLabelColor : .labelColor
        return NSAttributedString(string: "\(left)\t\(right)", attributes: [
            .paragraphStyle: ps, .font: NSFont.menuFont(ofSize: 0), .foregroundColor: color])
    }

    func refreshTitles() {
        let total = items.reduce(Int64(0)) { $0 + max($1.bytes, 0) }
        for item in items {
            guard let mi = item.menuItem else { continue }
            let size = item.bytes < 0 ? "…" : (item.bytes == 0 ? "empty" : fmt(item.bytes))
            mi.attributedTitle = row(item.name, size, dim: item.bytes == 0)
            mi.isEnabled = item.bytes > 0 && !cleaning
        }
        if cleaning { header.title = "Cleaning…" }
        else if scanning { header.title = "Measuring… (\(fmt(total)) so far)" }
        else { header.title = total > 0 ? "\(fmt(total)) can be freed safely" : "All clean ✨" }
        cleanAll.attributedTitle = row("Clean Everything", total > 0 ? fmt(total) : "")
        cleanAll.isEnabled = total > 0 && !cleaning && !scanning
    }

    @objc func cleanOne(_ sender: NSMenuItem) {
        let item = items[sender.tag]
        confirmAndClean([item], message: "Clean \(item.name) (\(fmt(item.bytes)))?", detail: item.note)
    }

    @objc func cleanEverything() {
        let toClean = items.filter { $0.bytes > 0 }
        let total = toClean.reduce(Int64(0)) { $0 + $1.bytes }
        let list = toClean.map { "• \($0.name) — \(fmt($0.bytes))" }.joined(separator: "\n")
        confirmAndClean(toClean, message: "Free up \(fmt(total))?",
                        detail: "\(list)\n\nAll of these are rebuilt automatically when needed.")
    }

    func confirmAndClean(_ toClean: [CacheItem], message: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let blockers = Set(toClean.compactMap { $0.blockingApp }.filter(isRunning))
        if !blockers.isEmpty {
            let a = NSAlert()
            a.messageText = "Please quit \(blockers.map(appName).sorted().joined(separator: " and ")) first"
            a.informativeText = "Cleaning its caches while it's open could confuse it. Quit it, then try again."
            a.runModal()
            return
        }
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail + "\n\nYour projects are never touched."
        a.addButton(withTitle: "Clean")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        cleaning = true
        refreshTitles()
        let before = toClean.reduce(Int64(0)) { $0 + max($1.bytes, 0) }
        DispatchQueue.global(qos: .userInitiated).async {
            if toClean.contains(where: { $0.blockingApp == studioID }) {
                // Stop idle Gradle background daemons so their files can be removed.
                let k = Process()
                k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                k.arguments = ["-f", "org.gradle.launcher.daemon"]
                try? k.run(); k.waitUntilExit()
            }
            for item in toClean { item.targets().forEach(emptyFolder) }
            let after = toClean.reduce(Int64(0)) { sum, item in sum + item.targets().reduce(0) { $0 + diskUsage($1) } }
            DispatchQueue.main.async {
                self.cleaning = false
                let done = NSAlert()
                done.messageText = "Freed \(fmt(max(before - after, 0))) ✨"
                done.runModal()
                self.rescan()
            }
        }
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
        loginItem.state = svc.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
