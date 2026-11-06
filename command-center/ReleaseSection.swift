// Release Desk section of Command Center — your Android app builds in one place.
//  • Finds every Flutter / Android project, with its real app name, version and newest release build (.aab)
//  • Build Release (flutter build appbundle / gradlew bundleRelease) in the background, with a sound when done
//  • Get Ready to Upload: copies the .aab to ~/Desktop/Ready to Upload as "AppName 1.2.1 (113).aab",
//    selects it in Finder and opens Play Console — warns if the build is stale or the build number was used before
// Open it anywhere with a double-tap of Left ⌃ (sent by ClaudeHere), or from the Command Center menu.

import Cocoa

struct ReleaseApp {
    let folder: URL, androidDir: URL
    let label: String, appId: String, versionName: String, build: String
    let isFlutter: Bool
    let aab: URL?, aabDate: Date?, ipa: URL?
    let codeChangedAfterBuild: Bool
}

let releaseRoots = ["Flutter applications", "AndroidStudioProjects", "StudioProjects"]
let readyFolder = URL(fileURLWithPath: home + "/Desktop/Ready to Upload")

private func text(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
private func groups(_ pattern: String, _ s: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
}
private func newest(_ dir: URL, ext: String) -> (URL, Date)? {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
    return files.filter { $0.pathExtension == ext }
        .compactMap { f in (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map { (f, $0) } }
        .max { $0.1 < $1.1 }
}

/// The name the app shows on the phone (android:label, resolving @string/…), else the folder name.
private func appLabel(androidDir: URL, fallback: String) -> String {
    let manifest = androidDir.appendingPathComponent("app/src/main/AndroidManifest.xml")
    guard let m = text(manifest), var label = groups(#"android:label="([^"]+)""#, m)?.first else { return fallback }
    if label.hasPrefix("@string/") {
        let key = String(label.dropFirst("@string/".count))
        let strings = androidDir.appendingPathComponent("app/src/main/res/values/strings.xml")
        label = text(strings).flatMap { groups("<string name=\"\(key)\">([^<]+)<", $0)?.first } ?? fallback
    }
    return label.contains("${") || label.isEmpty ? fallback : label
}

func scanReleaseApps() -> [ReleaseApp] {
    let fm = FileManager.default
    var out: [ReleaseApp] = []
    for root in releaseRoots {
        let r = URL(fileURLWithPath: home).appendingPathComponent(root)
        guard let kids = try? fm.contentsOfDirectory(at: r, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
        for dir in kids {
            let pubspec = dir.appendingPathComponent("pubspec.yaml")
            let isFlutter = fm.fileExists(atPath: pubspec.path) && fm.fileExists(atPath: dir.appendingPathComponent("android").path)
            let isNative = !isFlutter && fm.fileExists(atPath: dir.appendingPathComponent("app").path)
                && (fm.fileExists(atPath: dir.appendingPathComponent("settings.gradle").path) || fm.fileExists(atPath: dir.appendingPathComponent("settings.gradle.kts").path))
            guard isFlutter || isNative else { continue }
            let androidDir = isFlutter ? dir.appendingPathComponent("android") : dir
            let gradle = text(androidDir.appendingPathComponent("app/build.gradle")) ?? text(androidDir.appendingPathComponent("app/build.gradle.kts")) ?? ""
            let appId = groups(#"applicationId\s*=?\s*["']([^"']+)["']"#, gradle)?.first ?? "?"
            var vName = "?", vCode = "?"
            if isFlutter, let p = text(pubspec), let g = groups(#"(?m)^version:\s*([^\s+]+)(?:\+(\S+))?"#, p) {
                vName = g[0]; vCode = g.count > 1 && !g[1].isEmpty ? g[1] : "?"
            } else {
                vName = groups(#"versionName\s*=?\s*["']([^"']+)["']"#, gradle)?.first ?? "?"
                vCode = groups(#"versionCode\s*=?\s*(\d+)"#, gradle)?.first ?? "?"
            }
            let bundleDir = isFlutter ? dir.appendingPathComponent("build/app/outputs/bundle/release")
                                      : dir.appendingPathComponent("app/build/outputs/bundle/release")
            let aab = newest(bundleDir, ext: "aab")
            let ipa = isFlutter ? newest(dir.appendingPathComponent("build/ios/ipa"), ext: "ipa") : nil
            var stale = false
            if let built = aab?.1 {
                let sources = isFlutter ? [dir.appendingPathComponent("lib"), pubspec, androidDir.appendingPathComponent("app/src")]
                                        : [dir.appendingPathComponent("app/src"), androidDir.appendingPathComponent("app/build.gradle")]
                stale = sources.contains { fm.fileExists(atPath: $0.path) && sizeAndNewest($0).1 > built.addingTimeInterval(60) }
            }
            // Your own nicknames win: defaults write com.local.commandcenter releaseNames -dict swap '"SnailPost (Dearly)"'
            let nick = (UserDefaults.standard.dictionary(forKey: "releaseNames") as? [String: String])?[dir.lastPathComponent]
            out.append(ReleaseApp(folder: dir, androidDir: androidDir, label: nick ?? appLabel(androidDir: androidDir, fallback: dir.lastPathComponent),
                                  appId: appId, versionName: vName, build: vCode, isFlutter: isFlutter,
                                  aab: aab?.0, aabDate: aab?.1, ipa: ipa?.0, codeChangedAfterBuild: stale))
        }
    }
    // Apps with builds first (newest first), then the rest alphabetically
    return out.sorted {
        switch ($0.aabDate, $1.aabDate) {
        case let (a?, b?): return a > b
        case (_?, nil): return true
        case (nil, _?): return false
        default: return $0.label.lowercased() < $1.label.lowercased()
        }
    }
}

/// Everything you can trigger, for the menu's cheat sheet.
func shortcutsMenu() -> NSMenu {
    let m = NSMenu(); m.autoenablesItems = false
    func header(_ t: String) { m.addItem(NSMenuItem.sectionHeader(title: t)) }
    func row(_ keys: String, _ what: String) {
        let ps = NSMutableParagraphStyle(); ps.tabStops = [NSTextTab(textAlignment: .left, location: 150)]
        let i = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        i.attributedTitle = NSAttributedString(string: "\(keys)\t\(what)", attributes: [.paragraphStyle: ps, .font: NSFont.menuFont(ofSize: 0)])
        i.isEnabled = false
        m.addItem(i)
    }
    header("Double-tap (ClaudeHere)")
    row("⌥⌥  in Finder", "Open Claude in that folder")
    row("Right ⌘⌘", "Screenshot → your Claude session")
    row("Right ⇧⇧  in Finder", "Copy selection to T7")
    row("Left ⇧⇧  in Finder", "AirDrop selection to your iPhone")
    row("Left ⌃⌃", "Release Desk (Android builds)")
    m.addItem(.separator())
    header("Command Center")
    row("⌃⌥Space", "Open this menu")
    row("⌃⌥M  /  ⌃⌥C", "Move / copy Finder selection to T7")
    row("⌃⌥E", "Eject T7")
    row("Drag onto ⌘ icon", "Move or copy files to T7")
    row("⌥-click a project", "New Claude chat (instead of continue)")
    m.addItem(.separator())
    header("iPhone (Back Tap)")
    row("Tap back ×2", "iPhone clipboard → Mac")
    row("Tap back ×3", "Mac clipboard → iPhone")
    return m
}

final class ReleaseSection: NSObject {
    weak var hub: Hub?
    var apps: [ReleaseApp] = []
    var busy: String? { didSet { hub?.updateStatus() } }
    let work = DispatchQueue(label: "commandcenter.release")
    var buildTimer: Timer?

    func start() {
        refresh()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(popUpMenu),
                                                            name: Notification.Name("com.local.commandcenter.releaseMenu"), object: nil)
    }

    func refresh(then: (() -> Void)? = nil) {
        work.async {
            let a = scanReleaseApps()
            DispatchQueue.main.async { self.apps = a; then?() }
        }
    }

    /// Left ⌃⌃ from ClaudeHere: show the Release Desk right at the mouse.
    @objc func popUpMenu() {
        refresh {
            let m = NSMenu(); m.autoenablesItems = false
            self.buildMenu(m, withShortcuts: true)
            m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    var prepared: [String: [String: Date]] {   // appId → build number → when it was prepared
        get { UserDefaults.standard.dictionary(forKey: "preparedBuilds") as? [String: [String: Date]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "preparedBuilds") }
    }

    @discardableResult
    func add(_ m: NSMenu, _ title: String, _ action: Selector?, enabled: Bool = true, symbol: String? = nil, rep: Any? = nil) -> NSMenuItem {
        let i = menuItem(title, action, target: self, enabled: enabled, symbol: symbol, rep: rep)
        m.addItem(i); return i
    }

    func buildMenu(_ menu: NSMenu, withShortcuts: Bool) {
        menu.addItem(NSMenuItem.sectionHeader(title: "🚀 Release Desk — Android builds"))
        if let busy { add(menu, "⏳ \(busy)", nil) }
        if apps.isEmpty { add(menu, "No Flutter/Android projects found in ~/\(releaseRoots[0])", nil) }
        let rf = RelativeDateTimeFormatter(); rf.unitsStyle = .short
        for (i, a) in apps.enumerated() {
            var info = a.aabDate.map { "built \(rf.localizedString(for: $0, relativeTo: Date()))" } ?? "no build yet"
            if a.codeChangedAfterBuild { info += " ⚠︎" }
            let folderName = a.folder.lastPathComponent
            let where_ = a.label.lowercased().contains(folderName.lowercased()) ? "" : "   [\(folderName)]"
            let row = add(menu, "\(a.label)\(where_)   \(a.versionName) (\(a.build))   ·  \(info)", nil,
                          symbol: a.aab == nil ? "shippingbox" : (a.codeChangedAfterBuild ? "exclamationmark.triangle" : "shippingbox.fill"))
            row.isEnabled = true
            let sub = NSMenu(); sub.autoenablesItems = false
            add(sub, "Get Ready to Upload", #selector(prepare(_:)), enabled: a.aab != nil && busy == nil, symbol: "arrow.up.doc", rep: i)
            add(sub, "Build Release", #selector(build(_:)), enabled: busy == nil, symbol: "hammer", rep: i)
            add(sub, "Show Build in Finder", #selector(showBuild(_:)), enabled: a.aab != nil, symbol: "magnifyingglass", rep: i)
            if a.ipa != nil { add(sub, "Show iOS .ipa", #selector(showIPA(_:)), symbol: "iphone", rep: i) }
            sub.addItem(.separator())
            add(sub, "Open Project Folder", #selector(openFolder(_:)), symbol: "folder", rep: i)
            if FileManager.default.fileExists(atPath: "/Applications/Android Studio.app") {
                add(sub, "Open in Android Studio", #selector(openStudio(_:)), symbol: "hammer.circle", rep: i)
            }
            add(sub, "Build Log", #selector(showLog(_:)), symbol: "doc.text.magnifyingglass", rep: i)
            sub.addItem(.separator())
            if a.codeChangedAfterBuild { add(sub, "⚠︎ Code changed after this build — rebuild before uploading", nil) }
            if let when = prepared[a.appId]?[a.build] {
                add(sub, "⚠︎ Build \(a.build) was already prepared \(rf.localizedString(for: when, relativeTo: Date())) — bump the version", nil)
            }
            add(sub, "Package: \(a.appId)", nil)
            add(sub, "Folder: \(tildify(a.folder.path))", nil)
            row.submenu = sub
        }
        menu.addItem(.separator())
        add(menu, "Open “Ready to Upload” Folder", #selector(openReady), symbol: "tray.and.arrow.up")
        add(menu, "Open Play Console", #selector(openConsole), symbol: "safari")
        if withShortcuts {
            let s = add(menu, "⌨️ All Shortcuts", nil); s.isEnabled = true; s.submenu = shortcutsMenu()
        }
    }

    func app(_ s: NSMenuItem) -> ReleaseApp? {
        guard let i = s.representedObject as? Int, i < apps.count else { return nil }
        return apps[i]
    }

    // MARK: actions

    @objc func prepare(_ s: NSMenuItem) { if let a = app(s) { prepareApp(a) } }

    func prepareApp(_ a: ReleaseApp) {
        guard let aab = a.aab else { return }
        var warnings: [String] = []
        if a.codeChangedAfterBuild { warnings.append("Your code changed after this build was made — you may be uploading an old version.") }
        if prepared[a.appId]?[a.build] != nil {
            warnings.append("Build number \(a.build) was already prepared before. Play Console rejects a build number it has already seen — bump the number after + in \(a.isFlutter ? "pubspec.yaml" : "build.gradle") and rebuild.")
        }
        if !warnings.isEmpty {
            let r = showAlert("Check before uploading \(a.label)", warnings.joined(separator: "\n\n"), buttons: ["Use This Build Anyway", "Build New Release", "Cancel"])
            if r == .alertSecondButtonReturn { startBuild(a); return }
            if r != .alertFirstButtonReturn { return }
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: readyFolder, withIntermediateDirectories: true)
        let dest = readyFolder.appendingPathComponent("\(a.label) \(a.versionName) (\(a.build)).aab")
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: aab, to: dest) } catch { showAlert("Couldn't copy the build", error.localizedDescription); return }
        var p = prepared; p[a.appId, default: [:]][a.build] = Date(); prepared = p
        let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects([dest as NSURL])
        NSWorkspace.shared.activateFileViewerSelecting([dest])
        NSWorkspace.shared.open(URL(string: "https://play.google.com/console")!)
        hub?.flash("✓ \(a.label) \(a.versionName) (\(a.build)) ready to upload")
        log("Release Desk: prepared \(dest.lastPathComponent)")
    }

    @objc func build(_ s: NSMenuItem) { if let a = app(s) { startBuild(a) } }

    func logURL(_ a: ReleaseApp) -> URL { logDir.appendingPathComponent("build-\(a.folder.lastPathComponent).log") }

    func startBuild(_ a: ReleaseApp) {
        guard busy == nil else { NSSound.beep(); return }
        let started = Date()
        busy = "Building \(a.label)…"
        buildTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.busy = "Building \(a.label)… \(Int(Date().timeIntervalSince(started) / 60))m"
        }
        let log = logURL(a)
        work.async {
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let h = try? FileHandle(forWritingTo: log)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", a.isFlutter ? "flutter build appbundle --release" : "./gradlew bundleRelease"]
            p.currentDirectoryURL = a.isFlutter ? a.folder : a.androidDir
            var env = ProcessInfo.processInfo.environment; env["PATH"] = userPATH; p.environment = env
            p.standardOutput = h; p.standardError = h; p.standardInput = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { }
            try? h?.close()
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async {
                self.buildTimer?.invalidate(); self.buildTimer = nil
                self.busy = nil
                let mins = max(1, Int(Date().timeIntervalSince(started) / 60))
                self.refresh {
                    if ok, let fresh = self.apps.first(where: { $0.folder == a.folder }) {
                        NSSound(named: "Glass")?.play()
                        if showAlert("✅ \(fresh.label) \(fresh.versionName) (\(fresh.build)) built in \(mins) min",
                                     "", buttons: ["Get Ready to Upload", "OK"]) == .alertFirstButtonReturn { self.prepareApp(fresh) }
                    } else {
                        NSSound(named: "Basso")?.play()
                        let tail = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").suffix(8).joined(separator: "\n") ?? ""
                        if showAlert("❌ \(a.label) build failed", tail, buttons: ["Show Log", "OK"]) == .alertFirstButtonReturn {
                            NSWorkspace.shared.open(log)
                        }
                    }
                }
            }
        }
    }

    @objc func showBuild(_ s: NSMenuItem) { if let u = app(s)?.aab { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc func showIPA(_ s: NSMenuItem) { if let u = app(s)?.ipa { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc func openFolder(_ s: NSMenuItem) { if let a = app(s) { NSWorkspace.shared.open(a.folder) } }
    @objc func openStudio(_ s: NSMenuItem) {
        guard let a = app(s) else { return }
        NSWorkspace.shared.open([a.androidDir], withApplicationAt: URL(fileURLWithPath: "/Applications/Android Studio.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func showLog(_ s: NSMenuItem) {
        guard let a = app(s) else { return }
        let u = logURL(a)
        if !FileManager.default.fileExists(atPath: u.path) { showAlert("No build log yet", "Use Build Release once and its log appears here."); return }
        NSWorkspace.shared.open(u)
    }
    @objc func openReady() {
        try? FileManager.default.createDirectory(at: readyFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(readyFolder)
    }
    @objc func openConsole() { NSWorkspace.shared.open(URL(string: "https://play.google.com/console")!) }
}
