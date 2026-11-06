// ClaudeHere — two tiny shortcuts for Claude Code on macOS:
//   • Double-tap ⌥ Option in Finder   → open Claude Code in a full-screen Terminal for the selected folder
//   • Double-tap Right ⌘ Command       → drag over the screen; the screenshot is pasted straight into
//                                        your open Claude Code session (Terminal)
//   • Double-tap Right ⇧ Shift in Finder → Command Center copies the selected items to your external drive
//   • Double-tap Left ⇧ Shift in Finder  → AirDrops the selected items straight to your iPhone
//   • Double-tap Left ⌃ Control anywhere → Command Center's Release Desk (your Android builds) pops up
// Pure macOS frameworks, no third-party dependencies.

import Cocoa
import ApplicationServices

// ---- Settings ----
let doubleTapWindow: TimeInterval = 0.35  // max seconds between the two taps
// Key codes: 58/61 = Left/Right Option, 55/54 = Left/Right Command, 59/62 = Left/Right Control
let openKeys: Set<Int64> = [58, 61]
let openFlag: CGEventFlags = .maskAlternate
let shotKeys: Set<Int64> = [54]
let shotFlag: CGEventFlags = .maskCommand
let copyKeys: Set<Int64> = [60]               // Right Shift
let copyFlag: CGEventFlags = .maskShift
let dropKeys: Set<Int64> = [56]               // Left Shift
let dropFlag: CGEventFlags = .maskShift
let releaseKeys: Set<Int64> = [59]            // Left Control
let releaseFlag: CGEventFlags = .maskControl
// ------------------

final class DoubleTap {
    let name: String, keys: Set<Int64>, flag: CGEventFlags, action: () -> Void
    var isDown = false, otherKeyPressed = false, lastTap: TimeInterval = 0
    init(_ name: String, _ keys: Set<Int64>, _ flag: CGEventFlags, _ action: @escaping () -> Void) {
        self.name = name; self.keys = keys; self.flag = flag; self.action = action
    }

    func flagsChanged(_ code: Int64, _ flags: CGEventFlags) {
        guard keys.contains(code) else { return }
        let pressed = flags.contains(flag)
        if pressed && !isDown {
            isDown = true; otherKeyPressed = false
        } else if !pressed && isDown {
            isDown = false
            if otherKeyPressed { lastTap = 0; return }   // used as a modifier (e.g. ⌘C), not a tap
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTap < doubleTapWindow {
                lastTap = 0
                log("double-tap: \(name) (front app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")
                DispatchQueue.main.async(execute: action)
            }
            else { lastTap = now }
        }
    }
}

var eventTap: CFMachPort?
var triggers: [DoubleTap] = []
var modifierLogBudget = 30

let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/ClaudeHere.log")
func log(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

@discardableResult
func runAppleScript(_ source: String) -> String? {
    var err: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
    if let err { log("AppleScript error: \(err)") }
    return result?.stringValue
}

func frontBundleID() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?" }
func terminalRunning() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty }

func alert(_ title: String, _ text: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
}

// MARK: - 1. Open Claude in the selected Finder folder

let finderPathScript = """
tell application "Finder"
  set sel to selection
  if (count of sel) > 0 then
    set f to item 1 of sel
    if class of f is folder or class of f is disk then return POSIX path of (f as alias)
    return POSIX path of (container of f as alias)
  else if (count of Finder windows) > 0 then
    return POSIX path of (target of front Finder window as alias)
  end if
  return POSIX path of (path to desktop folder)
end tell
"""

func makeTerminalFullScreen(attempt: Int = 0) {
    guard let term = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else { return }
    let axApp = AXUIElementCreateApplication(term.processIdentifier)
    var winRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success, let winRef {
        AXUIElementSetAttributeValue(winRef as! AXUIElement, "AXFullScreen" as CFString, kCFBooleanTrue)
    } else if attempt < 10 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { makeTerminalFullScreen(attempt: attempt + 1) }
    }
}

func openClaudeHere() {
    guard frontBundleID() == "com.apple.finder" else { return }
    guard let path = runAppleScript(finderPathScript) else { NSSound.beep(); return }
    log("opening Claude in \(path)")
    let cmd = "cd \(shellQuote(path)) && clear && claude"
    runAppleScript("""
    tell application "Terminal"
      activate
      do script \(appleQuote(cmd))
    end tell
    """)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { makeTerminalFullScreen() }
}

// MARK: - 2. Screenshot → Claude

/// Brings the most recently used Terminal tab that's running `claude` to the front.
let focusClaudeScript = """
tell application "Terminal"
  repeat with w in windows
    if (processes of (selected tab of w)) contains "claude" then
      set index of w to 1
      activate
      return "ok"
    end if
  end repeat
  repeat with w in windows
    repeat with t in tabs of w
      if (processes of t) contains "claude" then
        set selected of t to true
        set index of w to 1
        activate
        return "ok"
      end if
    end repeat
  end repeat
  return "none"
end tell
"""

var shotInProgress = false

func screenshotToClaude() {
    guard !shotInProgress else { return }
    // Screen Recording permission: macOS only applies it to a freshly started app,
    // so after asking we quit and launchd starts us again.
    if !CGPreflightScreenCaptureAccess() {
        log("asking for Screen Recording permission")
        _ = CGRequestScreenCaptureAccess()
        alert("Allow Screen Recording for ClaudeHere",
              "System Settings → Privacy & Security → Screen Recording → turn on ClaudeHere.\n\nClaudeHere will restart itself — then double-tap Right ⌘ again.")
        exit(0)
    }
    shotInProgress = true
    let file = NSTemporaryDirectory() + "claudehere-screenshot.png"
    try? FileManager.default.removeItem(atPath: file)
    DispatchQueue.global(qos: .userInitiated).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", file]          // interactive: drag an area, Space for a window, Esc to cancel
        try? p.run(); p.waitUntilExit()
        DispatchQueue.main.async {
            shotInProgress = false
            guard let png = FileManager.default.contents(atPath: file), !png.isEmpty else { log("screenshot cancelled"); return }
            try? FileManager.default.removeItem(atPath: file)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(png, forType: .png)
            guard terminalRunning(), runAppleScript(focusClaudeScript) == "ok" else {
                log("screenshot taken, but no Claude session found")
                alert("No Claude session open",
                      "Your screenshot is on the clipboard. Open Claude in Terminal (double-tap ⌥ in Finder) and press Control-V to paste it.")
                return
            }
            pasteWhenTerminalIsFront()
        }
    }
}

/// Waits until Terminal is actually frontmost (switching to a full-screen Space takes a moment), then presses ⌃V,
/// which is Claude Code's "paste image" shortcut.
func pasteWhenTerminalIsFront(attempt: Int = 0) {
    if frontBundleID() != "com.apple.Terminal" {
        if attempt < 30 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pasteWhenTerminalIsFront(attempt: attempt + 1) } }
        else { log("Terminal never came to the front; screenshot left on clipboard") }
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        let vKey: CGKeyCode = 9
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: down)
            e?.flags = .maskControl
            e?.post(tap: .cghidEventTap)
        }
        log("screenshot pasted into Claude")
    }
}

// MARK: - 3. Quick Copy to T7 (handled by T7 Helper)

func quickCopyToT7() {
    guard frontBundleID() == "com.apple.finder" else { return }
    let helperRunning = ["com.local.commandcenter", "com.local.t7helper"].contains {
        !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
    }
    guard helperRunning else { log("Quick Copy: Command Center isn't running"); NSSound.beep(); return }
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.local.t7helper.quickCopy"),
                                                                 object: nil, userInfo: nil, deliverImmediately: true)
    log("Quick Copy: asked Command Center to copy the Finder selection")
}

// MARK: - 5. Release Desk (shown by Command Center)

func openReleaseDesk() {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.commandcenter").isEmpty else {
        log("Release Desk: Command Center isn't running"); NSSound.beep(); return
    }
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.local.commandcenter.releaseMenu"),
                                                                 object: nil, userInfo: nil, deliverImmediately: true)
}

// MARK: - 4. AirDrop the Finder selection to your iPhone

let finderSelectionScript = """
tell application "Finder"
  set out to ""
  repeat with f in (selection as alias list)
    set out to out & POSIX path of f & linefeed
  end repeat
  return out
end tell
"""

final class AirDropDelegate: NSObject, NSSharingServiceDelegate {
    func sharingService(_ s: NSSharingService, didShareItems items: [Any]) {
        log("AirDrop: sent \(items.count) item(s)"); NSSound(named: "Glass")?.play()
    }
    func sharingService(_ s: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        log("AirDrop: failed — \(error.localizedDescription)")
    }
}
let airDropDelegate = AirDropDelegate()
var airDropService: NSSharingService?

func airDropToIPhone() {
    guard frontBundleID() == "com.apple.finder" else { return }
    let urls = (runAppleScript(finderSelectionScript) ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    guard !urls.isEmpty else { NSSound.beep(); log("AirDrop: nothing selected in Finder"); return }
    guard let svc = NSSharingService(named: .sendViaAirDrop), svc.canPerform(withItems: urls) else {
        alert("AirDrop isn't available", "Turn on Wi-Fi and Bluetooth, and make sure AirDrop is enabled in Control Center.")
        return
    }
    svc.delegate = airDropDelegate
    airDropService = svc
    NSApp.activate(ignoringOtherApps: true)
    svc.perform(withItems: urls)
    log("AirDrop: opened for \(urls.count) item(s)")
    pressIPhoneWhenVisible()
}

/// Every element in an accessibility tree that has a visible label.
func labeledElements(_ root: AXUIElement, depth: Int = 0, into out: inout [(AXUIElement, String)]) {
    guard depth < 25, out.count < 400 else { return }
    for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, attr as CFString, &v) == .success, let s = v as? String, !s.isEmpty {
            out.append((root, s)); break
        }
    }
    var kids: CFTypeRef?
    guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &kids) == .success,
          let children = kids as? [AXUIElement] else { return }
    for c in children { labeledElements(c, depth: depth + 1, into: &out) }
}

/// Presses the element, or the nearest pressable parent.
func press(_ el: AXUIElement) -> Bool {
    var cur: AXUIElement? = el
    for _ in 0..<4 {
        guard let e = cur else { return false }
        if AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { return true }
        var parent: CFTypeRef?
        cur = AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parent) == .success ? (parent as! AXUIElement) : nil
    }
    return false
}

/// The AirDrop picker can live in our own process or in a system sharing helper — search both.
func airDropRoots() -> [(AXUIElement, String)] {
    var roots = [(AXUIElementCreateApplication(getpid()), "ClaudeHere")]
    for app in NSWorkspace.shared.runningApplications {
        let id = (app.bundleIdentifier ?? "").lowercased(), name = (app.localizedName ?? "").lowercased()
        if id.contains("sharing") || id.contains("airdrop") || id.contains("sharesheet") || name.contains("airdrop") || name.contains("sharing") {
            roots.append((AXUIElementCreateApplication(app.processIdentifier), app.bundleIdentifier ?? name))
        }
    }
    return roots
}

/// Same name? Ignores case, straight-vs-curly apostrophes and anything after the first line (e.g. a status).
func sameDeviceName(_ label: String, _ wanted: String) -> Bool {
    func norm(_ s: String) -> String {
        (s.components(separatedBy: .newlines).first ?? s).replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }
    return norm(label) == norm(wanted)
}

func pressIPhoneWhenVisible(attempt: Int = 0) {
    // Only ever auto-sends to YOUR device, matched by exact name — never "any iPhone" nearby.
    // Set it with: defaults write com.local.claudehere airdropDevice "Your iPhone's name"
    guard let wanted = UserDefaults.standard.string(forKey: "airdropDevice"), !wanted.isEmpty else {
        log("AirDrop: no airdropDevice set — choose the device in the AirDrop window"); return
    }
    var found: [(AXUIElement, String)] = []
    var where_: [String] = []
    for (root, name) in airDropRoots() {
        var els: [(AXUIElement, String)] = []
        labeledElements(root, into: &els)
        if !els.isEmpty { where_.append(name) }
        found += els
    }
    if let target = found.first(where: { sameDeviceName($0.1, wanted) }) {
        if press(target.0) { log("AirDrop: sending to “\(target.1)”"); return }
    }
    if attempt == 8 || attempt == 24 {   // diagnostics: what the picker shows (labels only)
        let labels = Set(found.map { $0.1 }).prefix(40).joined(separator: " | ")
        log("AirDrop: looking for “\(wanted)” in [\(where_.joined(separator: ", "))] — labels: \(labels)")
    }
    if attempt < 48 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pressIPhoneWhenVisible(attempt: attempt + 1) } }
    else { log("AirDrop: couldn't find “\(wanted)” — pick it in the AirDrop window") }
}

// MARK: - Key listening

let callback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    case .keyDown:
        triggers.forEach { if $0.isDown { $0.otherKeyPressed = true } }
    case .flagsChanged:
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if modifierLogBudget > 0 {   // diagnostics: first few modifier keys (⌘⌥⌃⇧ only, never typed text)
            modifierLogBudget -= 1
            log("modifier key \(code) \(event.flags.contains(.maskCommand) ? "⌘" : "")\(event.flags.contains(.maskAlternate) ? "⌥" : "")\(event.flags.contains(.maskControl) ? "⌃" : "")\(event.flags.contains(.maskShift) ? "⇧" : "")")
        }
        triggers.forEach { $0.flagsChanged(code, event.flags) }
    default: break
    }
    return Unmanaged.passUnretained(event)
}

var loggedWaiting = false
func startTap() {
    // macOS won't deliver keys to a tap created before permission was granted,
    // so wait for permission, then quit — launchd (KeepAlive) relaunches us with it.
    if !(CGPreflightListenEventAccess() && AXIsProcessTrusted()) {
        if !loggedWaiting {
            loggedWaiting = true
            log("waiting for permission (accessibility=\(AXIsProcessTrusted()), inputMonitoring=\(CGPreflightListenEventAccess()))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if CGPreflightListenEventAccess() && AXIsProcessTrusted() { log("permission granted, restarting"); exit(0) }
            startTap()
        }
        return
    }
    let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                      callback: callback, userInfo: nil) else {
        log("couldn't create key listener; retrying")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { startTap() }
        return
    }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("listening: ⌥⌥ in Finder = open Claude, Right ⌘⌘ = screenshot → Claude, Right ⇧⇧ in Finder = copy to T7, Left ⇧⇧ in Finder = AirDrop to iPhone, Left ⌃⌃ = Release Desk (screenRecording=\(CGPreflightScreenCaptureAccess()))")
}

triggers = [
    DoubleTap("⌥ → open Claude here", openKeys, openFlag, openClaudeHere),
    DoubleTap("Right ⌘ → screenshot to Claude", shotKeys, shotFlag, screenshotToClaude),
    DoubleTap("Right ⇧ in Finder → copy to T7", copyKeys, copyFlag, quickCopyToT7),
    DoubleTap("Left ⇧ in Finder → AirDrop to iPhone", dropKeys, dropFlag, airDropToIPhone),
    DoubleTap("Left ⌃ → Release Desk", releaseKeys, releaseFlag, openReleaseDesk),
]

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar

// Only one copy may run. System Settings' "Quit & Reopen" (after granting a permission) starts an extra copy
// next to the one launchd keeps alive — the launchd copy wins, any other copy quits.
func enforceSingleInstance() {
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .filter { $0.processIdentifier != me }
    guard !others.isEmpty else { return }
    if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.local.claudehere" {
        others.forEach { _ = $0.forceTerminate() }
        log("stopped \(others.count) extra copy")
    } else {
        log("another copy is already running; quitting")
        exit(0)
    }
}
enforceSingleInstance()
DispatchQueue.main.asyncAfter(deadline: .now() + 3) { enforceSingleInstance() }  // catch copies that started at the same moment
log("started")
// Permissions: Input Monitoring (see the double-taps) + Accessibility (full screen, paste).
// Screen Recording is requested the first time you take a screenshot.
if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
startTap()
app.run()
