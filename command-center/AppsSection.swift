// Apps section of Command Center (your local dashboards, scripts, Claude projects, dev ports, links).
//  • Your local dashboards/servers run in the background (no Terminal windows), auto-restart if they crash,
//    open in the browser with one click, optional start at login, per-app logs.
//  • One-shot scripts (e.g. "sync & open marketing") run with one click.
//  • Your recent Claude Code projects, newest first: click = continue the last chat there (⌥-click = new chat).
//  • Busy dev ports: see what's listening and kill a stuck server.
//  • Quick links (consoles, dashboards).
//  • ⌃⌥Space opens the menu from anywhere.
// Configure everything in ~/Library/Application Support/CommandCenter/config.json (menu → Edit Config…).
// Only built-in macOS frameworks. Idle until you use it.

import Cocoa
import Carbon.HIToolbox
import ServiceManagement


// MARK: - Config

struct AppDef: Codable {
    var id: String, name: String, emoji: String?
    var dir: String, command: String
    var port: Int?, url: String?
    var autoStart: Bool?
}
struct ScriptDef: Codable { var name: String, emoji: String?, command: String, dir: String? }
struct LinkDef: Codable { var name: String, url: String }
struct Config: Codable {
    var apps: [AppDef] = []
    var scripts: [ScriptDef] = []
    var links: [LinkDef] = []
    var claudeProjectsShown: Int? = 8
    var hiddenPortProcesses: [String]? = nil
}

let supportDir = URL(fileURLWithPath: home + "/Library/Application Support/CommandCenter")
let configURL = supportDir.appendingPathComponent("config.json")

let defaultConfigJSON = """
{
  "apps": [
    { "id": "my-dashboard", "name": "My Dashboard", "emoji": "📊",
      "dir": "~/path/to/project",
      "command": "[ -d node_modules ] || npm install; exec npm start",
      "port": 3000, "url": "http://localhost:3000", "autoStart": false }
  ],
  "scripts": [
    { "name": "Example — say hello", "emoji": "👋", "command": "say hello" }
  ],
  "links": [
    { "name": "App Store Connect", "url": "https://appstoreconnect.apple.com" },
    { "name": "Google Play Console", "url": "https://play.google.com/console" },
    { "name": "Firebase Console", "url": "https://console.firebase.google.com" },
    { "name": "GitHub", "url": "https://github.com" }
  ],
  "claudeProjectsShown": 8
}
"""

func loadConfig() -> (Config, String?) {
    let fm = FileManager.default
    try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
    if !fm.fileExists(atPath: configURL.path) { try? defaultConfigJSON.write(to: configURL, atomically: true, encoding: .utf8) }
    do {
        let data = try Data(contentsOf: configURL)
        return (try JSONDecoder().decode(Config.self, from: data), nil)
    } catch {
        return ((try? JSONDecoder().decode(Config.self, from: Data(defaultConfigJSON.utf8))) ?? Config(), "\(error)")
    }
}

// MARK: - Shell helpers

/// PATH from your interactive shell, so node/npm/nvm/python work exactly like in Terminal.
let userPATH: String = {
    let p = Process(); let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-ilc", "echo __PATH__$PATH"]
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    var path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if (try? p.run()) != nil {
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let line = out.components(separatedBy: "\n").last(where: { $0.hasPrefix("__PATH__") }) {
            path = String(line.dropFirst("__PATH__".count))
        }
    }
    return path
}()

@discardableResult
func sh(_ cmd: String) -> String {
    let p = Process(); let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return out
}

func pidsListening(on port: Int) -> [Int32] {
    sh("/usr/sbin/lsof -tiTCP:\(port) -sTCP:LISTEN 2>/dev/null").split(separator: "\n").compactMap { Int32($0) }
}

func killPids(_ pids: [Int32]) {
    pids.forEach { kill($0, SIGTERM) }
    usleep(800_000)
    pids.forEach { kill($0, SIGKILL) }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
func runInTerminal(_ cmd: String) {
    var err: NSDictionary?
    NSAppleScript(source: "tell application \"Terminal\"\n activate\n do script \(appleQuote(cmd))\nend tell")?.executeAndReturnError(&err)
}

// MARK: - Managed app (server) processes

final class ManagedApp {
    var def: AppDef
    var process: Process?
    var stopping = false
    var restarts: [Date] = []
    var crashed = false
    var lastError: String?
    var logURL: URL { logDir.appendingPathComponent("\(def.id).log") }
    var onChange: (() -> Void)?

    init(_ d: AppDef) { def = d }

    var ownProcessRunning: Bool { process?.isRunning == true }

    enum State { case running, external, starting, stopped, crashed }
    func state() -> State {
        if crashed { return .crashed }
        if let port = def.port {
            let listening = !pidsListening(on: port).isEmpty
            if listening { return ownProcessRunning ? .running : .external }
            return ownProcessRunning ? .starting : .stopped
        }
        return ownProcessRunning ? .running : .stopped
    }

    func start() {
        guard !ownProcessRunning else { return }
        let dir = expand(def.dir)
        guard FileManager.default.fileExists(atPath: dir) else {
            lastError = "Folder not found: \(tildify(dir))"; crashed = true; onChange?(); return
        }
        if let port = def.port, !pidsListening(on: port).isEmpty { onChange?(); return } // already running elsewhere
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try? FileHandle(forWritingTo: logURL)
        log?.seekToEndOfFile()
        log?.write("\n===== \(Date()) starting \(def.name) =====\n".data(using: .utf8)!)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", def.command]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPATH
        if let port = def.port { env["PORT"] = String(port) }
        p.environment = env
        p.standardOutput = log; p.standardError = log
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.exited(code: proc.terminationStatus) }
        }
        stopping = false; crashed = false; lastError = nil
        do { try p.run(); process = p } catch { lastError = "\(error)"; crashed = true }
        onChange?()
    }

    func exited(code: Int32) {
        process = nil
        if stopping { stopping = false; onChange?(); return }
        // Unexpected exit → restart, but give up after 3 crashes in 2 minutes.
        restarts = restarts.filter { $0 > Date().addingTimeInterval(-120) }
        let tail = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
        if restarts.count >= 3 {
            crashed = true
            lastError = "Keeps crashing (exit \(code)). Last log lines:\n\(tail)"
            onChange?()
            return
        }
        restarts.append(Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() }
        onChange?()
    }

    func stop() {
        stopping = true
        if let p = process, p.isRunning { p.terminate() }
        // npm etc. can leave the real server behind — make sure the port is free.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if let port = self.def.port { killPids(pidsListening(on: port)) }
            DispatchQueue.main.async { self.crashed = false; self.onChange?() }
        }
    }

    func restart() {
        crashed = false; restarts = []
        stopping = true
        process?.terminate()
        DispatchQueue.global().async {
            if let port = self.def.port { killPids(pidsListening(on: port)) }
            usleep(500_000)
            DispatchQueue.main.async { self.process = nil; self.start() }
        }
    }
}

// MARK: - Claude Code projects

struct ClaudeProject { let path: String; let lastUsed: Date }

func claudeProjects() -> [ClaudeProject] {
    let root = URL(fileURLWithPath: home + "/.claude/projects")
    let fm = FileManager.default
    guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
    var seen = Set<String>()
    var out: [ClaudeProject] = []
    for d in dirs {
        guard let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
        let sessions = files.filter { $0.pathExtension == "jsonl" }
            .compactMap { f -> (URL, Date)? in
                guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
                return (f, m)
            }.sorted { $0.1 > $1.1 }
        guard let newest = sessions.first, let cwd = cwdFromSession(newest.0) else { continue }
        guard fm.fileExists(atPath: cwd), !seen.contains(cwd) else { continue }
        seen.insert(cwd)
        out.append(ClaudeProject(path: cwd, lastUsed: newest.1))
    }
    return out.sorted { $0.lastUsed > $1.lastUsed }
}

/// Reads the working directory recorded in a Claude Code session file (first lines only).
func cwdFromSession(_ url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let chunk = h.readData(ofLength: 256 * 1024)
    for line in chunk.split(separator: UInt8(ascii: "\n")).prefix(60) {
        if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let cwd = obj["cwd"] as? String {
            return cwd
        }
    }
    return nil
}

// MARK: - Busy ports

struct Listener { let command: String; let pid: Int32; let port: Int; let cwd: String }

// Exact process names of typical dev servers (python3.12 etc. matched by prefix "python").
let devProcessNames: Set<String> = ["node", "java", "ruby", "php", "deno", "bun", "dart", "uvicorn", "gunicorn", "flask", "dotnet", "beam.smp", "esbuild"]
func isDevProcess(_ cmd: String) -> Bool {
    let c = cmd.lowercased()
    return devProcessNames.contains(c) || c.hasPrefix("python")
}

func devListeners(hidden: [String]) -> [Listener] {
    let out = sh("/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcn 2>/dev/null")
    var result: [Listener] = []
    var pid: Int32 = 0, cmd = ""
    var seen = Set<String>()
    for line in out.split(separator: "\n") {
        guard let t = line.first else { continue }
        let v = String(line.dropFirst())
        switch t {
        case "p": pid = Int32(v) ?? 0
        case "c": cmd = v
        case "n":
            guard let portStr = v.split(separator: ":").last, let port = Int(portStr) else { continue }
            guard isDevProcess(cmd), !hidden.contains(cmd), !seen.contains("\(pid):\(port)") else { continue }
            seen.insert("\(pid):\(port)")
            let cwd = sh("/usr/sbin/lsof -a -d cwd -p \(pid) -Fn 2>/dev/null").split(separator: "\n").first(where: { $0.hasPrefix("n") }).map { String($0.dropFirst()) } ?? ""
            // Gradle / Kotlin build daemons aren't servers you'd open — skip the noise.
            if cwd.contains("/.gradle/daemon") || cwd.contains("/kotlin/daemon") { continue }
            result.append(Listener(command: cmd, pid: pid, port: port, cwd: cwd))
        default: break
        }
    }
    return result.sorted { $0.port < $1.port }
}

// MARK: - App

final class AppsSection: NSObject {
    weak var hub: Hub?
    var config = Config()
    var configError: String?
    var apps: [ManagedApp] = []
    var runningScripts = Set<String>()
    var projectsCache: [ClaudeProject] = []

    func start() {
        reloadConfig(startAutoApps: true)
        refreshProjects()
    }

    func refreshProjects() {
        DispatchQueue.global(qos: .utility).async {
            let p = claudeProjects()
            DispatchQueue.main.async { self.projectsCache = p }
        }
    }

    var anyCrashed: Bool { apps.contains { $0.crashed } }

    func stopOwnedApps() {
        for a in apps where a.ownProcessRunning { a.stopping = true; a.process?.terminate() }
    }

    func reloadConfig(startAutoApps: Bool) {
        (config, configError) = loadConfig()
        // keep running processes for apps that still exist
        var newApps: [ManagedApp] = []
        for d in config.apps {
            if let existing = apps.first(where: { $0.def.id == d.id }) { existing.def = d; newApps.append(existing) }
            else {
                let m = ManagedApp(d)
                m.onChange = { [weak self] in self?.updateIcon() }
                newApps.append(m)
            }
        }
        for old in apps where !newApps.contains(where: { $0 === old }) { old.stop() }
        apps = newApps
        if startAutoApps { apps.filter { $0.def.autoStart == true }.forEach { $0.start() } }
        updateIcon()
    }

    func updateIcon() { hub?.updateStatus() }

    // MARK: menu

    @discardableResult
    func add(_ m: NSMenu, _ title: String, _ action: Selector? = nil, rep: Any? = nil, symbol: String? = nil,
             enabled: Bool = true, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self; i.representedObject = rep
        i.isEnabled = enabled && (action != nil)
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        m.addItem(i)
        return i
    }
    func header(_ m: NSMenu, _ t: String) { m.addItem(NSMenuItem.sectionHeader(title: t)) }

    func buildMain(_ menu: NSMenu) {
        if let e = configError {
            add(menu, "⚠️ Config has an error — using defaults", #selector(editConfig), symbol: nil)
            add(menu, String(e.prefix(80)), enabled: false)
            menu.addItem(.separator())
        }

        // Apps
        header(menu, "Your Apps")
        for a in apps {
            let st = a.state()
            let dot: String = { switch st {
                case .running: return "🟢"; case .external: return "🟢"; case .starting: return "🟡"
                case .stopped: return "⚪️"; case .crashed: return "🔴" } }()
            var title = "\(dot)  \(a.def.emoji.map { $0 + " " } ?? "")\(a.def.name)"
            if st == .external { title += "  (started elsewhere)" }
            if st == .starting { title += "  (starting…)" }
            let item = add(menu, title, rep: a.def.id)
            item.isEnabled = true
            let sub = NSMenu(); sub.autoenablesItems = false
            if let u = a.def.url { add(sub, "Open \(u.replacingOccurrences(of: "http://", with: ""))", #selector(openApp(_:)), rep: a.def.id, symbol: "safari", enabled: st != .stopped && st != .crashed) }
            if st == .stopped || st == .crashed {
                add(sub, "Start", #selector(startApp(_:)), rep: a.def.id, symbol: "play.fill")
            } else {
                add(sub, "Restart", #selector(restartApp(_:)), rep: a.def.id, symbol: "arrow.clockwise")
                add(sub, "Stop", #selector(stopApp(_:)), rep: a.def.id, symbol: "stop.fill")
            }
            sub.addItem(.separator())
            add(sub, "Show Log", #selector(showLog(_:)), rep: a.def.id, symbol: "doc.text.magnifyingglass")
            add(sub, "Open Folder", #selector(openFolder(_:)), rep: expand(a.def.dir), symbol: "folder")
            add(sub, "Claude in This Folder", #selector(claudeContinue(_:)), rep: expand(a.def.dir), symbol: "terminal")
            let auto = add(sub, "Start at Login", #selector(toggleAutoStart(_:)), rep: a.def.id)
            auto.state = a.def.autoStart == true ? .on : .off
            if let err = a.lastError {
                sub.addItem(.separator())
                for line in err.split(separator: "\n").prefix(4) { add(sub, "⚠️ " + String(line.prefix(90)), enabled: false) }
            }
            item.submenu = sub
        }
        let allStopped = apps.allSatisfy { $0.state() == .stopped }
        add(menu, allStopped ? "Start All" : "Restart All", #selector(startAll), symbol: allStopped ? "play.circle" : "arrow.clockwise.circle")
        if apps.contains(where: { $0.ownProcessRunning }) { add(menu, "Stop All", #selector(stopAll), symbol: "stop.circle") }

        // Scripts
        if !config.scripts.isEmpty {
            menu.addItem(.separator())
            header(menu, "Quick Actions")
            for s in config.scripts {
                let busy = runningScripts.contains(s.name)
                add(menu, "\(s.emoji.map { $0 + "  " } ?? "")\(s.name)\(busy ? "  (running…)" : "")", #selector(runScript(_:)), rep: s.name, enabled: !busy)
            }
        }

        // Claude projects
        menu.addItem(.separator())
        header(menu, "Claude — Recent Projects")
        let shown = config.claudeProjectsShown ?? 8
        let rf = RelativeDateTimeFormatter(); rf.unitsStyle = .short
        func projectItem(_ p: ClaudeProject, in m: NSMenu) {
            let name = URL(fileURLWithPath: p.path).lastPathComponent
            let it = add(m, "\(name)   ·  \(rf.localizedString(for: p.lastUsed, relativeTo: Date()))", #selector(claudeContinue(_:)), rep: p.path, symbol: "bubble.left.and.text.bubble.right")
            it.toolTip = "\(tildify(p.path))\nClick: continue last chat · ⌥-click: new chat"
            let alt = add(m, "\(name)  —  new chat", #selector(claudeNew(_:)), rep: p.path, symbol: "plus.bubble")
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = .option
        }
        if projectsCache.isEmpty { add(menu, "Loading…", enabled: false) }
        projectsCache.prefix(shown).forEach { projectItem($0, in: menu) }
        if projectsCache.count > shown {
            let more = add(menu, "More Projects (\(projectsCache.count - shown))", symbol: "ellipsis.circle")
            more.isEnabled = true
            let sub = NSMenu(); sub.autoenablesItems = false
            projectsCache.dropFirst(shown).forEach { projectItem($0, in: sub) }
            more.submenu = sub
        }
        add(menu, "Hold ⌥ for a new chat instead of continuing", enabled: false)

    }

    func buildExtras(_ menu: NSMenu) {
        // Ports
        menu.addItem(.separator())
        let listeners = devListeners(hidden: config.hiddenPortProcesses ?? [])
        let portsItem = add(menu, "Busy Dev Ports (\(listeners.count))", symbol: "network")
        portsItem.isEnabled = true
        let psub = NSMenu(); psub.autoenablesItems = false
        if listeners.isEmpty { add(psub, "No dev servers listening", enabled: false) }
        for l in listeners {
            let where_ = l.cwd.isEmpty ? "" : "  ·  \(URL(fileURLWithPath: l.cwd).lastPathComponent)"
            let it = add(psub, ":\(l.port)  \(l.command)\(where_)", symbol: "circle.fill")
            it.isEnabled = true
            let lsub = NSMenu(); lsub.autoenablesItems = false
            add(lsub, "Open http://localhost:\(l.port)", #selector(openURL(_:)), rep: "http://localhost:\(l.port)", symbol: "safari")
            add(lsub, "Kill (pid \(l.pid))", #selector(killListener(_:)), rep: [l.pid, l.port], symbol: "xmark.octagon")
            if !l.cwd.isEmpty { add(lsub, tildify(l.cwd), #selector(openFolder(_:)), rep: l.cwd, symbol: "folder") }
            it.submenu = lsub
        }
        portsItem.submenu = psub

        // Links
        if !config.links.isEmpty {
            let li = add(menu, "Quick Links", symbol: "link")
            li.isEnabled = true
            let lsub = NSMenu(); lsub.autoenablesItems = false
            for l in config.links { add(lsub, l.name, #selector(openURL(_:)), rep: l.url) }
            li.submenu = lsub
        }

    }

    func app(_ sender: NSMenuItem) -> ManagedApp? { apps.first { $0.def.id == sender.representedObject as? String } }

    // MARK: actions

    @objc func openApp(_ s: NSMenuItem) {
        guard let a = app(s) else { return }
        if a.state() == .stopped { a.start() }
        openWhenReady(a)
    }

    func openWhenReady(_ a: ManagedApp, attempt: Int = 0) {
        guard let u = a.def.url, let url = URL(string: u) else { return }
        if let port = a.def.port, pidsListening(on: port).isEmpty {
            if attempt < 40 && !a.crashed { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openWhenReady(a, attempt: attempt + 1) } }
            else { alert("\(a.def.name) didn't start", a.lastError ?? "Check its log (menu → \(a.def.name) → Show Log).") }
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc func startApp(_ s: NSMenuItem) { guard let a = app(s) else { return }; a.crashed = false; a.restarts = []; a.start(); openWhenReady(a) }
    @objc func stopApp(_ s: NSMenuItem) { app(s)?.stop() }
    @objc func restartApp(_ s: NSMenuItem) { guard let a = app(s) else { return }; a.restart(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.openWhenReady(a) } }
    @objc func startAll() {
        for a in apps {
            switch a.state() {
            case .stopped, .crashed: a.crashed = false; a.restarts = []; a.start()
            default: a.restart()
            }
        }
    }
    @objc func stopAll() { apps.filter { $0.ownProcessRunning }.forEach { $0.stop() } }

    @objc func showLog(_ s: NSMenuItem) {
        guard let a = app(s) else { return }
        if !FileManager.default.fileExists(atPath: a.logURL.path) {
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: a.logURL.path, contents: Data("(no output yet)\n".utf8))
        }
        NSWorkspace.shared.open([a.logURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func toggleAutoStart(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String,
              var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL))) as? [String: Any],
              var list = json["apps"] as? [[String: Any]],
              let idx = list.firstIndex(where: { $0["id"] as? String == id }) else { return }
        list[idx]["autoStart"] = !((list[idx]["autoStart"] as? Bool) ?? false)
        json["apps"] = list
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL)
        }
        reloadConfig(startAutoApps: false)
    }

    @objc func runScript(_ s: NSMenuItem) {
        guard let name = s.representedObject as? String, let def = config.scripts.first(where: { $0.name == name }) else { return }
        runningScripts.insert(name)
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", def.command]
            if let d = def.dir { p.currentDirectoryURL = URL(fileURLWithPath: expand(d)) }
            var env = ProcessInfo.processInfo.environment; env["PATH"] = userPATH; p.environment = env
            p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
            try? p.run()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.runningScripts.remove(name)
                if p.terminationStatus != 0 {
                    self.alert("“\(name)” failed", out.split(separator: "\n").suffix(6).joined(separator: "\n"))
                }
            }
        }
    }

    @objc func claudeContinue(_ s: NSMenuItem) {
        guard let path = s.representedObject as? String else { return }
        runInTerminal("cd \(shellQuote(path)) && clear && (claude -c || claude)")
    }
    @objc func claudeNew(_ s: NSMenuItem) {
        guard let path = s.representedObject as? String else { return }
        runInTerminal("cd \(shellQuote(path)) && clear && claude")
    }

    @objc func killListener(_ s: NSMenuItem) {
        guard let v = s.representedObject as? [Int], v.count == 2 else { return }
        let pid = Int32(v[0])
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Kill the server on port \(v[1])?"
        a.informativeText = "Process \(pid) will be stopped. Unsaved work in that server (not your files) is lost."
        a.addButton(withTitle: "Kill"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global().async { killPids([pid]); DispatchQueue.main.async { self.updateIcon() } }
    }

    @objc func openURL(_ s: NSMenuItem) { if let u = s.representedObject as? String, let url = URL(string: u) { NSWorkspace.shared.open(url) } }
    @objc func openFolder(_ s: NSMenuItem) { if let p = s.representedObject as? String { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }

    @objc func editConfig() {
        _ = loadConfig()
        NSWorkspace.shared.open([configURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func reloadConfigAction() {
        reloadConfig(startAutoApps: false)
        if let e = configError { alert("Config has an error", "Fix config.json and reload.\n\n\(e)") }
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}

