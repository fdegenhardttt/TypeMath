import Cocoa
import ApplicationServices
import ServiceManagement

/// Marks keystrokes we post ourselves so the tap ignores them.
private let syntheticMarker: Int64 = 0x4D41_5448

private enum KeyCode {
    static let tab: Int64 = 48
    static let delete: Int64 = 51
    /// Return, enter, escape, arrows, home/end, page up/down, forward delete.
    static let resetting: Set<Int64> = [36, 76, 53, 123, 124, 125, 126, 115, 119, 116, 121, 117]
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let app = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
    return app.handle(type: type, event: event)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var tap: CFMachPort?
    private var buffer = ""
    private var pendingMatch: Evaluator.Match?
    /// The text before the caret that `pendingMatch` was found in.
    private var matchedText = ""
    private let popup = AnswerPopup()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    /// The app that was in front when the menu opened, for the per-app toggle.
    private var menuTargetApp: NSRunningApplication?
    private let menu = NSMenu()

    private var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "disabled") }
        set { UserDefaults.standard.set(!newValue, forKey: "disabled") }
    }

    private var disabledApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "disabledApps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "disabledApps") }
    }

    private var activeInFrontApp: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return true }
        return !disabledApps.contains(id)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "equal.square", accessibilityDescription: "TypeMath")
        rebuildMenu()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startTap()
        } else {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard AXIsProcessTrusted() else { return }
                self?.permissionTimer?.invalidate()
                self?.startTap()
                self?.rebuildMenu()
            }
        }
    }

    // MARK: Menu

    private func rebuildMenu() {
        menu.removeAllItems()
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "Allow Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        let enabledItem = menu.addItem(withTitle: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = enabled ? .on : .off

        if let app = menuTargetApp, let id = app.bundleIdentifier, let name = app.localizedName {
            let appItem = menu.addItem(withTitle: "Enabled in \(name)", action: #selector(toggleFrontApp), keyEquivalent: "")
            appItem.target = self
            appItem.state = disabledApps.contains(id) ? .off : .on
            appItem.isEnabled = enabled
        }

        let loginItem = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TypeMath", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.appearsDisabled = !enabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let front = NSWorkspace.shared.frontmostApplication
        menuTargetApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        rebuildMenu()
    }

    @objc private func toggleFrontApp() {
        guard let id = menuTargetApp?.bundleIdentifier else { return }
        if disabledApps.contains(id) { disabledApps.remove(id) } else { disabledApps.insert(id) }
        reset()
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        reset()
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        try? service.status == .enabled ? service.unregister() : service.register()
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Keyboard tap

    private func startTap() {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("TypeMath: could not create event tap")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard enabled, activeInFrontApp,
              event.getIntegerValueField(.eventSourceUserData) != syntheticMarker else { return pass }

        guard type == .keyDown else {
            reset()  // a click moves the caret
            return pass
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let hasShortcutModifier = event.flags.contains(.maskCommand) || event.flags.contains(.maskControl)

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        let typed = String(utf16CodeUnits: chars, count: length)

        // Graphs are only previewed, so "=" and Tab act normally while one is showing.
        if let match = pendingMatch, let answer = match.answer, !hasShortcutModifier {
            if typed == "=" {
                fill(answer)
                return nil  // swallow the second "="
            }
            if keyCode == KeyCode.tab, modifiers.isEmpty {
                replace(length: match.length, with: answer)
                return nil  // swallow the tab
            }
        }

        if hasShortcutModifier || keyCode == KeyCode.tab || KeyCode.resetting.contains(keyCode) {
            reset()
            return pass
        }

        if keyCode == KeyCode.delete {
            if !buffer.isEmpty { buffer.removeLast() }
        } else if typed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            reset()
            return pass
        } else {
            buffer += typed
            if buffer.count > 200 { buffer = String(buffer.suffix(200)) }
        }

        pendingMatch = nil  // never act on a match from before this keystroke
        // Let the target app insert the character first, so its text and caret are current.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.updateMatch() }
        return pass
    }

    private func updateMatch() {
        // Prefer the app's real text (handles dead keys like ^, autocorrect and paste);
        // fall back to the keystrokes we saw in apps that don't expose their text.
        matchedText = CaretLocator.textBeforeCaret() ?? buffer
        pendingMatch = Evaluator.match(in: matchedText)
        if let match = pendingMatch {
            popup.show(match, near: CaretLocator.caretRect())
        } else {
            popup.hide()
        }
    }

    private func reset() {
        buffer = ""
        pendingMatch = nil
        popup.hide()
    }

    /// "=" again: types the answer after the equation, matching the spacing around "=".
    private func fill(_ answer: String) {
        var text = answer
        if matchedText.hasSuffix("=") && matchedText.dropLast().hasSuffix(" ") { text = " " + text }
        type(text)
        buffer = matchedText + text
        pendingMatch = nil
        popup.hide()
    }

    /// Tab: deletes the equation and types just the answer in its place.
    private func replace(length: Int, with answer: String) {
        for _ in 0..<length {
            post(virtualKey: UInt16(KeyCode.delete), text: nil)
        }
        type(answer)
        buffer = String(matchedText.dropLast(length)) + answer
        pendingMatch = nil
        popup.hide()
    }

    private func type(_ text: String) {
        let utf16 = Array(text.utf16)
        for start in stride(from: 0, to: utf16.count, by: 16) {  // some apps cap a single event at 20 units
            post(virtualKey: 0, text: Array(utf16[start..<min(start + 16, utf16.count)]))
        }
    }

    private func post(virtualKey: UInt16, text: [UniChar]?) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: keyDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            if var text { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: &text) }
            event.post(tap: .cgSessionEventTap)
        }
    }
}

// MARK: - Caret position

enum CaretLocator {
    /// Screen rect of the text caret in Cocoa coordinates, or a small rect at the mouse if unavailable.
    static func caretRect() -> NSRect {
        if let rect = axCaretRect() { return rect }
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 20)
    }

    /// The current line up to the caret in the focused text field, if the app exposes it.
    static func textBeforeCaret() -> String? {
        guard let (field, range) = focusedSelection(), range.length == 0, range.location >= 0 else { return nil }
        let start = max(range.location - 200, 0)
        var lookup = CFRange(location: start, length: range.location - start)
        guard let lookupValue = AXValueCreate(.cfRange, &lookup) else { return nil }

        var result: CFTypeRef?
        var text: String?
        if AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString,
                                                      lookupValue, &result) == .success {
            text = result as? String
        } else if AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &result) == .success,
                  let value = result as? String {
            let utf16 = Array(value.utf16)
            guard range.location <= utf16.count else { return nil }
            text = String(decoding: utf16[start..<range.location], as: UTF16.self)
        }
        guard let text else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    private static func focusedSelection() -> (AXUIElement, CFRange)? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let field = element as! AXUIElement

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeRef = rangeValue, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return (field, range)
    }

    private static func axCaretRect() -> NSRect? {
        guard let (field, range) = focusedSelection() else { return nil }

        // Bounds of the character just before the caret.
        var charRange = CFRange(location: max(range.location - 1, 0), length: 1)
        guard let charValue = AXValueCreate(.cfRange, &charRange) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         charValue, &boundsValue) == .success,
              let boundsRef = boundsValue else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &bounds), bounds.height > 0 else { return nil }

        // AX uses top-left origin on the primary screen; Cocoa uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: bounds.maxX, y: primaryHeight - bounds.maxY, width: 1, height: bounds.height)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
