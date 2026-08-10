import AppKit
import SwiftUI

final class SuggestionPanel: NSPanel {
    private let state: AppState
    private var rowHeight: CGFloat { CGFloat(state.config.fontSize) + 12 }

    init(state: AppState) {
        self.state = state
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: SuggestionListView.listWidth, height: 24),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: SuggestionListView().environmentObject(state))
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `origin` is the panel's top-left in Cocoa coords (y grows upward), `gap` below the caret.
    func present(at origin: CGPoint, lineHeight: CGFloat, gap: CGFloat = 4) {
        let size = SuggestionListView.panelSize(rows: state.suggestions.count, config: state.config)
        setContentSize(size)

        var o = origin
        if let vf = (NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main)?.visibleFrame {
            o.x = min(max(o.x, vf.minX), max(vf.minX, vf.maxX - size.width))
            if o.y - size.height < vf.minY {
                o.y = origin.y + gap + lineHeight + gap + size.height
            }
            o.y = min(o.y, vf.maxY)
        }
        setFrameTopLeftPoint(o)
        orderFrontRegardless()
    }

    func relayout() {
        guard isVisible else { return }
        present(at: CGPoint(x: frame.minX, y: frame.maxY), lineHeight: rowHeight)
    }

    func hidePanel() { orderOut(nil) }
}
