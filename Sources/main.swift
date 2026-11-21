import Cocoa
import ApplicationServices
import ServiceManagement
import SwiftUI

/// Marks keystrokes we post ourselves so the tap ignores them.
private let syntheticMarker: Int64 = 0x4D41_5448

private enum KeyCode {
    static let a: Int64 = 0
    static let v: Int64 = 9
    static let returnKey: Int64 = 36
    static let enter: Int64 = 76
    static let escape: Int64 = 53
    static let downArrow: Int64 = 125
    static let upArrow: Int64 = 126
    static let tab: Int64 = 48
    static let delete: Int64 = 51
    static let rightArrow: Int64 = 124
    static let arrows: Set<Int64> = [123, 124, 125, 126]
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
    /// The answer for what was just typed.
    private var pendingMatch: Evaluator.Match?
    /// The text before the caret that `pendingMatch` was found in.
    private var matchedText = ""
    /// The answer for highlighted text, while its popup shows.
    private var selectionMatch: Evaluator.Match?
    private lazy var historyPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(rootView: HistoryView(history: .shared))
        host.sizingOptions = .preferredContentSize  // the popover follows the list's height
        popover.contentViewController = host
        return popover
    }()
    private let popup = AnswerPopup()

    // VBA mode
    private let suggestionPopup = SuggestionPopup()
    /// Everything typed in the VBA editor, for editors that don't expose their text.
    private var vbaTyped = ""
    /// Bumped on every keystroke so late suggestions for older text are dropped.
    private var vbaGeneration = 0
    private var vbaModeCache: (isActive: Bool, checked: Date) = (false, .distantPast)
    private let issuePopup = IssuePopup()
    private var grumpiness = Grumpiness()
    /// The line the caret was on at the last check, to notice when a line is finished.
    private var vbaLastLine: Int?
    /// Mistakes already shown, by rule and message, to notice when one gets fixed.
    private var reportedMistakes = Set<String>()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var ratesTimer: Timer?
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

    private var vbaBuiltIn: Bool {
        get { !UserDefaults.standard.bool(forKey: "vbaBuiltInOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "vbaBuiltInOff") }
    }

    private var vbaCheck: Bool {
        get { !UserDefaults.standard.bool(forKey: "vbaCheckOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "vbaCheckOff") }
    }

    private var grumpyMode: Bool {
        get { !UserDefaults.standard.bool(forKey: "grumpyOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "grumpyOff") }
    }

    private var activeInFrontApp: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return true }
        return !disabledApps.contains(id)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "equal.square", accessibilityDescription: "TypeMath")
        loadOptions()
        grumpiness.enabled = grumpyMode
        rebuildMenu()

        Currency.refreshIfNeeded()
        ratesTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in Currency.refreshIfNeeded() }

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
        menu.addItem(.separator())

        menu.addItem(withTitle: "History…", action: #selector(showHistory), keyEquivalent: "").target = self

        let vbaMenu = NSMenu()
        let builtIn = vbaMenu.addItem(withTitle: "Suggestions", action: #selector(toggleVBABuiltIn), keyEquivalent: "")
        builtIn.target = self
        builtIn.state = vbaBuiltIn ? .on : .off
        let check = vbaMenu.addItem(withTitle: "Check My Code", action: #selector(toggleVBACheck), keyEquivalent: "")
        check.target = self
        check.state = vbaCheck ? .on : .off
        let grumpy = vbaMenu.addItem(withTitle: "Grumpy Mode", action: #selector(toggleGrumpy), keyEquivalent: "")
        grumpy.target = self
        grumpy.state = grumpyMode ? .on : .off
        grumpy.isEnabled = vbaCheck
        menu.addItem(withTitle: "VBA Helper", action: nil, keyEquivalent: "").submenu = vbaMenu

        let formatMenu = NSMenu()
        let grouping = formatMenu.addItem(withTitle: "Group Thousands", action: #selector(toggleGrouping), keyEquivalent: "")
        grouping.target = self
        grouping.state = Evaluator.options.groupThousands ? .on : .off
        formatMenu.addItem(.separator())
        for (title, decimals) in [("Automatic Decimals", 0), ("2 Decimals", 2), ("4 Decimals", 4)] {
            let item = formatMenu.addItem(withTitle: title, action: #selector(setDecimals(_:)), keyEquivalent: "")
            item.target = self
            item.tag = decimals
            item.state = (Evaluator.options.decimals ?? 0) == decimals ? .on : .off
        }
        menu.addItem(withTitle: "Number Format", action: nil, keyEquivalent: "").submenu = formatMenu

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
        guard menu === self.menu else { return }
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

    @objc private func showHistory() {
        // Wait for the menu to close, then hang the history panel from the menu bar icon.
        DispatchQueue.main.async { [self] in
            guard let button = statusItem.button else { return }
            NSApp.activate(ignoringOtherApps: true)
            historyPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func toggleGrouping() {
        Evaluator.options.groupThousands.toggle()
        saveOptions()
    }

    @objc private func setDecimals(_ sender: NSMenuItem) {
        Evaluator.options.decimals = sender.tag == 0 ? nil : sender.tag
        saveOptions()
    }

    @objc private func toggleVBABuiltIn() {
        vbaBuiltIn.toggle()
        rebuildMenu()
    }

    @objc private func toggleVBACheck() {
        vbaCheck.toggle()
        issuePopup.hide()
        rebuildMenu()
    }

    @objc private func toggleGrumpy() {
        grumpyMode.toggle()
        grumpiness = Grumpiness()
        grumpiness.enabled = grumpyMode
        rebuildMenu()
    }

    private func loadOptions() {
        let defaults = UserDefaults.standard
        Evaluator.options.groupThousands = defaults.bool(forKey: "groupThousands")
        let decimals = defaults.integer(forKey: "decimals")
        Evaluator.options.decimals = decimals == 0 ? nil : decimals
    }

    private func saveOptions() {
        UserDefaults.standard.set(Evaluator.options.groupThousands, forKey: "groupThousands")
        UserDefaults.standard.set(Evaluator.options.decimals ?? 0, forKey: "decimals")
        rebuildMenu()
    }

    // MARK: Keyboard and mouse tap

    private func startTap() {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
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

        let inVBA = isVBAMode()
        if type == .leftMouseUp {
            if !inVBA { checkSelectionSoon() }  // a drag or double-click may have selected text
            return pass
        }
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
        let isTab = keyCode == KeyCode.tab && modifiers.isEmpty

        if inVBA {
            return handleVBAKey(keyCode: keyCode, typed: typed, isTab: isTab, hasShortcutModifier: hasShortcutModifier)
                ? nil : pass
        }

        if let match = selectionMatch, !hasShortcutModifier {
            selectionMatch = nil
            if isTab {
                if let answer = match.answer {
                    self.type(answer)  // typing over the selection replaces it
                    accept(match)
                    popup.hide()
                } else {
                    popup.copyGraph()
                }
                return nil
            }
            if typed == "=", let answer = match.answer {
                post(virtualKey: UInt16(KeyCode.rightArrow), text: nil)  // keep the selection, add after it
                self.type(" = " + answer)
                accept(match)
                popup.hide()
                return nil
            }
            popup.hide()
        }

        if let match = pendingMatch, !hasShortcutModifier {
            if let answer = match.answer {
                if typed == "=" {
                    fill(answer)
                    accept(match)
                    return nil  // swallow the second "="
                }
                if isTab {
                    replace(length: match.length, with: answer)
                    accept(match)
                    return nil  // swallow the tab
                }
            } else if isTab {
                pendingMatch = nil
                popup.copyGraph()
                return nil
            }
        }

        let selects = (event.flags.contains(.maskShift) && KeyCode.arrows.contains(keyCode))
            || (event.flags.contains(.maskCommand) && keyCode == KeyCode.a)
        if hasShortcutModifier || keyCode == KeyCode.tab || KeyCode.resetting.contains(keyCode) {
            reset()
            if selects { checkSelectionSoon() }
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
            remember(match, equation: String(matchedText.suffix(match.length)))
            popup.show(match, near: CaretLocator.caretRect())
        } else {
            popup.hide()
        }
    }

    // MARK: Selections

    private func checkSelectionSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.checkSelection() }
    }

    private func checkSelection() {
        guard let text = CaretLocator.selectedText(), let match = Evaluator.selectionMatch(text) else { return }
        selectionMatch = match
        pendingMatch = nil
        remember(match, equation: text)
        popup.show(match, near: CaretLocator.caretRect())
    }

    // MARK: Answers

    /// Makes an answer available as "ans" and adds it to History.
    private func remember(_ match: Evaluator.Match, equation: String) {
        guard let answer = match.answer else { return }
        if let value = match.value, !match.usesAns { Evaluator.lastAnswer = value }
        History.shared.add(question: equation, answer: answer)
    }

    /// The user took this answer, so "ans" follows it even if it used "ans" itself.
    private func accept(_ match: Evaluator.Match) {
        if let value = match.value { Evaluator.lastAnswer = value }
    }

    private func reset() {
        buffer = ""
        pendingMatch = nil
        selectionMatch = nil
        popup.hide()
        issuePopup.hide()
        cancelVBASuggestions()
    }

    // MARK: VBA mode

    /// Whether the VBA editor is in front. Cached briefly, since every keystroke asks.
    private func isVBAMode() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == VBAContext.excelBundleID else { return false }
        if Date().timeIntervalSince(vbaModeCache.checked) > 0.5 {
            vbaModeCache = (VBAContext.isCodeWindow(), Date())
        }
        return vbaModeCache.isActive
    }

    /// Handles a key in the VBA editor; returns true to swallow it.
    private func handleVBAKey(keyCode: Int64, typed: String, isTab: Bool, hasShortcutModifier: Bool) -> Bool {
        pendingMatch = nil  // no maths in code: "=" is assignment there
        popup.hide()
        issuePopup.hide()

        if suggestionPopup.isVisible, !hasShortcutModifier {
            switch keyCode {
            case KeyCode.tab where isTab:
                if let suggestion = suggestionPopup.selectedSuggestion { insert(suggestion) }
                return true
            case KeyCode.downArrow:
                suggestionPopup.move(by: 1)
                return true
            case KeyCode.upArrow:
                suggestionPopup.move(by: -1)
                return true
            case KeyCode.escape:
                cancelVBASuggestions()
                return true
            default:
                break
            }
        }
        cancelVBASuggestions()
        if hasShortcutModifier { return false }

        if keyCode == KeyCode.delete {
            if !vbaTyped.isEmpty { vbaTyped.removeLast() }
        } else if keyCode == KeyCode.returnKey || keyCode == KeyCode.enter {
            vbaTyped += "\n"
        } else if !typed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            vbaTyped += typed
        }
        if vbaTyped.count > 4000 { vbaTyped = String(vbaTyped.suffix(4000)) }

        let generation = vbaGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in self?.updateVBA(generation: generation) }
        return false
    }

    private func cancelVBASuggestions() {
        vbaGeneration += 1
        suggestionPopup.hide()
    }

    private func updateVBA(generation: Int) {
        guard generation == vbaGeneration else { return }
        let shared = VBAContext.moduleAndCaret()
        let (module, caret) = shared ?? (vbaTyped, vbaTyped.count)
        checkFinishedLine(module: module, caret: caret, knowsLines: shared != nil)
        let builtIn = vbaBuiltIn ? VBASuggestions.suggest(module: module, caret: caret) : []
        if builtIn.isEmpty { suggestionPopup.hide() } else { suggestionPopup.show(builtIn, near: CaretLocator.caretRect()) }
    }

    /// When the caret has moved to another line, checks the line it left and lets the helper react.
    private func checkFinishedLine(module: String, caret: Int, knowsLines: Bool) {
        let line = module.prefix(caret).filter { $0 == "\n" }.count + 1
        defer { vbaLastLine = line }
        guard vbaCheck, let finished = vbaLastLine, finished != line else { return }

        let issues = VBALinter.lint(module)
        let mistakes = Set(issues.filter { $0.kind == .mistake }.map { "\($0.key)|\($0.message)" })
        let fixed = !reportedMistakes.subtracting(mistakes).isEmpty
        reportedMistakes.formIntersection(mistakes)

        let issue = issues.first { $0.line == finished && $0.kind == .mistake } ?? issues.first { $0.line == finished }
        if let issue, issue.kind == .mistake { reportedMistakes.insert("\(issue.key)|\(issue.message)") }
        var reaction = grumpiness.lineFinished(with: issue, at: Date(), showLine: knowsLines)
        if reaction == nil, fixed { reaction = grumpiness.mistakeFixed(at: Date()) }
        if let reaction { issuePopup.show(reaction, near: CaretLocator.caretRect()) }
    }

    /// Replaces what the suggestion covers and inserts it. Multi-line code is pasted, so the editor's
    /// auto-indent and syntax checks don't act on each typed line break.
    private func insert(_ suggestion: VBASuggestion) {
        cancelVBASuggestions()
        for _ in 0..<suggestion.replacing { post(virtualKey: UInt16(KeyCode.delete), text: nil) }
        if suggestion.text.contains("\n") {
            paste(suggestion.text)
        } else {
            type(suggestion.text)
        }
        vbaTyped = String(vbaTyped.dropLast(suggestion.replacing)) + suggestion.text
    }

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        post(virtualKey: UInt16(KeyCode.v), text: nil, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {  // put the user's clipboard back
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    /// "=" again: types the answer after the equation, matching the spacing around "=" or "?".
    private func fill(_ answer: String) {
        var text = answer
        let joinsDirectly = matchedText.hasSuffix(" ")
            || (matchedText.hasSuffix("=") && !matchedText.dropLast().hasSuffix(" "))  // "4*4=" -> "4*4=16"
        if !joinsDirectly { text = " " + text }
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

    private func post(virtualKey: UInt16, text: [UniChar]?, flags: CGEventFlags = []) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: keyDown) else { continue }
            event.flags = flags
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

    /// The highlighted text in the focused field, if the app exposes it and it is short.
    static func selectedText() -> String? {
        guard let (field, range) = focusedSelection(), range.length > 0, range.length <= 200 else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextAttribute as CFString, &result) == .success
        else { return nil }
        return result as? String
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

        // Bounds of the character just before the caret, or the last selected character.
        var charRange = CFRange(location: max(range.location + range.length - 1, 0), length: 1)
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
