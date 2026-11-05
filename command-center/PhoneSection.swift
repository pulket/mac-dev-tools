// iPhone section of Command Center — Clip Bridge: clipboard sync with your iPhone over Wi-Fi.
//   iPhone → Mac : a Shortcut POSTs the iPhone clipboard here → Mac clipboard
//   Mac → iPhone : a Shortcut GETs the Mac clipboard (text, image, or a file copied in Finder)
// Trigger both with Back Tap. Every request must carry a secret key only your devices know.

import Cocoa
import Network
import SystemConfiguration
import ServiceManagement
import UniformTypeIdentifiers

let bridgePort: UInt16 = 8790
let maxBody = 100 * 1024 * 1024

let secretKey: String = {
    let d = UserDefaults.standard
    if let k = d.string(forKey: "clipKey") { return k }
    // Keep the key from the old standalone iPhone Bridge app, so existing iPhone Shortcuts keep working.
    if let old = oldPref("clipKey", app: "com.local.iphonebridge") as? String { d.set(old, forKey: "clipKey"); return old }
    let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    var rng = SystemRandomNumberGenerator()
    let k = String((0..<28).map { _ in chars.randomElement(using: &rng)! })
    d.set(k, forKey: "clipKey")
    return k
}()

func localHostName() -> String {
    ((SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "localhost") + ".local"
}

// MARK: - Minimal HTTP server (Network.framework)

struct Request {
    var method = "", path = "", query: [String: String] = [:], headers: [String: String] = [:], body = Data()
}
struct Response {
    var status = 200, contentType = "text/plain; charset=utf-8", body = Data(), filename: String? = nil
    static func text(_ s: String, _ status: Int = 200) -> Response { Response(status: status, body: Data(s.utf8)) }
}

final class Connection {
    let conn: NWConnection, handler: (Request) -> Response
    var buffer = Data()
    init(_ c: NWConnection, _ h: @escaping (Request) -> Response) { conn = c; handler = h }

    func start(on q: DispatchQueue) { conn.start(queue: q); receive() }

    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
            if let data { self.buffer.append(data) }
            if self.buffer.count > maxBody + 65536 { self.reply(.text("Too large (max 100 MB)", 413)); return }
            if let req = self.parse() { self.reply(self.handler(req)); return }
            if done || err != nil { self.conn.cancel(); return }
            self.receive()
        }
    }

    /// Returns a complete request once headers + full body have arrived.
    func parse() -> Request? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return Request(method: "BAD") }
        var r = Request()
        r.method = String(first[0])
        let target = String(first[1])
        let comps = URLComponents(string: target)
        r.path = comps?.path ?? target
        for item in comps?.queryItems ?? [] { r.query[item.name] = item.value ?? "" }
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            r.headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headEnd.upperBound
        if r.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let body = dechunk(buffer[bodyStart...]) else { return nil }
            r.body = body
        } else {
            let len = Int(r.headers["content-length"] ?? "0") ?? 0
            guard buffer.count - bodyStart >= len else { return nil }
            r.body = buffer.subdata(in: bodyStart..<(bodyStart + len))
        }
        return r
    }

    func dechunk(_ d: Data) -> Data? {
        var out = Data(), i = d.startIndex
        while true {
            guard let lineEnd = d[i...].range(of: Data("\r\n".utf8)) else { return nil }
            let sizeStr = String(decoding: d[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            let start = lineEnd.upperBound
            if size == 0 { return out }
            guard d.endIndex - start >= size + 2 else { return nil }
            out.append(d[start..<(start + size)])
            i = start + size + 2
        }
    }

    func reply(_ r: Response) {
        let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 413: "Payload Too Large"]
        var head = "HTTP/1.1 \(r.status) \(reasons[r.status] ?? "OK")\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n"
        if let f = r.filename {
            let safe = f.replacingOccurrences(of: "\"", with: "")
            head += "Content-Disposition: attachment; filename=\"\(safe)\"\r\n"
        }
        head += "\r\n"
        conn.send(content: Data(head.utf8) + r.body, completion: .contentProcessed { _ in self.conn.cancel() })
    }
}

final class HTTPServer {
    let queue = DispatchQueue(label: "iphonebridge.http")
    var listener: NWListener?
    var onState: ((String) -> Void)?

    func start(handler: @escaping (Request) -> Response) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: bridgePort)!)
            l.newConnectionHandler = { c in Connection(c, handler).start(on: self.queue) }
            l.stateUpdateHandler = { s in
                switch s {
                case .ready: self.onState?("ready")
                case .failed(let e): self.onState?("failed: \(e)"); log("listener failed: \(e)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.listener?.cancel(); self.start(handler: handler) }
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            onState?("failed: \(error)"); log("couldn't start server: \(error)")
        }
    }
}

// MARK: - Clipboard

func mime(forExtension ext: String) -> String {
    UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
}
func ext(forMime m: String) -> String {
    UTType(mimeType: m.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces))?.preferredFilenameExtension ?? "bin"
}

/// What's on the Mac clipboard, in a form Shortcuts understands.
func macClipboardResponse() -> Response {
    let pb = NSPasteboard.general
    let types = pb.types ?? []
    // 1. A file copied in Finder → send the file itself
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
       let u = urls.first {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue,
           let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBody,
           let data = try? Data(contentsOf: u) {
            return Response(status: 200, contentType: mime(forExtension: u.pathExtension), body: data, filename: u.lastPathComponent)
        }
    }
    // 2. Image (when the copying app's preferred type is an image), else 3. text
    let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
    let firstIsImage = types.first.map { imageTypes.contains($0) } ?? false
    func image() -> Response? {
        if let png = pb.data(forType: .png) { return Response(status: 200, contentType: "image/png", body: png, filename: "Mac Clipboard.png") }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return Response(status: 200, contentType: "image/png", body: png, filename: "Mac Clipboard.png")
        }
        return nil
    }
    if firstIsImage, let r = image() { return r }
    if let s = pb.string(forType: .string), !s.isEmpty { return .text(s) }
    if let r = image() { return r }
    return Response(status: 204, body: Data())
}

/// Puts what the iPhone sent onto the Mac clipboard. Returns a short description.
func receiveFromPhone(_ req: Request) -> String? {
    let ct = (req.headers["content-type"] ?? "").lowercased()
    let body = req.body
    guard !body.isEmpty else { return nil }
    let pb = NSPasteboard.general
    if ct.hasPrefix("image/"), let img = NSImage(data: body) {
        pb.clearContents(); pb.writeObjects([img])
        return "🖼 Image (\(ByteCountFormatter.string(fromByteCount: Int64(body.count), countStyle: .file)))"
    }
    let looksLikeText = ct.isEmpty || ct.hasPrefix("text/") || ct.contains("json") || ct.contains("xml")
        || (ct.contains("octet-stream") && body.count < 2_000_000)
    if looksLikeText, let s = String(data: body, encoding: .utf8) {
        pb.clearContents(); pb.setString(s, forType: .string)
        let preview = s.replacingOccurrences(of: "\n", with: " ")
        return "📝 “\(preview.prefix(40))\(preview.count > 40 ? "…" : "")”"
    }
    // Any other file (PDF, video, …) → save to Downloads/From iPhone and put the file on the clipboard
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/From iPhone")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    var name = "iPhone \(df.string(from: Date())).\(ext(forMime: ct))"
    if let cd = req.headers["content-disposition"], let r = cd.range(of: "filename=\"") {
        let rest = cd[r.upperBound...]
        if let end = rest.firstIndex(of: "\"") { name = String(rest[..<end]).replacingOccurrences(of: "/", with: "-") }
    }
    let url = dir.appendingPathComponent(name)
    guard (try? body.write(to: url)) != nil else { return nil }
    pb.clearContents(); pb.writeObjects([url as NSURL])
    return "📄 \(name) (saved in Downloads › From iPhone)"
}

// MARK: - Shortcut generation

func uuid() -> String { UUID().uuidString }

func outputRef(_ uuid: String, _ name: String) -> [String: Any] {
    ["Value": ["OutputUUID": uuid, "Type": "ActionOutput", "OutputName": name], "WFSerializationType": "WFTextTokenAttachment"]
}

func shortcutPlist(actions: [[String: Any]], color: Int, glyph: Int) -> [String: Any] {
    [
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2302.0.4",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": ["WFWorkflowIconStartColor": color, "WFWorkflowIconGlyphNumber": glyph],
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": [],
        "WFWorkflowHasShortcutInputVariables": false,
    ]
}

func notifyAction(_ title: String, _ body: String) -> [String: Any] {
    ["WFWorkflowActionIdentifier": "is.workflow.actions.notification",
     "WFWorkflowActionParameters": ["UUID": uuid(), "WFNotificationActionTitle": title,
                                    "WFNotificationActionBody": body, "WFNotificationActionSound": false]]
}

func sendToMacShortcut(_ url: String) -> [String: Any] {
    let clip = uuid()
    return shortcutPlist(actions: [
        ["WFWorkflowActionIdentifier": "is.workflow.actions.getclipboard",
         "WFWorkflowActionParameters": ["UUID": clip]],
        ["WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
         "WFWorkflowActionParameters": ["UUID": uuid(), "WFURL": url, "WFHTTPMethod": "POST",
                                        "WFHTTPBodyType": "File", "WFRequestVariable": outputRef(clip, "Clipboard"), "ShowHeaders": false]],
        notifyAction("Sent to Mac", "📋 ✅"),
    ], color: 4282601983, glyph: 59511)
}

func getFromMacShortcut(_ url: String) -> [String: Any] {
    let dl = uuid()
    return shortcutPlist(actions: [
        ["WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
         "WFWorkflowActionParameters": ["UUID": dl, "WFURL": url, "WFHTTPMethod": "GET", "ShowHeaders": false]],
        ["WFWorkflowActionIdentifier": "is.workflow.actions.setclipboard",
         "WFWorkflowActionParameters": ["UUID": uuid(), "WFInput": outputRef(dl, "Contents of URL"), "WFLocalOnly": false]],
        notifyAction("Copied from Mac", "📋 ✅"),
    ], color: 463140863, glyph: 59511)
}

/// Writes, signs and returns the two .shortcut files.
func makeShortcuts() throws -> [URL] {
    let host = localHostName()
    let base = "http://\(host):\(bridgePort)/clip?key=\(secretKey)"
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/iPhone Bridge Shortcuts")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmp = FileManager.default.temporaryDirectory
    var out: [URL] = []
    for (name, plist) in [("Send Clipboard to Mac", sendToMacShortcut(base)), ("Get Mac Clipboard", getFromMacShortcut(base))] {
        let unsigned = tmp.appendingPathComponent("\(name)-unsigned.shortcut")
        let signed = dir.appendingPathComponent("\(name).shortcut")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: unsigned)
        try? FileManager.default.removeItem(at: signed)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["sign", "--mode", "anyone", "--input", unsigned.path, "--output", signed.path]
        let errPipe = Pipe(); p.standardError = errPipe; p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: signed.path) else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "iPhoneBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Signing “\(name)” failed: \(err)"])
        }
        out.append(signed)
    }
    return out
}

// MARK: - Section

final class PhoneSection: NSObject {
    weak var hub: Hub?
    let server = HTTPServer()
    var serverState = "starting…"
    var lastEvent: (String, Date)?

    func start() {
        server.onState = { s in DispatchQueue.main.async { self.serverState = s } }
        server.start { req in self.handle(req) }
        log("iPhone Bridge listening on \(localHostName()):\(bridgePort)")
    }

    var ready: Bool { serverState == "ready" }
    func rowTitle() -> String { ready ? "iPhone Bridge — ready" : "iPhone Bridge — not running" }

    /// Runs on the server queue; clipboard work hops to the main thread.
    func handle(_ req: Request) -> Response {
        let key = req.query["key"] ?? req.headers["x-key"] ?? ""
        guard key == secretKey else { log("iPhone Bridge: rejected request with wrong key"); return .text("Wrong key", 401) }
        switch (req.method, req.path) {
        case ("GET", "/ping"):
            return .text("iPhone Bridge OK")
        case ("GET", "/clip"):
            let r = DispatchQueue.main.sync { macClipboardResponse() }
            DispatchQueue.main.async { self.note(r.status == 204 ? "📤 Mac clipboard was empty" : "📤 Sent Mac clipboard to iPhone") }
            return r
        case ("POST", "/clip"), ("PUT", "/clip"):
            let desc = DispatchQueue.main.sync { receiveFromPhone(req) }
            guard let desc else { return .text("Your iPhone clipboard is empty", 400) }
            DispatchQueue.main.async { self.note("📥 " + desc); NSSound(named: "Pop")?.play() }
            return .text("✅ On your Mac clipboard")
        default:
            return .text("Not found", 404)
        }
    }

    func note(_ s: String) { lastEvent = (s, Date()); log("iPhone Bridge: " + s) }

    @discardableResult
    func add(_ m: NSMenu, _ title: String, _ action: Selector?, enabled: Bool = true, symbol: String? = nil) -> NSMenuItem {
        let i = menuItem(title, action, target: self, enabled: enabled, symbol: symbol)
        m.addItem(i); return i
    }

    func buildMenu(_ menu: NSMenu) {
        add(menu, ready ? "🟢 Ready at \(localHostName())" : "🔴 Not running (\(serverState))", nil)
        if let (s, d) = lastEvent {
            add(menu, "\(s) · \(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()))", nil)
        }
        add(menu, "Back Tap ×2 = iPhone → Mac   ·   ×3 = Mac → iPhone", nil)
        menu.addItem(.separator())
        add(menu, "Set Up iPhone Shortcuts…", #selector(setUpShortcuts), symbol: "square.and.arrow.down")
        add(menu, "How to Use…", #selector(howTo), symbol: "questionmark.circle")
        add(menu, "Fix Universal Clipboard", #selector(fixUniversalClipboard), symbol: "wand.and.stars")
    }

    @objc func setUpShortcuts() {
        do {
            let files = try makeShortcuts()
            let r = showAlert("Add the two Shortcuts",
                          """
                          Click “Add Shortcut” in each window that opens. If iCloud sync is on for Shortcuts, they appear on your iPhone automatically.

                          (No iCloud sync? AirDrop the two files from Downloads › iPhone Bridge Shortcuts to your iPhone instead.)

                          Then on your iPhone:
                          Settings › Accessibility › Touch › Back Tap
                            • Double Tap → “Send Clipboard to Mac”
                            • Triple Tap → “Get Mac Clipboard”

                          The first run asks to allow local-network access — tap Allow.
                          """, buttons: ["Open Shortcuts", "Show Files", "Cancel"])
            if r == .alertFirstButtonReturn { files.forEach { NSWorkspace.shared.open($0) } }
            else if r == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting(files) }
        } catch {
            showAlert("Couldn't create the Shortcuts", error.localizedDescription)
        }
    }

    @objc func howTo() {
        showAlert("How Clip Bridge works",
                  """
                  iPhone → Mac: copy on your iPhone, then double-tap the back of the phone. Press ⌘V on the Mac.

                  Mac → iPhone: copy on the Mac (text, image, or a file in Finder), then triple-tap the back of the phone. Paste on the iPhone.

                  Both devices must be on the same Wi-Fi (or the iPhone's hotspot). Files other than text/images arrive in Downloads › From iPhone.

                  Your Mac: \(localHostName()) · port \(bridgePort)
                  """)
    }

    @objc func fixUniversalClipboard() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["sharingd"]   // macOS restarts it immediately; this often revives Handoff / Universal Clipboard
        try? p.run(); p.waitUntilExit()
        showAlert("Restarted Handoff", "Apple's Universal Clipboard service was restarted. Give it ~10 seconds, then try copy/paste between devices again.\n\nIf it still fails, check that Bluetooth, Wi-Fi and Handoff are on on both devices.")
    }
}
