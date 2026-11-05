// ClaudeHere — double-tap Right Option in Finder to open Claude Code
// in a full-screen Terminal window for the selected folder.
// Pure macOS frameworks, no third-party dependencies.

import Cocoa
import ApplicationServices

// ---- Settings ----
let triggerKeyCodes: Set<Int64> = [58, 61] // 58 = Left Option, 61 = Right Option (54/55 = Cmd, 59/62 = Control)
let triggerFlag: CGEventFlags = .maskAlternate  // .maskCommand for Cmd, .maskControl for Control
let doubleTapWindow: TimeInterval = 0.35  // max seconds between the two taps
// ------------------

var keyIsDown = false
var otherKeyPressed = false
var lastTap: TimeInterval = 0
var eventTap: CFMachPort?

let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/ClaudeHere.log")
func log(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

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

let callback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    case .keyDown:
        otherKeyPressed = true   // key used as a modifier (e.g. ⌥+letter), not a tap
    case .flagsChanged:
        guard triggerKeyCodes.contains(event.getIntegerValueField(.keyboardEventKeycode)) else { break }
        let pressed = event.flags.contains(triggerFlag)
        if pressed && !keyIsDown {
            keyIsDown = true
            otherKeyPressed = false
        } else if !pressed && keyIsDown {
            keyIsDown = false
            if otherKeyPressed { lastTap = 0; break }
            let now = ProcessInfo.processInfo.systemUptime
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            if now - lastTap < doubleTapWindow {
                lastTap = 0
                log("double-tap detected (front app: \(front))")
                if front == "com.apple.finder" { DispatchQueue.main.async { openClaudeHere() } }
            } else {
                lastTap = now
            }
        }
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
        // No permission yet — keep retrying until the user grants it.
        if !loggedWaiting {
            loggedWaiting = true
            log("waiting for permission (accessibility=\(AXIsProcessTrusted()), inputMonitoring=\(CGPreflightListenEventAccess()))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { startTap() }
        return
    }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("listening for double-tap ⌥ (accessibility=\(AXIsProcessTrusted()), inputMonitoring=\(CGPreflightListenEventAccess()))")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
log("started")
// Ask for both permissions macOS needs: Input Monitoring (see keys) + Accessibility (full screen)
if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
startTap()
app.run()
