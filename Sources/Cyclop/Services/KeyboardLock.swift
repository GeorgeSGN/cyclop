import AppKit
import ApplicationServices

/// Swallows every input event so the keyboard and trackpad can be wiped.
///
/// The only mechanism that can actually stop an event from reaching the system
/// is a `CGEventTap` in its default, non-listening mode — and that one is gated
/// behind the Accessibility permission. Anything cheaper only steals the focus:
/// the app would look locked while ⌘Q, ⌘Tab and the brightness keys still went
/// through, which is worse than not offering the feature, because a cloth is
/// trusted against a promise that does not hold.
@MainActor
final class KeyboardLock: ObservableObject {
    @Published private(set) var isLocked = false
    /// How far into the three-second hold the release key is, 0…1.
    @Published private(set) var holdProgress: Double = 0
    /// Seconds before the lock lifts on its own.
    @Published private(set) var secondsLeft = Int(autoRelease)

    /// Never configurable. It is the one way out that does not depend on the
    /// user, the app or the tap still working correctly.
    static let autoRelease: TimeInterval = 60
    static let holdToRelease: TimeInterval = 3

    /// Physical keys, matched by code rather than character: a Cyrillic layout
    /// prints something else entirely, and the way out must not depend on which
    /// layout happened to be active when the cloth came out.
    private enum Key {
        static let escape: Int64 = 53
        static let minus: Int64 = 27
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var ticker: Timer?
    private var lockedAt: Date?
    private var holdStartedAt: Date?

    /// Whether the Accessibility permission is granted. Read every time rather
    /// than cached: it is granted in System Settings, outside this app, and a
    /// cached "no" would outlive the granting by a whole launch.
    var hasAccess: Bool { AXIsProcessTrusted() }

    /// Raises the system's own permission dialog. Called from the pane's second
    /// press, after the explanation — the first press is what asks for it.
    func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lock

    @discardableResult
    func lock() -> Bool {
        guard !isLocked, hasAccess else { return false }

        // Everything, not a hand-picked list: the point is that nothing gets
        // through, and a list is a promise to have remembered every event type
        // macOS has — including the ones it gains later.
        let mask = ~CGEventMask(0)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let lock = Unmanaged<KeyboardLock>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated { lock.handle(type, event) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        lockedAt = Date()
        holdStartedAt = nil
        holdProgress = 0
        secondsLeft = Int(Self.autoRelease)
        isLocked = true
        startTicker()
        return true
    }

    func unlock() {
        guard isLocked else { return }
        ticker?.invalidate()
        ticker = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        lockedAt = nil
        holdStartedAt = nil
        holdProgress = 0
        isLocked = false
    }

    // MARK: - Events

    /// Returns `nil` for everything, which is what discards the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a tap off if its callback ever takes too long, and says
        // so through these two. Re-enabling is the difference between a lock
        // that recovers and one that silently stopped locking.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let isReleaseKey = code == Key.escape || code == Key.minus
        switch type {
        case .keyDown where isReleaseKey:
            // Auto-repeat fires keyDown over and over while the key is held, so
            // the start is only recorded once — otherwise the hold would reset
            // itself every repeat and never complete.
            if holdStartedAt == nil { holdStartedAt = Date() }
        case .keyUp where isReleaseKey:
            holdStartedAt = nil
            holdProgress = 0
        case .keyDown, .keyUp:
            // Some other key: an accidental press under the cloth, and the one
            // in-progress hold it must not credit.
            holdStartedAt = nil
            holdProgress = 0
        default:
            break
        }
        return nil
    }

    private func startTicker() {
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard isLocked, let lockedAt else { return }
        let now = Date()

        if let holdStartedAt {
            let held = now.timeIntervalSince(holdStartedAt)
            holdProgress = min(1, held / Self.holdToRelease)
            if held >= Self.holdToRelease {
                unlock()
                return
            }
        }

        let elapsed = now.timeIntervalSince(lockedAt)
        secondsLeft = max(0, Int((Self.autoRelease - elapsed).rounded(.up)))
        if elapsed >= Self.autoRelease { unlock() }
    }
}
