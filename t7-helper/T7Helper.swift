// T7 Helper — menu-bar app for an external SSD (made for a Samsung T7, works with any drive).
//  • Shows free space whenever the drive is plugged in
//  • ⌃⌥M  Move selected Finder items to the drive (copy → verify → originals to Trash)
//  • ⌃⌥C  Copy selected Finder items to the drive
//  • "Moved to drive" list with one-click Bring Back to the original location
//  • Sync chosen folders to the drive automatically each time it's plugged in
//  • Safe eject
// Only built-in macOS frameworks. No polling: it reacts to mount/unmount events only.

import Cocoa
import Carbon.HIToolbox
import DiskArbitration
import ServiceManagement

// MARK: - Settings

let offloadFolder = "From Mac"            // moved items live here, mirroring their path in your home folder
let copyFolder = "Copied from Mac"
let syncFolder = "Synced Folders"
let manifestFile = ".t7helper-manifest.json"
// Rebuildable folders skipped when syncing projects
let syncExcludes = ["node_modules", "build", ".gradle", "Pods", "DerivedData", ".dart_tool", ".build",
                    ".next", ".expo", "__pycache__", ".venv", "venv", ".DS_Store"]
let home = ProcessInfo.processInfo.environment["T7HELPER_HOME"] ?? NSHomeDirectory()   // override is for testing only

// MARK: - Helpers

func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

@discardableResult
func run(_ exe: String, _ args: [String]) -> (status: Int32, err: String) {
    let p = Process(); let errPipe = Pipe()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = errPipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, err.trimmingCharacters(in: .whitespacesAndNewlines))
}

func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

func fsType(_ url: URL) -> String {
    var s = statfs()
    guard statfs(url.path, &s) == 0 else { return "" }
    return withUnsafePointer(to: &s.f_fstypename) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
    }
}

func freeSpace(_ url: URL) -> Int64 {
    let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    if let important = v?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
    return Int64(v?.volumeAvailableCapacity ?? 0)
}
func totalSpace(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity ?? 0)
}

/// Counts files (incl. symlinks) and their bytes, ignoring Finder/AppleDouble junk, so a copy can be verified.
struct TreeStats: Equatable { var files = 0; var bytes: Int64 = 0 }
func treeStats(_ url: URL) -> TreeStats {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
    func ignored(_ name: String) -> Bool { name.hasPrefix("._") || name == ".DS_Store" }
    var s = TreeStats()
    func add(_ u: URL) {
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return }
        if v.isDirectory == true && v.isSymbolicLink != true { return }
        s.files += 1
        if v.isSymbolicLink != true { s.bytes += Int64(v.fileSize ?? 0) }
    }
    let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if v?.isDirectory != true || v?.isSymbolicLink == true { add(url); return s }
    let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [])
    while let u = e?.nextObject() as? URL {
        if ignored(u.lastPathComponent) { continue }
        add(u)
    }
    return s
}

func uniqueURL(_ url: URL, suffix: String = "") -> URL {
    if !exists(url) && suffix.isEmpty { return url }
    let ext = url.pathExtension
    let base = url.deletingPathExtension().lastPathComponent
    let dir = url.deletingLastPathComponent()
    func make(_ tag: String) -> URL {
        let name = base + tag
        return dir.appendingPathComponent(ext.isEmpty ? name : name + "." + ext)
    }
    var candidate = make(suffix)
    var i = 2
    while exists(candidate) { candidate = make("\(suffix) \(i)"); i += 1 }
    return candidate
}

/// Copies with ditto, then verifies file count + bytes match. Removes the partial copy on failure.
func copyVerified(_ src: URL, to dst: URL) -> String? {
    try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    let r = run("/usr/bin/ditto", [src.path, dst.path])
    if r.status != 0 {
        try? FileManager.default.removeItem(at: dst)
        let hint = r.err.contains("not supported") ? " (this drive's format can't store some items, like shortcuts/symlinks)" : ""
        return "copy failed\(hint): \(r.err.split(separator: "\n").first ?? "")"
    }
    let a = treeStats(src), b = treeStats(dst)
    if a != b {
        try? FileManager.default.removeItem(at: dst)
        return "check failed — \(b.files) of \(a.files) files arrived (this drive's format may not support some items, like shortcuts/symlinks)"
    }
    return nil
}

// MARK: - Drive detection

struct Drive { let url: URL; let name: String; let uuid: String; let model: String }

/// Mount points of Time Machine backup disks — never offered as a drive. Cached; reset on mount/unmount.
var timeMachineMountsCache: Set<String>?
func timeMachineMounts() -> Set<String> {
    if let c = timeMachineMountsCache { return c }
    let p = Process(); let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
    p.arguments = ["destinationinfo"]
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    var mounts = Set<String>()
    if (try? p.run()) != nil {
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        for line in out.split(separator: "\n") where line.hasPrefix("Mount Point") {
            if let r = line.range(of: ": ") { mounts.insert(String(line[r.upperBound...])) }
        }
    }
    timeMachineMountsCache = mounts
    return mounts
}

func externalDrives() -> [Drive] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey]
    let tm = timeMachineMounts()
    let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
    let allowImages = ProcessInfo.processInfo.environment["T7HELPER_ALLOW_DISK_IMAGES"] != nil
    return vols.compactMap { url in
        guard url.path.hasPrefix("/Volumes/"), !tm.contains(url.path),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
        let isInternal = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false
        let model0 = (desc[kDADiskDescriptionDeviceModelKey as String] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if proto == "Disk Image" || proto == "Virtual Interface" || model0 == "Disk Image" {
            if !allowImages { return nil }   // skip mounted .dmg installers
        } else if isInternal { return nil }
        let v = try? url.resourceValues(forKeys: Set(keys))
        let model = (desc[kDADiskDescriptionDeviceModelKey as String] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return Drive(url: url, name: v?.volumeName ?? url.lastPathComponent, uuid: v?.volumeUUIDString ?? url.path, model: model)
    }
}

func looksLikeT7(_ d: Drive) -> Bool { d.model.contains("T7") || d.name.contains("T7") }

/// The drive to use: the one you picked in "Use Drive", else your Samsung T7. Other drives are never used
/// unless you pick them, so e.g. a backup SSD that happens to be plugged in is left alone.
func currentDrive() -> Drive? {
    let drives = externalDrives()
    if let saved = UserDefaults.standard.string(forKey: "driveUUID"), let d = drives.first(where: { $0.uuid == saved }) { return d }
    return drives.first(where: looksLikeT7)
}

// MARK: - Moved-items manifest (stored on the drive itself)

struct Record: Codable { let id: String; let name: String; let originalPath: String; let drivePath: String; let bytes: Int64; let date: Date }

func manifestURL(_ vol: URL) -> URL { vol.appendingPathComponent(offloadFolder).appendingPathComponent(manifestFile) }
func loadRecords(_ vol: URL) -> [Record] {
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: manifestURL(vol)) else { return [] }
    return (try? dec.decode([Record].self, from: data)) ?? []
}
func saveRecords(_ recs: [Record], _ vol: URL) {
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
    try? FileManager.default.createDirectory(at: vol.appendingPathComponent(offloadFolder), withIntermediateDirectories: true)
    try? enc.encode(recs).write(to: manifestURL(vol), options: .atomic)
}

// MARK: - Core operations

let protectedTop: Set<String> = ["Desktop", "Documents", "Downloads", "Library", "Applications", "Movies", "Music", "Pictures", "Public"]

func whyNotMovable(_ path: String, vol: URL) -> String? {
    if path == vol.path || path.hasPrefix(vol.path + "/") { return "it's already on the drive" }
    guard path.hasPrefix(home + "/") else { return "only items inside your home folder can be moved" }
    let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
    guard let top = parts.first else { return "can't move your whole home folder" }
    if parts.count == 1 && protectedTop.contains(top) { return "it's a main Mac folder — move the things inside it instead" }
    if top == "Library" || top.hasPrefix(".") { return "it's app/system data that apps expect to find on the Mac" }
    return nil
}

struct Outcome { var done: [String] = []; var bytes: Int64 = 0; var failed: [(String, String)] = [] }

func moveToDrive(_ paths: [String], vol: URL) -> Outcome {
    var out = Outcome()
    var recs = loadRecords(vol)
    for path in paths {
        let src = URL(fileURLWithPath: path)
        let name = src.lastPathComponent
        if let why = whyNotMovable(path, vol: vol) { out.failed.append((name, why)); continue }
        let size = treeStats(src).bytes
        if size + 200_000_000 > freeSpace(vol) { out.failed.append((name, "not enough space on the drive")); continue }
        let rel = String(path.dropFirst(home.count + 1))
        let dst = uniqueURL(vol.appendingPathComponent(offloadFolder).appendingPathComponent(rel))
        if let err = copyVerified(src, to: dst) { out.failed.append((name, err)); continue }
        do { try FileManager.default.trashItem(at: src, resultingItemURL: nil) }
        catch { out.failed.append((name, "copied, but couldn't move the original to Trash: \(error.localizedDescription)")); continue }
        let drivePath = String(dst.path.dropFirst(vol.path.count + 1))
        recs.append(Record(id: UUID().uuidString, name: name, originalPath: path, drivePath: drivePath, bytes: size, date: Date()))
        saveRecords(recs, vol)
        out.done.append(name); out.bytes += size
    }
    return out
}

func copyToDrive(_ paths: [String], vol: URL) -> Outcome {
    var out = Outcome()
    for path in paths {
        let src = URL(fileURLWithPath: path)
        let name = src.lastPathComponent
        if path == vol.path || path.hasPrefix(vol.path + "/") { out.failed.append((name, "it's already on the drive")); continue }
        let size = treeStats(src).bytes
        if size + 200_000_000 > freeSpace(vol) { out.failed.append((name, "not enough space on the drive")); continue }
        let dst = uniqueURL(vol.appendingPathComponent(copyFolder).appendingPathComponent(name))
        if let err = copyVerified(src, to: dst) { out.failed.append((name, err)); continue }
        out.done.append(name); out.bytes += size
    }
    return out
}

func bringBack(_ rec: Record, vol: URL) -> String? {
    var recs = loadRecords(vol)
    let src = vol.appendingPathComponent(rec.drivePath)
    guard exists(src) else {
        recs.removeAll { $0.id == rec.id }; saveRecords(recs, vol)
        return "it's no longer in \(offloadFolder) on the drive (moved or deleted), so it was removed from the list"
    }
    if rec.bytes + 500_000_000 > freeSpace(URL(fileURLWithPath: home)) { return "not enough free space on your Mac" }
    var dst = URL(fileURLWithPath: rec.originalPath)
    if exists(dst) { dst = uniqueURL(dst, suffix: " (from drive)") }
    if let err = copyVerified(src, to: dst) { return err }
    try? FileManager.default.removeItem(at: src)
    // tidy empty parent folders inside "From Mac"
    var parent = src.deletingLastPathComponent()
    let root = vol.appendingPathComponent(offloadFolder).path
    while parent.path.count > root.count,
          let kids = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
          kids.allSatisfy({ $0 == ".DS_Store" || $0.hasPrefix("._") }) {
        try? FileManager.default.removeItem(at: parent)
        parent = parent.deletingLastPathComponent()
    }
    recs.removeAll { $0.id == rec.id }; saveRecords(recs, vol)
    return nil
}

func syncOne(_ folder: String, vol: URL) -> String? {
    guard FileManager.default.fileExists(atPath: folder) else { return "folder no longer exists" }
    let dst = vol.appendingPathComponent(syncFolder).appendingPathComponent(URL(fileURLWithPath: folder).lastPathComponent)
    try? FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
    let mac = ["apfs", "hfs"].contains(fsType(vol))
    var args = mac ? ["-a"] : ["-rt"]   // exFAT can't store Mac permissions/owners
    for ex in syncExcludes { args += ["--exclude", ex] }
    args += [folder + "/", dst.path + "/"]
    let r = run("/usr/bin/rsync", args)
    if r.status == 0 { return nil }
    if r.status == 23 || r.status == 24 { return "some files were skipped (in use or not supported by the drive)" }
    return "sync failed: \(r.err.split(separator: "\n").first ?? "")"
}

// MARK: - Finder selection

func finderSelection() -> [String] {
    let src = """
    tell application "Finder"
      set out to ""
      repeat with f in (selection as alias list)
        set out to out & POSIX path of f & linefeed
      end repeat
      return out
    end tell
    """
    var err: NSDictionary?
    let res = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue ?? ""
    return res.split(separator: "\n").map { s in
        var p = String(s); if p.count > 1 && p.hasSuffix("/") { p.removeLast() }; return p
    }
}

// MARK: - Global hotkeys (Carbon — needs no special permission)

var hotKeyActions: [UInt32: () -> Void] = [:]
func installHotKeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        DispatchQueue.main.async { hotKeyActions[hk.id]?() }
        return noErr
    }, 1, &spec, nil, nil)
}
func registerHotKey(_ id: UInt32, key: Int, _ action: @escaping () -> Void) {
    hotKeyActions[id] = action
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                        EventHotKeyID(signature: OSType(0x54374850), id: id), GetApplicationEventTarget(), 0, &ref)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let work = DispatchQueue(label: "t7helper.work")
    var busy: String? = nil { didSet { updateStatus() } }
    var syncFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: "syncFolders") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "syncFolders") }
    }
    var autoSync: Bool {
        get { UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoSync") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false
        status.menu = menu
        installHotKeys()
        registerHotKey(1, key: kVK_ANSI_M) { [weak self] in self?.hotkey(move: true) }
        registerHotKey(2, key: kVK_ANSI_C) { [weak self] in self?.hotkey(move: false) }
        registerHotKey(3, key: kVK_ANSI_E) { [weak self] in self?.eject() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didMount(_:)), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        if !UserDefaults.standard.bool(forKey: "loginSetupDone") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginSetupDone")
        }
        updateStatus()
    }

    // MARK: status bar

    func updateStatus() {
        guard let b = status.button else { return }
        let drive = currentDrive()
        let symbol = busy != nil ? "arrow.triangle.2.circlepath" : (drive != nil ? "externaldrive.fill" : "externaldrive")
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "T7 Helper")
        b.image?.isTemplate = true
        b.imagePosition = .imageLeading
        if let busy { b.title = " " + busy }
        else if let d = drive { b.title = " " + fmt(freeSpace(d.url)) }
        else { b.title = "" }
        b.appearsDisabled = drive == nil && busy == nil
    }

    @objc func volumesChanged() { timeMachineMountsCache = nil; updateStatus() }

    @objc func didMount(_ n: Notification) {
        timeMachineMountsCache = nil
        updateStatus()
        guard let d = currentDrive(), let mounted = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              mounted.standardizedFileURL == d.url.standardizedFileURL else { return }
        if autoSync && !syncFolders.isEmpty { syncNow() }
    }

    // MARK: menu

    func menuWillOpen(_ m: NSMenu) { rebuildMenu() }

    func add(_ m: NSMenu, _ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = [],
             enabled: Bool = true, symbol: String? = nil, rep: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self; i.isEnabled = enabled; i.representedObject = rep
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        m.addItem(i)
        return i
    }

    func rebuildMenu() {
        menu.removeAllItems()
        let drive = currentDrive()
        let name = drive?.name ?? "drive"
        let idle = busy == nil

        if let d = drive {
            let free = freeSpace(d.url), total = totalSpace(d.url)
            let used = total > 0 ? Double(total - free) / Double(total) : 0
            let bar = String(repeating: "▓", count: Int(used * 20)) + String(repeating: "░", count: 20 - Int(used * 20))
            _ = add(menu, "\(d.name) — \(fmt(free)) free of \(fmt(total))", nil, enabled: false, symbol: "externaldrive.fill")
            _ = add(menu, "\(bar)  \(Int(used * 100))% used", nil, enabled: false)
            if fsType(d.url) != "apfs" && fsType(d.url) != "hfs" {
                _ = add(menu, "Format: \(fsType(d.url)) (works with Windows/Android too)", nil, enabled: false)
            }
        } else {
            _ = add(menu, "No drive connected — plug in your T7", nil, enabled: false, symbol: "externaldrive")
        }
        if let busy { _ = add(menu, "⏳ \(busy)", nil, enabled: false) }

        menu.addItem(.separator())
        _ = add(menu, "Move Selected to \(name)", #selector(moveSelected), key: "m", mods: [.control, .option],
                enabled: drive != nil && idle, symbol: "arrow.right.doc.on.clipboard")
        _ = add(menu, "Copy Selected to \(name)", #selector(copySelected), key: "c", mods: [.control, .option],
                enabled: drive != nil && idle, symbol: "doc.on.doc")

        // Moved items
        let recs = drive.map { loadRecords($0.url) } ?? []
        let movedItem = add(menu, "Moved to \(name) (\(recs.count))", nil, enabled: drive != nil, symbol: "tray.full")
        let sub = NSMenu(); sub.autoenablesItems = false
        if recs.isEmpty {
            _ = add(sub, "Nothing moved yet — select files in Finder and press ⌃⌥M", nil, enabled: false)
        } else {
            let df = DateFormatter(); df.dateFormat = "d MMM"
            _ = add(sub, "Total: \(fmt(recs.reduce(0) { $0 + $1.bytes }))", nil, enabled: false)
            sub.addItem(.separator())
            for r in recs.sorted(by: { $0.date > $1.date }).prefix(40) {
                let item = NSMenuItem(title: "\(r.name)  ·  \(fmt(r.bytes))  ·  \(df.string(from: r.date))", action: nil, keyEquivalent: "")
                item.toolTip = "Was at: " + r.originalPath.replacingOccurrences(of: home, with: "~")
                let rsub = NSMenu(); rsub.autoenablesItems = false
                _ = add(rsub, "Bring Back to Mac", #selector(bringBackItem(_:)), enabled: idle, symbol: "arrow.uturn.backward", rep: r.id)
                _ = add(rsub, "Show on \(name)", #selector(revealItem(_:)), symbol: "magnifyingglass", rep: r.drivePath)
                _ = add(rsub, "Was at: " + r.originalPath.replacingOccurrences(of: home, with: "~"), nil, enabled: false)
                item.submenu = rsub
                sub.addItem(item)
            }
            sub.addItem(.separator())
            _ = add(sub, "Open “\(offloadFolder)” Folder", #selector(openOffload), symbol: "folder")
        }
        movedItem.submenu = sub

        // Sync folders
        let syncItem = add(menu, "Sync Folders (\(syncFolders.count))", nil, symbol: "arrow.triangle.2.circlepath")
        let ssub = NSMenu(); ssub.autoenablesItems = false
        _ = add(ssub, "Sync Now", #selector(syncNow), enabled: drive != nil && idle && !syncFolders.isEmpty, symbol: "arrow.clockwise")
        let auto = add(ssub, "Auto-sync When Plugged In", #selector(toggleAutoSync))
        auto.state = autoSync ? .on : .off
        ssub.addItem(.separator())
        if syncFolders.isEmpty { _ = add(ssub, "No folders yet", nil, enabled: false) }
        let last = UserDefaults.standard.dictionary(forKey: "lastSync") as? [String: Date] ?? [:]
        let rf = RelativeDateTimeFormatter()
        for f in syncFolders {
            let item = NSMenuItem(title: f.replacingOccurrences(of: home, with: "~"), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let fsub = NSMenu(); fsub.autoenablesItems = false
            _ = add(fsub, "Last synced: " + (last[f].map { rf.localizedString(for: $0, relativeTo: Date()) } ?? "never"), nil, enabled: false)
            _ = add(fsub, "Remove from Sync", #selector(removeSync(_:)), symbol: "minus.circle", rep: f)
            item.submenu = fsub
            ssub.addItem(item)
        }
        ssub.addItem(.separator())
        _ = add(ssub, "Add Folder…", #selector(addSync), symbol: "plus.circle")
        _ = add(ssub, "Skips: node_modules, build, Pods, .gradle, DerivedData…", nil, enabled: false)
        syncItem.submenu = ssub

        menu.addItem(.separator())
        _ = add(menu, "Open \(name) in Finder", #selector(openDrive), enabled: drive != nil, symbol: "folder")
        _ = add(menu, "Eject \(name)", #selector(eject), key: "e", mods: [.control, .option], enabled: drive != nil && idle, symbol: "eject")

        let drives = externalDrives()
        if !drives.isEmpty && (drives.count > 1 || drive == nil) {
            let pick = add(menu, "Use a Different Drive", nil, symbol: "externaldrive.badge.checkmark")
            let psub = NSMenu()
            let auto = add(psub, "Samsung T7 (default)", #selector(pickDrive(_:)), rep: nil)
            auto.state = UserDefaults.standard.string(forKey: "driveUUID") == nil ? .on : .off
            psub.addItem(.separator())
            for d in drives {
                let i = add(psub, "\(d.name)  (\(d.model.isEmpty ? "external" : d.model))", #selector(pickDrive(_:)), rep: d.uuid)
                i.state = d.uuid == UserDefaults.standard.string(forKey: "driveUUID") ? .on : .off
            }
            _ = add(psub, "Time Machine disks are never shown here", nil, enabled: false)
            pick.submenu = psub
        }

        menu.addItem(.separator())
        let login = add(menu, "Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = add(menu, "Quit T7 Helper", #selector(NSApplication.terminate(_:)), key: "q")
        menu.items.last?.target = NSApp
    }

    // MARK: actions

    func alert(_ title: String, _ text: String = "") {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    func report(_ verb: String, _ o: Outcome, drive: String, extra: String = "") {
        var lines: [String] = []
        if !o.done.isEmpty { lines.append("✅ \(o.done.joined(separator: ", "))") }
        for (n, why) in o.failed { lines.append("⚠️ \(n): \(why)") }
        if !o.done.isEmpty && !extra.isEmpty { lines.append("\n" + extra) }
        let title = o.done.isEmpty ? "Nothing was \(verb.lowercased())" : "\(verb) \(o.done.count) item\(o.done.count == 1 ? "" : "s") (\(fmt(o.bytes))) to \(drive)"
        alert(title, lines.joined(separator: "\n"))
    }

    func hotkey(move: Bool) {
        // Only act when you're in Finder, so a stray shortcut never moves anything unexpected.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { NSSound.beep(); return }
        move ? moveSelected() : copySelected()
    }

    @objc func moveSelected() { transfer(move: true) }
    @objc func copySelected() { transfer(move: false) }

    func transfer(move: Bool) {
        guard busy == nil else { NSSound.beep(); return }
        guard let d = currentDrive() else { alert("Plug in your T7 first"); return }
        let paths = finderSelection()
        guard !paths.isEmpty else { alert("Select some files or folders in Finder first", "Then press \(move ? "⌃⌥M" : "⌃⌥C") again."); return }
        busy = "Measuring…"
        work.async {
            let size = paths.reduce(Int64(0)) { $0 + treeStats(URL(fileURLWithPath: $1)).bytes }
            DispatchQueue.main.async {
                self.busy = nil
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                let what = paths.count == 1 ? "“\(URL(fileURLWithPath: paths[0]).lastPathComponent)”" : "\(paths.count) items"
                a.messageText = "\(move ? "Move" : "Copy") \(what) (\(fmt(size))) to \(d.name)?"
                a.informativeText = move
                    ? "They're copied to \(d.name) › \(offloadFolder), every file is checked, and only then do the originals go to the Trash.\n\nBring them back anytime from the menu → Moved to \(d.name)."
                    : "Copies go to \(d.name) › \(copyFolder). Your originals stay where they are."
                a.addButton(withTitle: move ? "Move" : "Copy"); a.addButton(withTitle: "Cancel")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                self.busy = move ? "Moving…" : "Copying…"
                self.work.async {
                    let o = move ? moveToDrive(paths, vol: d.url) : copyToDrive(paths, vol: d.url)
                    DispatchQueue.main.async {
                        self.busy = nil
                        self.report(move ? "Moved" : "Copied", o, drive: d.name,
                                    extra: move ? "The originals are in your Trash. Empty the Trash to free up the space on your Mac." : "")
                    }
                }
            }
        }
    }

    @objc func bringBackItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let d = currentDrive(),
              let rec = loadRecords(d.url).first(where: { $0.id == id }) else { return }
        busy = "Bringing back…"
        work.async {
            let err = bringBack(rec, vol: d.url)
            DispatchQueue.main.async {
                self.busy = nil
                if let err { self.alert("Couldn't bring back “\(rec.name)”", err) }
                else {
                    self.alert("“\(rec.name)” is back on your Mac", rec.originalPath.replacingOccurrences(of: home, with: "~"))
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.originalPath)])
                }
            }
        }
    }

    @objc func revealItem(_ sender: NSMenuItem) {
        guard let rel = sender.representedObject as? String, let d = currentDrive() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([d.url.appendingPathComponent(rel)])
    }
    @objc func openOffload() {
        guard let d = currentDrive() else { return }
        NSWorkspace.shared.open(d.url.appendingPathComponent(offloadFolder))
    }
    @objc func openDrive() { if let d = currentDrive() { NSWorkspace.shared.open(d.url) } }

    @objc func eject() {
        guard let d = currentDrive() else { return }
        busy = "Ejecting…"
        work.async {
            var err: Error?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: d.url) } catch { err = error }
            DispatchQueue.main.async {
                self.busy = nil
                if err != nil { self.alert("\(d.name) is still in use", "Close any files or apps using it (Finder previews, Terminal windows in it, etc.), then try again.") }
                else { self.alert("✅ Safe to unplug \(d.name)") }
            }
        }
    }

    @objc func syncNow() {
        guard busy == nil, let d = currentDrive() else { return }
        let folders = syncFolders
        guard !folders.isEmpty else { return }
        busy = "Syncing…"
        work.async {
            var problems: [String] = []
            var last = UserDefaults.standard.dictionary(forKey: "lastSync") as? [String: Date] ?? [:]
            for f in folders {
                let err = syncOne(f, vol: d.url)
                if let err { problems.append("⚠️ \(URL(fileURLWithPath: f).lastPathComponent): \(err)") }
                let hardFailure = err.map { $0.hasPrefix("sync failed") || $0 == "folder no longer exists" } ?? false
                if !hardFailure { last[f] = Date() }
            }
            UserDefaults.standard.set(last, forKey: "lastSync")
            DispatchQueue.main.async {
                self.busy = nil
                if !problems.isEmpty { self.alert("Sync finished with problems", problems.joined(separator: "\n")) }
            }
        }
    }

    @objc func toggleAutoSync() { autoSync.toggle() }

    @objc func addSync() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.prompt = "Sync to Drive"
        p.message = "Choose folders to copy to your drive automatically each time you plug it in."
        guard p.runModal() == .OK else { return }
        var list = syncFolders
        for u in p.urls where !list.contains(u.path) { list.append(u.path) }
        syncFolders = list
    }
    @objc func removeSync(_ sender: NSMenuItem) {
        guard let f = sender.representedObject as? String else { return }
        syncFolders = syncFolders.filter { $0 != f }
    }

    @objc func pickDrive(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "driveUUID")
        updateStatus()
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    }
}

// MARK: - CLI (for testing): T7Helper --cli <list|move|copy|records|restore|sync> <volume> [paths…]

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--cli" {
    let a = Array(CommandLine.arguments.dropFirst(2))
    let vol = a.count > 1 ? URL(fileURLWithPath: a[1]) : URL(fileURLWithPath: "/")
    let rest = Array(a.dropFirst(2))
    switch a.first ?? "" {
    case "list": externalDrives().forEach { print("\($0.name)\t\($0.model)\t\($0.url.path)\t\(fsType($0.url))") }
    case "move": let o = moveToDrive(rest, vol: vol); print("done:", o.done, "bytes:", o.bytes, "failed:", o.failed)
    case "copy": let o = copyToDrive(rest, vol: vol); print("done:", o.done, "bytes:", o.bytes, "failed:", o.failed)
    case "records": loadRecords(vol).forEach { print("\($0.id)\t\($0.name)\t\($0.originalPath)\t\($0.drivePath)\t\($0.bytes)") }
    case "restore": for r in loadRecords(vol) where rest.contains(r.id) || rest.contains(r.name) { print(r.name, bringBack(r, vol: vol) ?? "ok") }
    case "sync": for f in rest { print(f, syncOne(f, vol: vol) ?? "ok") }
    default: print("unknown command")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
