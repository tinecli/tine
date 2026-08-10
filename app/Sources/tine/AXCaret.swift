import AppKit
import ApplicationServices

enum AXCaret {
    static func ensureTrusted() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Returns Cocoa coords (bottom-left origin), paired with line height so SuggestionPanel
    /// can flip above the caret near the screen bottom.
    static func caretTopLeftBelow(gap: CGFloat = 4) -> (point: NSPoint, lineHeight: CGFloat)? {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let system = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        let fErr = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard fErr == .success, let focusedRef = focused else {
            tlog("AX[\(app)] focusedElement FAILED err=\(fErr.rawValue)")
            return nil
        }
        let element = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        let rErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard rErr == .success, let rangeVal = rangeRef else {
            tlog("AX[\(app)] selectedRange FAILED err=\(rErr.rawValue)")
            return nil
        }

        var caret = CFRange(location: 0, length: 0)
        AXValueGetValue(rangeVal as! AXValue, .cfRange, &caret)

        // Three probes, in order: the caret range itself (iTerm2); if that's empty/zero-height
        // (Terminal.app), the character before the caret, anchored to its right edge;
        // otherwise the character after the caret.
        var anchorRight = false
        var rect = bounds(element, CFRange(location: caret.location, length: 0))
        if !valid(rect) && caret.location > 0 {
            rect = bounds(element, CFRange(location: caret.location - 1, length: 1))
            anchorRight = true
        }
        if !valid(rect) {
            rect = bounds(element, CFRange(location: caret.location, length: 1))
            anchorRight = false
        }
        // Canvas/Electron terminals (VSCode) refuse boundsForRange, but xterm.js's hidden
        // IME field tracks the cursor cell-by-cell, so its own frame *is* the caret.
        if !valid(rect), let er = caretSizedElementRect(element) {
            rect = er
            anchorRight = false
        }
        guard let r = rect, valid(r) else {
            tlog("AX[\(app)] no valid bounds for caret \(caret)")
            return nil
        }

        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let anchorX = anchorRight ? r.maxX : r.minX
        let caretBottomCocoaY = primaryHeight - (r.origin.y + r.height)
        let point = NSPoint(x: anchorX, y: caretBottomCocoaY - gap)

        tlog("AX[\(app)] caret=\(caret) rect=\(r) anchorRight=\(anchorRight) -> \(point)")
        return (point, r.height)
    }

    // A caret-tracking field (VSCode/xterm.js) is a few points wide; a whole terminal
    // canvas (Ghostty) is hundreds — the 100pt cap below tells them apart.
    private static func caretSizedElementRect(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, szRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &szRef) == .success,
              let p = posRef, let s = szRef else { return nil }
        var pos = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        guard sz.width > 0, sz.height > 0, sz.width < 100, sz.height < 100 else { return nil }
        return CGRect(origin: pos, size: sz)
    }

    /// Screen coords, top-left origin — unlike `caretTopLeftBelow`'s Cocoa coords. For a
    /// canvas terminal (Ghostty) this is the whole text area, which the caller turns into
    /// a per-cell pixel position using the grid it already has.
    static func focusedElementRect() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        var posRef: CFTypeRef?, szRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSizeAttribute as CFString, &szRef) == .success,
              let p = posRef, let s = szRef else { return nil }
        var pos = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        guard sz.width > 0, sz.height > 0 else { return nil }
        return CGRect(origin: pos, size: sz)
    }

    private static func valid(_ rect: CGRect?) -> Bool {
        guard let r = rect else { return false }
        return r.origin.x.isFinite && r.origin.y.isFinite && r.height > 0
    }

    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var r = range
        guard let value = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &out) == .success,
              let boundsVal = out else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsVal as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
