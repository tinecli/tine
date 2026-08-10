import ApplicationServices
import Foundation

/// Both notifications are required: tab-per-window terminals only fire the window one, single-window terminals only the element one.
final class AXFocusWatcher {
    let pid: pid_t
    private let observer: AXObserver
    private let onFocusChange: () -> Void

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
