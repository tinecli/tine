import ApplicationServices
import Foundation

/// Reports when one application moves its Accessibility focus — a different
/// window, tab or split. Terminals differ: Ghostty and Canario give each tab its
/// own window, Terminal.app and iTerm2 keep one window and swap the focused
/// element, so both notifications are observed.
final class AXFocusWatcher {
    let pid: pid_t
    private let observer: AXObserver
    private let onFocusChange: () -> Void

    /// Fails when the app is gone or Accessibility is not trusted; the caller then
    /// runs without focus events rather than prompting.
    init?(pid: pid_t, onFocusChange: @escaping () -> Void) {
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<AXFocusWatcher>.fromOpaque(refcon).takeUnretainedValue().onFocusChange()
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else {
            return nil
        }
        self.pid = pid
        self.observer = observer
        self.onFocusChange = onFocusChange

        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
