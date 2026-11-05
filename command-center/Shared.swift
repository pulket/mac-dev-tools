// Shared helpers used by every section of Command Center.

import Cocoa
import Carbon.HIToolbox

let home = NSHomeDirectory()
func expand(_ p: String) -> String { p.hasPrefix("~") ? home + p.dropFirst() : p }
func tildify(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

let logDir = URL(fileURLWithPath: home + "/Library/Logs/CommandCenter")

/// Appends a line to ~/Library/Logs/CommandCenter/command-center.log
func log(_ msg: String) {
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let url = logDir.appendingPathComponent("command-center.log")
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

/// A plain modal alert; returns which button was pressed.
@discardableResult
func showAlert(_ title: String, _ text: String = "", buttons: [String] = ["OK"], accessory: NSView? = nil) -> NSApplication.ModalResponse {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert(); a.messageText = title; a.informativeText = text
    buttons.forEach { a.addButton(withTitle: $0) }
    a.accessoryView = accessory
    return a.runModal()
}

/// Builds a menu item (target is set by the caller's `add` helpers).
func menuItem(_ title: String, _ action: Selector?, target: AnyObject?, key: String = "", mods: NSEvent.ModifierFlags = [],
              enabled: Bool = true, symbol: String? = nil, rep: Any? = nil) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
    i.keyEquivalentModifierMask = mods
    i.target = target; i.representedObject = rep
    i.isEnabled = enabled && (action != nil)
    if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    return i
}

/// Reads a value another (older) app stored in its own preferences — used to migrate settings.
func oldPref(_ key: String, app: String) -> Any? {
    CFPreferencesCopyAppValue(key as CFString, app as CFString)
}

// MARK: - Global hotkeys (Carbon — no special permission needed). All use ⌃⌥ + key.

var hotKeyActions: [UInt32: () -> Void] = [:]
private var hotKeyHandlerInstalled = false

func registerHotKey(_ id: UInt32, key: Int, _ action: @escaping () -> Void) {
    if !hotKeyHandlerInstalled {
        hotKeyHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { hotKeyActions[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
    hotKeyActions[id] = action
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                        EventHotKeyID(signature: OSType(0x434D4443), id: id), GetApplicationEventTarget(), 0, &ref)
}

/// Implemented by the app delegate so sections can refresh the shared menu-bar icon.
protocol Hub: AnyObject {
    func updateStatus()
    func flash(_ text: String)
}
