import Cocoa
import ApplicationServices

/// Finds out whether the user is in Excel's VBA editor, and reads the module being edited.
enum VBAContext {
    static let excelBundleID = "com.microsoft.Excel"

    /// Whether the focused window is a VBA code window ("Book1 - Module1 (Code)" or the Visual Basic editor).
    static func isCodeWindow() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == excelBundleID,
              let title = focusedWindowTitle(pid: app.processIdentifier) else { return false }
        return title.contains("(Code)") || title.localizedCaseInsensitiveContains("Visual Basic")
    }

    /// The whole module text and the caret as a character offset, if the editor exposes them.
    static func moduleAndCaret() -> (text: String, caret: Int)? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let field = element as! AXUIElement

        var value: CFTypeRef?, rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeRef = rangeValue, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length == 0 else { return nil }

        // Accessibility counts UTF-16 units; the suggestion engine counts characters.
        let utf16 = text.utf16
        guard range.location <= utf16.count,
              let index = utf16.index(utf16.startIndex, offsetBy: range.location, limitedBy: utf16.endIndex)
        else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let caret = String(text[..<index]).replacingOccurrences(of: "\r\n", with: "\n").count
        return (normalized, caret)
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let windowRef = window, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }
}
