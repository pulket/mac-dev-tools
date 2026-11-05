// Drive section of Command Center — your Samsung T7 (or any external SSD).
// Move (verified) / copy / bring back, Free Up Space, sync folders, find, speed test, safe sleep.

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
/// Home folder used for moves (overridable for tests).
let driveHome = ProcessInfo.processInfo.environment["T7HELPER_HOME"] ?? NSHomeDirectory()

// MARK: - Helpers


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
/// Copies with ditto (reporting bytes copied so far), then verifies file count + bytes match.
/// Removes the partial copy on failure.
func copyVerified(_ src: URL, to dst: URL, progress: ((Int64) -> Void)? = nil) -> String? {
    try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    let p = Process(); let errPipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = [src.path, dst.path]
    p.standardOutput = FileHandle.nullDevice; p.standardError = errPipe
    do { try p.run() } catch { return "copy failed: \(error.localizedDescription)" }
    var errData = Data()
    let reader = DispatchGroup(); reader.enter()
    DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
    while p.isRunning {
        usleep(700_000)
        if let progress, p.isRunning { progress(treeStats(dst).bytes) }
    }
    reader.wait()
    let err = String(data: errData, encoding: .utf8) ?? ""
    if p.terminationStatus != 0 {
        try? FileManager.default.removeItem(at: dst)
        let hint = err.contains("not supported") ? " (this drive's format can't store some items, like shortcuts/symlinks)" : ""
        return "copy failed\(hint): \(err.split(separator: "\n").first ?? "")"
    }
    let a = treeStats(src), b = treeStats(dst)
    if a != b {
        try? FileManager.default.removeItem(at: dst)
        return "check failed — \(b.files) of \(a.files) files arrived (this drive's format may not support some items, like shortcuts/symlinks)"
    }
    progress?(a.bytes)
    return nil
}

/// A Finder alias at `aliasURL` that opens `target` (works whenever the drive is plugged in).
func makeAlias(to target: URL, at aliasURL: URL) -> Bool {
    guard let data = try? target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
    else { return false }
    return (try? URL.writeBookmarkData(data, to: aliasURL)) != nil
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

struct Record: Codable {
    let id: String; let name: String; let originalPath: String; let drivePath: String; let bytes: Int64; let date: Date
    var batch: String? = nil      // items moved together (e.g. "Old Downloads") are listed + restored as one
    var aliasPath: String? = nil  // alias left at the original location, removed on Bring Back
}

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
    guard path.hasPrefix(driveHome + "/") else { return "only items inside your driveHome folder can be moved" }
    let parts = path.dropFirst(driveHome.count + 1).split(separator: "/").map(String.init)
    guard let top = parts.first else { return "can't move your whole driveHome folder" }
    if parts.count == 1 && protectedTop.contains(top) { return "it's a main Mac folder — move the things inside it instead" }
    if top == "Library" || top.hasPrefix(".") { return "it's app/system data that apps expect to find on the Mac" }
    return nil
}

struct Outcome { var done: [String] = []; var bytes: Int64 = 0; var failed: [(String, String)] = []; var trashed: [URL] = [] }

func moveToDrive(_ paths: [String], vol: URL, leaveAliases: Bool = false, batch: String? = nil,
                 progress: ((Int64) -> Void)? = nil) -> Outcome {
    var out = Outcome()
    var recs = loadRecords(vol)
    let volName = vol.lastPathComponent
    for path in paths {
        let src = URL(fileURLWithPath: path)
        let name = src.lastPathComponent
        if let why = whyNotMovable(path, vol: vol) { out.failed.append((name, why)); continue }
        let size = treeStats(src).bytes
        if size + 200_000_000 > freeSpace(vol) { out.failed.append((name, "not enough space on the drive")); continue }
        let rel = String(path.dropFirst(driveHome.count + 1))
        let dst = uniqueURL(vol.appendingPathComponent(offloadFolder).appendingPathComponent(rel))
        let base = out.bytes
        if let err = copyVerified(src, to: dst, progress: { progress?(base + $0) }) { out.failed.append((name, err)); continue }
        var trashedURL: NSURL?
        do { try FileManager.default.trashItem(at: src, resultingItemURL: &trashedURL) }
        catch { out.failed.append((name, "copied, but couldn't move the original to Trash: \(error.localizedDescription)")); continue }
        if let t = trashedURL as URL? { out.trashed.append(t) }
        var rec = Record(id: UUID().uuidString, name: name, originalPath: path,
                         drivePath: String(dst.path.dropFirst(vol.path.count + 1)), bytes: size, date: Date())
        rec.batch = batch
        if leaveAliases {
            let aliasURL = uniqueURL(src.deletingLastPathComponent().appendingPathComponent("\(name) (on \(volName))"))
            if makeAlias(to: dst, at: aliasURL) { rec.aliasPath = aliasURL.path }
        }
        recs.append(rec)
        saveRecords(recs, vol)
        out.done.append(name); out.bytes += size
    }
    return out
}

func copyToDrive(_ paths: [String], vol: URL, progress: ((Int64) -> Void)? = nil) -> Outcome {
    var out = Outcome()
    for path in paths {
        let src = URL(fileURLWithPath: path)
        let name = src.lastPathComponent
        if path == vol.path || path.hasPrefix(vol.path + "/") { out.failed.append((name, "it's already on the drive")); continue }
        let size = treeStats(src).bytes
        if size + 200_000_000 > freeSpace(vol) { out.failed.append((name, "not enough space on the drive")); continue }
        let dst = uniqueURL(vol.appendingPathComponent(copyFolder).appendingPathComponent(name))
        let base = out.bytes
        if let err = copyVerified(src, to: dst, progress: { progress?(base + $0) }) { out.failed.append((name, err)); continue }
        out.done.append(name); out.bytes += size
    }
    return out
}

/// Copies items into "Copied from Mac" — or refreshes an earlier copy of the same item — skipping rebuildable
/// folders (node_modules, build, Pods…). Used by the double-tap Quick Copy.
func quickCopyToDrive(_ paths: [String], vol: URL) -> Outcome {
    var out = Outcome()
    let root = vol.appendingPathComponent(copyFolder)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let macFS = ["apfs", "hfs"].contains(fsType(vol))
    for path in paths {
        let src = URL(fileURLWithPath: path)
        let name = src.lastPathComponent
        if path == vol.path || path.hasPrefix(vol.path + "/") { out.failed.append((name, "it's already on the drive")); continue }
        let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let dst = root.appendingPathComponent(name)
        var args = macFS ? ["-a"] : ["-rt"]          // exFAT can't store Mac permissions/owners
        if isDir {
            for ex in syncExcludes { args += ["--exclude", ex] }
            try? FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            args += [path + "/", dst.path + "/"]
        } else {
            args += [path, dst.path]
        }
        let r = run("/usr/bin/rsync", args)
        if r.status == 0 || r.status == 24 {       // 24 = a file vanished mid-copy (harmless)
            out.done.append(name); out.bytes += treeStats(dst).bytes
        } else if r.err.lowercased().contains("no space") {
            out.failed.append((name, "the drive is full"))
        } else {
            out.failed.append((name, "copy failed: \(r.err.split(separator: "\n").first ?? "")"))
        }
    }
    return out
}

func bringBack(_ rec: Record, vol: URL, progress: ((Int64) -> Void)? = nil) -> String? {
    var recs = loadRecords(vol)
    let src = vol.appendingPathComponent(rec.drivePath)
    guard exists(src) else {
        recs.removeAll { $0.id == rec.id }; saveRecords(recs, vol)
        return "it's no longer in \(offloadFolder) on the drive (moved or deleted), so it was removed from the list"
    }
    if rec.bytes + 500_000_000 > freeSpace(URL(fileURLWithPath: driveHome)) { return "not enough free space on your Mac" }
    var dst = URL(fileURLWithPath: rec.originalPath)
    if exists(dst) { dst = uniqueURL(dst, suffix: " (from drive)") }
    if let err = copyVerified(src, to: dst, progress: progress) { return err }
    try? FileManager.default.removeItem(at: src)
    if let a = rec.aliasPath, (try? URL(fileURLWithPath: a).resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true {
        try? FileManager.default.removeItem(atPath: a)
    }
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

// MARK: - Free Up Space scanner

struct Candidate {
    let title: String; let detail: String; let paths: [String]; let bytes: Int64; let lastUsed: Date; let batch: String?
}

let scanRoots = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Flutter applications"]
let oldAfterDays = 60.0
let bigItemBytes: Int64 = 50_000_000

func spotlightLastUsed(_ url: URL) -> Date? {
    guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
    return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
}

/// Size + the newest modification date anywhere inside (so an active project never looks "old").
func sizeAndNewest(_ url: URL) -> (Int64, Date) {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
    let v = try? url.resourceValues(forKeys: keys)
    var newest = v?.contentModificationDate ?? .distantPast
    if v?.isDirectory != true { return (Int64(v?.fileSize ?? 0), newest) }
    var bytes: Int64 = 0
    let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [])
    while let u = e?.nextObject() as? URL {
        guard let r = try? u.resourceValues(forKeys: keys), r.isSymbolicLink != true else { continue }
        if let m = r.contentModificationDate, m > newest { newest = m }
        if r.isDirectory != true { bytes += Int64(r.fileSize ?? 0) }
    }
    return (bytes, newest)
}

func scanCandidates(vol: URL) -> [Candidate] {
    let fm = FileManager.default
    let cutoff = Date().addingTimeInterval(-oldAfterDays * 86400)
    var out: [Candidate] = []
    var oldDownloads: [(String, Int64)] = []
    for root in scanRoots {
        let dir = URL(fileURLWithPath: driveHome).appendingPathComponent(root)
        guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
        for k in kids {
            if k.pathExtension == "photoslibrary" || whyNotMovable(k.path, vol: vol) != nil { continue }
            if (try? k.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true { continue }
            let (bytes, newestMod) = sizeAndNewest(k)
            let lastUsed = max(newestMod, spotlightLastUsed(k) ?? .distantPast)
            guard lastUsed < cutoff else { continue }
            let isDir = (try? k.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if bytes >= bigItemBytes {
                out.append(Candidate(title: "\(isDir ? "📁" : "📄") \(k.lastPathComponent)", detail: "~/\(root)",
                                     paths: [k.path], bytes: bytes, lastUsed: lastUsed, batch: nil))
            } else if root == "Downloads" && !isDir {
                oldDownloads.append((k.path, bytes))
            }
        }
    }
    let odBytes = oldDownloads.reduce(Int64(0)) { $0 + $1.1 }
    if oldDownloads.count >= 5 && odBytes >= 10_000_000 {
        out.append(Candidate(title: "🗂 Old Downloads (\(oldDownloads.count) small files)", detail: "~/Downloads · untouched 60+ days",
                             paths: oldDownloads.map { $0.0 }, bytes: odBytes, lastUsed: cutoff, batch: "Old Downloads"))
    }
    return out.sorted { $0.bytes > $1.bytes }
}

// MARK: - Drive tools

func bsdName(of vol: URL) -> String? {
    guard let s = DASessionCreate(kCFAllocatorDefault),
          let d = DADiskCreateFromVolumePath(kCFAllocatorDefault, s, vol as CFURL),
          let n = DADiskGetBSDName(d) else { return nil }
    return String(cString: n)
}

/// Writes then reads 1 GB without caching. Returns MB/s.
func speedTest(vol: URL) -> (write: Double, read: Double)? {
    let path = vol.appendingPathComponent(".t7helper-speedtest").path
    let total = 1 << 30, chunk = 8 << 20
    var buf = [UInt8](repeating: 0, count: chunk)
    for i in stride(from: 0, to: chunk, by: 4096) { buf[i] = UInt8.random(in: 0...255) }
    defer { unlink(path) }
    var fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
    guard fd >= 0 else { return nil }
    _ = fcntl(fd, F_NOCACHE, 1)
    var t = Date()
    var written = 0
    while written < total { let n = buf.withUnsafeBytes { write(fd, $0.baseAddress, chunk) }; if n <= 0 { close(fd); return nil }; written += n }
    _ = fcntl(fd, F_FULLFSYNC)
    close(fd)
    let w = Double(total) / 1_000_000 / Date().timeIntervalSince(t)
    fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    _ = fcntl(fd, F_NOCACHE, 1)
    t = Date()
    var readBytes = 0
    while readBytes < total { let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }; if n <= 0 { break }; readBytes += n }
    close(fd)
    let r = Double(readBytes) / 1_000_000 / Date().timeIntervalSince(t)
    return (w, r)
}

/// Finds files/folders on the drive whose name contains `query` (Spotlight first, then a direct search).
func searchDrive(_ query: String, vol: URL, limit: Int = 40) -> [URL] {
    let spot = run2("/usr/bin/mdfind", ["-onlyin", vol.path, "-name", query])
    var results = spot.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    if results.isEmpty {
        let found = run2("/usr/bin/find", [vol.path, "-iname", "*\(query)*", "-not", "-path", "*/.*"])
        results = found.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
    return Array(results.filter { !$0.lastPathComponent.hasPrefix("._") && $0.lastPathComponent != manifestFile }.prefix(limit))
}

/// Runs a tool and returns its stdout.
func run2(_ exe: String, _ args: [String]) -> String {
    let p = Process(); let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return out
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

// MARK: - App

final class DriveSection: NSObject {
    weak var hub: Hub?
    let work = DispatchQueue(label: "t7helper.work")
    var busy: String? = nil { didSet { updateStatus() } }
    var unmountedForSleep: String?
    let macLowBytes: Int64 = 15_000_000_000

    func pref(_ key: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? def }
    var syncFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: "syncFolders") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "syncFolders") }
    }
    var autoSync: Bool { get { pref("autoSync", true) } set { UserDefaults.standard.set(newValue, forKey: "autoSync") } }
    var leaveAliases: Bool { get { pref("leaveAliases", true) } set { UserDefaults.standard.set(newValue, forKey: "leaveAliases") } }
    var sleepUnmount: Bool { get { pref("sleepUnmount", true) } set { UserDefaults.standard.set(newValue, forKey: "sleepUnmount") } }

    func start() {
        registerHotKey(1, key: kVK_ANSI_M) { [weak self] in self?.hotkey(move: true) }
        registerHotKey(2, key: kVK_ANSI_C) { [weak self] in self?.hotkey(move: false) }
        registerHotKey(3, key: kVK_ANSI_E) { [weak self] in self?.eject() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didMount(_:)), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        nc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        // Quick Copy request from ClaudeHere (double-tap Right ⇧ in Finder)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(quickCopyRequested),
                                                            name: Notification.Name("com.local.t7helper.quickCopy"), object: nil)
    }

    // MARK: status bar

    var macFree: Int64 { freeSpace(URL(fileURLWithPath: driveHome)) }

    func updateStatus() { hub?.updateStatus() }

    /// Text shown next to the menu-bar icon: progress while busy, else the drive's free space (+ Mac low-space warning).
    func titleText() -> String {
        var title = ""
        if let busy { title = busy }
        else if let d = currentDrive() { title = fmt(freeSpace(d.url)) }
        if busy == nil && macFree < macLowBytes { title += (title.isEmpty ? "" : "  ") + "⚠︎ Mac \(fmt(macFree))" }
        return title
    }

    func setProgress(_ verb: String, _ done: Int64, _ total: Int64) {
        let pct = total > 0 ? min(99, Int(Double(done) / Double(total) * 100)) : 0
        DispatchQueue.main.async { self.busy = "\(verb) \(pct)% · \(fmt(done)) of \(fmt(total))" }
    }

    @objc func volumesChanged() { timeMachineMountsCache = nil; updateStatus() }

    @objc func didMount(_ n: Notification) {
        timeMachineMountsCache = nil
        updateStatus()
        guard let d = currentDrive(), let mounted = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              mounted.standardizedFileURL == d.url.standardizedFileURL else { return }
        if autoSync && !syncFolders.isEmpty { syncNow() }
    }

    // Unmount before sleep so unplugging a sleeping Mac never corrupts the drive; remount on wake.
    @objc func willSleep() {
        guard sleepUnmount, busy == nil, let d = currentDrive(), let bsd = bsdName(of: d.url) else { return }
        if run("/usr/sbin/diskutil", ["unmount", d.url.path]).status == 0 { unmountedForSleep = bsd }
    }
    @objc func didWake() {
        guard let bsd = unmountedForSleep else { return }
        unmountedForSleep = nil
        work.asyncAfter(deadline: .now() + 2) { run("/usr/sbin/diskutil", ["mount", bsd]) }  // fails quietly if it was unplugged
    }

    // MARK: drag & drop onto the icon

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (currentDrive() != nil && busy == nil) ? .copy : []
    }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.transfer(paths: urls.map { $0.path }, move: nil) }
        return true
    }

    // MARK: menu

    @discardableResult
    func add(_ m: NSMenu, _ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = [],
             enabled: Bool = true, symbol: String? = nil, rep: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self; i.isEnabled = enabled; i.representedObject = rep
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        m.addItem(i)
        return i
    }

    func bar(_ used: Double) -> String {
        let n = max(0, min(20, Int(used * 20)))
        return String(repeating: "▓", count: n) + String(repeating: "░", count: 20 - n)
    }

    /// Title for this section's row in the main menu.
    func rowTitle() -> String {
        if let d = currentDrive() { return "\(d.name) — \(fmt(freeSpace(d.url))) free" }
        return "T7 — not connected"
    }

    func buildMenu(_ menu: NSMenu) {
        let drive = currentDrive()
        let name = drive?.name ?? "drive"
        let idle = busy == nil

        if let d = drive {
            let free = freeSpace(d.url), total = totalSpace(d.url)
            let used = total > 0 ? Double(total - free) / Double(total) : 0
            add(menu, "\(d.name) — \(fmt(free)) free of \(fmt(total))", nil, enabled: false, symbol: "externaldrive.fill")
            add(menu, "\(bar(used))  \(Int(used * 100))% used", nil, enabled: false)
            if fsType(d.url) != "apfs" && fsType(d.url) != "hfs" {
                add(menu, "Format: \(fsType(d.url)) (works with Windows/Android too)", nil, enabled: false)
            }
        } else {
            add(menu, "No drive connected — plug in your T7", nil, enabled: false, symbol: "externaldrive")
        }
        let mFree = macFree
        let mTotal = totalSpace(URL(fileURLWithPath: "/"))
        add(menu, "This Mac — \(fmt(mFree)) free\(mFree < macLowBytes ? "  ⚠︎ running low" : "")", nil, enabled: false, symbol: "laptopcomputer")
        if mTotal > 0 { add(menu, "\(bar(Double(mTotal - mFree) / Double(mTotal)))  \(Int(Double(mTotal - mFree) / Double(mTotal) * 100))% used", nil, enabled: false) }
        if let busy { add(menu, "⏳ \(busy)", nil, enabled: false) }

        menu.addItem(.separator())
        add(menu, "Free Up Space on Mac…", #selector(freeUpSpace), enabled: drive != nil && idle, symbol: "sparkles")
        add(menu, "Move Selected to \(name)", #selector(moveSelected), key: "m", mods: [.control, .option],
            enabled: drive != nil && idle, symbol: "arrow.right.doc.on.clipboard")
        add(menu, "Copy Selected to \(name)", #selector(copySelected), key: "c", mods: [.control, .option],
            enabled: drive != nil && idle, symbol: "doc.on.doc")
        add(menu, "Tip: drag files onto the menu-bar icon", nil, enabled: false)
        add(menu, "Quick Copy: double-tap Right ⇧ in Finder", nil, enabled: false)
        add(menu, "Find on \(name)…", #selector(findOnDrive), enabled: drive != nil, symbol: "magnifyingglass")

        // Moved items (batches shown as one entry)
        let recs = drive.map { loadRecords($0.url) } ?? []
        let movedItem = add(menu, "Moved to \(name) (\(recs.count))", nil, enabled: drive != nil, symbol: "tray.full")
        let sub = NSMenu(); sub.autoenablesItems = false
        if recs.isEmpty {
            add(sub, "Nothing moved yet — select files in Finder and press ⌃⌥M", nil, enabled: false)
        } else {
            let df = DateFormatter(); df.dateFormat = "d MMM"
            add(sub, "Total: \(fmt(recs.reduce(0) { $0 + $1.bytes }))", nil, enabled: false)
            sub.addItem(.separator())
            var shownBatches = Set<String>()
            for r in recs.sorted(by: { $0.date > $1.date }) {
                if sub.items.count > 45 { break }
                let item: NSMenuItem
                let rsub = NSMenu(); rsub.autoenablesItems = false
                if let b = r.batch {
                    let key = b + df.string(from: r.date)
                    if shownBatches.contains(key) { continue }
                    shownBatches.insert(key)
                    let group = recs.filter { $0.batch == b && df.string(from: $0.date) == df.string(from: r.date) }
                    item = NSMenuItem(title: "\(b) (\(group.count) items)  ·  \(fmt(group.reduce(0) { $0 + $1.bytes }))  ·  \(df.string(from: r.date))", action: nil, keyEquivalent: "")
                    add(rsub, "Bring All Back to Mac", #selector(bringBackBatch(_:)), enabled: idle, symbol: "arrow.uturn.backward", rep: group.map { $0.id })
                    add(rsub, "Show on \(name)", #selector(revealItem(_:)), symbol: "magnifyingglass",
                        rep: (r.drivePath as NSString).deletingLastPathComponent)
                } else {
                    item = NSMenuItem(title: "\(r.name)  ·  \(fmt(r.bytes))  ·  \(df.string(from: r.date))", action: nil, keyEquivalent: "")
                    add(rsub, "Bring Back to Mac", #selector(bringBackItem(_:)), enabled: idle, symbol: "arrow.uturn.backward", rep: r.id)
                    add(rsub, "Show on \(name)", #selector(revealItem(_:)), symbol: "magnifyingglass", rep: r.drivePath)
                    add(rsub, "Was at: " + tildePath(r.originalPath), nil, enabled: false)
                }
                item.submenu = rsub
                sub.addItem(item)
            }
            sub.addItem(.separator())
            add(sub, "Open “\(offloadFolder)” Folder", #selector(openOffload), symbol: "folder")
        }
        movedItem.submenu = sub

        // Sync folders
        let syncItem = add(menu, "Sync Folders (\(syncFolders.count))", nil, symbol: "arrow.triangle.2.circlepath")
        let ssub = NSMenu(); ssub.autoenablesItems = false
        add(ssub, "Sync Now", #selector(syncNow), enabled: drive != nil && idle && !syncFolders.isEmpty, symbol: "arrow.clockwise")
        add(ssub, "Auto-sync When Plugged In", #selector(toggleAutoSync)).state = autoSync ? .on : .off
        ssub.addItem(.separator())
        if syncFolders.isEmpty { add(ssub, "No folders yet", nil, enabled: false) }
        let last = UserDefaults.standard.dictionary(forKey: "lastSync") as? [String: Date] ?? [:]
        let rf = RelativeDateTimeFormatter()
        for f in syncFolders {
            let item = NSMenuItem(title: tildePath(f), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let fsub = NSMenu(); fsub.autoenablesItems = false
            add(fsub, "Last synced: " + (last[f].map { rf.localizedString(for: $0, relativeTo: Date()) } ?? "never"), nil, enabled: false)
            add(fsub, "Remove from Sync", #selector(removeSync(_:)), symbol: "minus.circle", rep: f)
            item.submenu = fsub
            ssub.addItem(item)
        }
        ssub.addItem(.separator())
        add(ssub, "Add Folder…", #selector(addSync), symbol: "plus.circle")
        add(ssub, "Skips: node_modules, build, Pods, .gradle, DerivedData…", nil, enabled: false)
        syncItem.submenu = ssub

        menu.addItem(.separator())
        add(menu, "Open \(name) in Finder", #selector(openDrive), enabled: drive != nil, symbol: "folder")
        add(menu, "Open “\(copyFolder)” Folder", #selector(openCopies), enabled: drive != nil, symbol: "doc.on.doc")
        add(menu, "Speed Test", #selector(runSpeedTest), enabled: drive != nil && idle, symbol: "gauge.with.dots.needle.67percent")
        add(menu, "Eject \(name)", #selector(eject), key: "e", mods: [.control, .option], enabled: drive != nil && idle, symbol: "eject")

        let drives = externalDrives()
        if !drives.isEmpty && (drives.count > 1 || drive == nil) {
            let pick = add(menu, "Use a Different Drive", nil, symbol: "externaldrive.badge.checkmark")
            let psub = NSMenu()
            add(psub, "Samsung T7 (default)", #selector(pickDrive(_:)), rep: nil).state = UserDefaults.standard.string(forKey: "driveUUID") == nil ? .on : .off
            psub.addItem(.separator())
            for d in drives {
                add(psub, "\(d.name)  (\(d.model.isEmpty ? "external" : d.model))", #selector(pickDrive(_:)), rep: d.uuid)
                    .state = d.uuid == UserDefaults.standard.string(forKey: "driveUUID") ? .on : .off
            }
            add(psub, "Time Machine disks are never shown here", nil, enabled: false)
            pick.submenu = psub
        }

        menu.addItem(.separator())
        let settings = add(menu, "Settings", nil, symbol: "gearshape")
        let st = NSMenu(); st.autoenablesItems = false
        add(st, "Leave an Alias Where Moved Items Were", #selector(toggleAliases)).state = leaveAliases ? .on : .off
        add(st, "Unmount Drive When Mac Sleeps", #selector(toggleSleepUnmount)).state = sleepUnmount ? .on : .off
        settings.submenu = st
    }

    func tildePath(_ p: String) -> String { p.hasPrefix(driveHome) ? "~" + p.dropFirst(driveHome.count) : p }

    // MARK: alerts

    @discardableResult
    func alert(_ title: String, _ text: String = "", buttons: [String] = ["OK"], accessory: NSView? = nil) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        buttons.forEach { a.addButton(withTitle: $0) }
        a.accessoryView = accessory
        return a.runModal()
    }

    func report(_ verb: String, _ o: Outcome, drive: String) {
        var lines: [String] = []
        if !o.done.isEmpty {
            let names = o.done.prefix(8).joined(separator: ", ") + (o.done.count > 8 ? " +\(o.done.count - 8) more" : "")
            lines.append("✅ \(names)")
        }
        for (n, why) in o.failed.prefix(8) { lines.append("⚠️ \(n): \(why)") }
        let title = o.done.isEmpty ? "Nothing was \(verb.lowercased())" : "\(verb) \(o.done.count) item\(o.done.count == 1 ? "" : "s") (\(fmt(o.bytes))) to \(drive)"
        if !o.trashed.isEmpty {
            lines.append("\nThe originals are in the Trash. Free the space now? (Only these items are deleted — the rest of your Trash is untouched, and the copies on \(drive) are verified.)")
            if alert(title, lines.joined(separator: "\n"), buttons: ["Free \(fmt(o.bytes)) Now", "Keep in Trash"]) == .alertFirstButtonReturn {
                o.trashed.forEach { try? FileManager.default.removeItem(at: $0) }
                updateStatus()
            }
        } else {
            alert(title, lines.joined(separator: "\n"))
        }
    }

    // MARK: move / copy

    func hotkey(move: Bool) {
        // Only act when you're in Finder, so a stray shortcut never moves anything unexpected.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { NSSound.beep(); return }
        move ? moveSelected() : copySelected()
    }

    @objc func moveSelected() { transferSelection(move: true) }
    @objc func copySelected() { transferSelection(move: false) }

    func transferSelection(move: Bool) {
        let paths = finderSelection()
        guard !paths.isEmpty else { alert("Select some files or folders in Finder first", "Then press \(move ? "⌃⌥M" : "⌃⌥C") again — or drag them onto the menu-bar icon."); return }
        transfer(paths: paths, move: move)
    }

    /// move == nil → ask Move or Copy (used for drag & drop).
    func transfer(paths: [String], move: Bool?) {
        guard busy == nil else { NSSound.beep(); return }
        guard let d = currentDrive() else { alert("Plug in your T7 first"); return }
        busy = "Measuring…"
        work.async {
            let size = paths.reduce(Int64(0)) { $0 + treeStats(URL(fileURLWithPath: $1)).bytes }
            DispatchQueue.main.async {
                self.busy = nil
                let what = paths.count == 1 ? "“\(URL(fileURLWithPath: paths[0]).lastPathComponent)”" : "\(paths.count) items"
                let moveInfo = "Move: copied to \(d.name) › \(offloadFolder), every file checked, then the originals go to the Trash\(self.leaveAliases ? " and an alias is left in their place" : "")."
                let copyInfo = "Copy: goes to \(d.name) › \(copyFolder), originals stay."
                var doMove: Bool
                if let move {
                    let r = self.alert("\(move ? "Move" : "Copy") \(what) (\(fmt(size))) to \(d.name)?",
                                       move ? moveInfo + "\n\nBring them back anytime: menu → Moved to \(d.name)." : copyInfo,
                                       buttons: [move ? "Move" : "Copy", "Cancel"])
                    guard r == .alertFirstButtonReturn else { return }
                    doMove = move
                } else {
                    let r = self.alert("Send \(what) (\(fmt(size))) to \(d.name)?", moveInfo + "\n" + copyInfo, buttons: ["Move", "Copy", "Cancel"])
                    if r == .alertThirdButtonReturn { return }
                    doMove = r == .alertFirstButtonReturn
                }
                self.runTransfer(paths: paths, move: doMove, drive: d, total: size)
            }
        }
    }

    func runTransfer(paths: [String], move: Bool, drive d: Drive, total: Int64, batch: String? = nil, aliases: Bool? = nil) {
        let verb = move ? "Moving" : "Copying"
        busy = "\(verb)…"
        let leave = aliases ?? leaveAliases
        work.async {
            let prog: (Int64) -> Void = { self.setProgress(verb, $0, total) }
            let o = move ? moveToDrive(paths, vol: d.url, leaveAliases: leave, batch: batch, progress: prog)
                         : copyToDrive(paths, vol: d.url, progress: prog)
            DispatchQueue.main.async {
                self.busy = nil
                self.report(move ? "Moved" : "Copied", o, drive: d.name)
            }
        }
    }

    // MARK: Quick Copy (double-tap Right ⇧ in Finder, sent by ClaudeHere)

    @objc func quickCopyRequested() {
        guard busy == nil else { NSSound.beep(); return }
        guard let d = currentDrive() else { NSSound(named: "Basso")?.play(); flash("Plug in your T7"); return }
        let paths = finderSelection()
        guard !paths.isEmpty else { NSSound.beep(); flash("Select something in Finder"); return }
        let label = paths.count == 1 ? URL(fileURLWithPath: paths[0]).lastPathComponent : "\(paths.count) items"
        NSSound(named: "Tink")?.play()
        busy = "Copying \(label)…"
        work.async {
            let o = quickCopyToDrive(paths, vol: d.url)
            DispatchQueue.main.async {
                self.busy = nil
                if o.failed.isEmpty {
                    NSSound(named: "Glass")?.play()
                    self.flash("✓ Copied \(label)")
                } else {
                    self.report("Copied", o, drive: d.name)
                }
            }
        }
    }

    func flash(_ text: String) { hub?.flash(text) }

    // MARK: Free Up Space

    @objc func freeUpSpace() {
        guard busy == nil, let d = currentDrive() else { return }
        busy = "Scanning your Mac…"
        work.async {
            let cands = scanCandidates(vol: d.url)
            DispatchQueue.main.async {
                self.busy = nil
                self.showCandidates(cands, drive: d)
            }
        }
    }

    final class Picker: NSObject {
        var boxes: [NSButton] = []; var cands: [Candidate] = []; var label: NSTextField!
        @objc func changed() {
            let total = zip(boxes, cands).filter { $0.0.state == .on }.reduce(Int64(0)) { $0 + $1.1.bytes }
            label.stringValue = "Selected: \(fmt(total))"
        }
        @objc func selectAll() { boxes.forEach { $0.state = .on }; changed() }
    }

    func showCandidates(_ cands: [Candidate], drive d: Drive) {
        guard !cands.isEmpty else {
            alert("Nothing big and old found 🎉", "No items over \(fmt(bigItemBytes)) untouched for \(Int(oldAfterDays))+ days in \(scanRoots.joined(separator: ", ")).")
            return
        }
        let picker = Picker(); picker.cands = Array(cands.prefix(60))
        let rf = RelativeDateTimeFormatter(); rf.unitsStyle = .full
        let width: CGFloat = 560
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        for c in picker.cands {
            let when = c.batch != nil ? "" : " · last used \(rf.localizedString(for: c.lastUsed, relativeTo: Date()))"
            let b = NSButton(checkboxWithTitle: "\(c.title)  —  \(fmt(c.bytes))\(when)  ·  \(c.detail)", target: picker, action: #selector(Picker.changed))
            b.lineBreakMode = .byTruncatingMiddle
            b.widthAnchor.constraint(lessThanOrEqualToConstant: width - 30).isActive = true
            picker.boxes.append(b); stack.addArrangedSubview(b)
        }
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: width - 20, height: 10))
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor).isActive = true
        stack.topAnchor.constraint(equalTo: doc.topAnchor).isActive = true
        let h = stack.fittingSize.height
        doc.frame.size.height = h
        let flipped = FlippedView(frame: doc.frame); flipped.addSubview(stack)
        stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor).isActive = true
        stack.topAnchor.constraint(equalTo: flipped.topAnchor).isActive = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 30, width: width, height: min(340, h + 4)))
        scroll.documentView = flipped; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let label = NSTextField(labelWithString: "Selected: 0 bytes"); label.frame = NSRect(x: 0, y: 4, width: 300, height: 20)
        picker.label = label
        let all = NSButton(title: "Select All", target: picker, action: #selector(Picker.selectAll))
        all.frame = NSRect(x: width - 110, y: 0, width: 110, height: 28)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: scroll.frame.maxY))
        [scroll, label, all].forEach { container.addSubview($0) }
        let total = cands.reduce(Int64(0)) { $0 + $1.bytes }
        let r = alert("Free up to \(fmt(total)) on your Mac",
                      "Big items you haven't opened in \(Int(oldAfterDays))+ days. Tick what to move to \(d.name) — each is copied and checked before the original is removed, and you can bring anything back from the menu.",
                      buttons: ["Move Selected to \(d.name)", "Cancel"], accessory: container)
        guard r == .alertFirstButtonReturn else { return }
        let chosen = zip(picker.boxes, picker.cands).filter { $0.0.state == .on }.map { $0.1 }
        guard !chosen.isEmpty else { return }
        let size = chosen.reduce(Int64(0)) { $0 + $1.bytes }
        // Batches (old downloads) are moved as their own group; no aliases for bulk clean-ups.
        let singles = chosen.filter { $0.batch == nil }.flatMap { $0.paths }
        let batches = chosen.filter { $0.batch != nil }
        busy = "Moving…"
        work.async {
            var all = Outcome()
            let prog: (Int64) -> Void = { self.setProgress("Moving", all.bytes + $0, size) }
            func merge(_ o: Outcome) { all.done += o.done; all.bytes += o.bytes; all.failed += o.failed; all.trashed += o.trashed }
            merge(moveToDrive(singles, vol: d.url, leaveAliases: false, progress: prog))
            for b in batches { merge(moveToDrive(b.paths, vol: d.url, leaveAliases: false, batch: b.batch, progress: prog)) }
            DispatchQueue.main.async { self.busy = nil; self.report("Moved", all, drive: d.name) }
        }
    }

    // MARK: bring back

    @objc func bringBackItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        bringBackIDs([id])
    }
    @objc func bringBackBatch(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String] else { return }
        bringBackIDs(ids)
    }
    func bringBackIDs(_ ids: [String]) {
        guard busy == nil, let d = currentDrive() else { return }
        let recs = loadRecords(d.url).filter { ids.contains($0.id) }
        guard !recs.isEmpty else { return }
        let total = recs.reduce(Int64(0)) { $0 + $1.bytes }
        busy = "Bringing back…"
        work.async {
            var done: Int64 = 0
            var errors: [String] = []
            for r in recs {
                let base = done
                if let err = bringBack(r, vol: d.url, progress: { self.setProgress("Bringing back", base + $0, total) }) {
                    errors.append("⚠️ \(r.name): \(err)")
                }
                done += r.bytes
            }
            DispatchQueue.main.async {
                self.busy = nil
                if errors.isEmpty {
                    self.alert(recs.count == 1 ? "“\(recs[0].name)” is back on your Mac" : "\(recs.count) items are back on your Mac",
                               recs.count == 1 ? self.tildePath(recs[0].originalPath) : "")
                    NSWorkspace.shared.activateFileViewerSelecting(recs.prefix(20).map { URL(fileURLWithPath: $0.originalPath) })
                } else {
                    self.alert("Some items couldn't come back", errors.prefix(10).joined(separator: "\n"))
                }
            }
        }
    }

    // MARK: find / tools

    @objc func findOnDrive() {
        guard let d = currentDrive() else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Part of a file or folder name"
        let a = NSAlert(); a.messageText = "Find on \(d.name)"; a.addButton(withTitle: "Find"); a.addButton(withTitle: "Cancel")
        a.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        busy = "Searching…"
        work.async {
            let results = searchDrive(q, vol: d.url)
            DispatchQueue.main.async {
                self.busy = nil
                guard !results.isEmpty else { self.alert("Nothing named “\(q)” on \(d.name)"); return }
                let m = NSMenu(); m.autoenablesItems = false
                self.add(m, "\(results.count) result\(results.count == 1 ? "" : "s") for “\(q)” — click to show in Finder", nil, enabled: false)
                for u in results {
                    let rel = String(u.path.dropFirst(d.url.path.count))
                    let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    let it = self.add(m, u.lastPathComponent, #selector(self.revealAbsolute(_:)), symbol: isDir ? "folder" : "doc", rep: u.path)
                    it.toolTip = d.name + rel
                }
                m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            }
        }
    }
    @objc func revealAbsolute(_ s: NSMenuItem) {
        if let p = s.representedObject as? String { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
    }

    @objc func runSpeedTest() {
        guard busy == nil, let d = currentDrive() else { return }
        guard freeSpace(d.url) > 3_000_000_000 else { alert("Not enough free space for a speed test (needs 3 GB)"); return }
        busy = "Speed test…"
        work.async {
            let r = speedTest(vol: d.url)
            DispatchQueue.main.async {
                self.busy = nil
                guard let r else { self.alert("Speed test failed"); return }
                let verdict = r.write > 700 ? "🚀 Excellent — full USB 3.2 Gen 2 speed." :
                              r.write > 300 ? "👍 Good — try a USB-C port directly on the Mac (not a hub) for full speed." :
                                              "🐢 Slow — check the cable/port (USB 2 or a hub limits it to ~40 MB/s)."
                self.alert("\(d.name) speed", String(format: "Write: %.0f MB/s\nRead:  %.0f MB/s\n\n", r.write, r.read) + verdict)
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
    @objc func openCopies() {
        guard let d = currentDrive() else { return }
        let u = d.url.appendingPathComponent(copyFolder)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        NSWorkspace.shared.open(u)
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

    // MARK: sync

    @objc func syncNow() {
        guard busy == nil, let d = currentDrive() else { return }
        let folders = syncFolders
        guard !folders.isEmpty else { return }
        busy = "Syncing…"
        work.async {
            var problems: [String] = []
            var last = UserDefaults.standard.dictionary(forKey: "lastSync") as? [String: Date] ?? [:]
            for (i, f) in folders.enumerated() {
                DispatchQueue.main.async { self.busy = "Syncing \(i + 1)/\(folders.count)…" }
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
    @objc func toggleAliases() { leaveAliases.toggle() }
    @objc func toggleSleepUnmount() { sleepUnmount.toggle() }

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

}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

