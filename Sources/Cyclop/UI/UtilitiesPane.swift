import SwiftUI

/// One button across the whole pane. Deliberately not a list of one: a row
/// layout built for items that do not exist yet would have to be guessed now and
/// redone later anyway, and redoing the inside of a pane is cheap.
struct UtilitiesPane: View {
    @ObservedObject var lock: KeyboardLock

    /// Read from the lock rather than kept here: one of the reasons — secure
    /// input coming up mid-wipe — is raised by a timer with no press behind it,
    /// and a copy in the view would never hear about it.
    private var refusal: KeyboardLock.Refusal? { lock.lastRefusal }

    var body: some View {
        Button {
            press()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: refusal == nil ? "keyboard" : "hand.raised.fill")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(refusal == nil ? .white : Color.white.opacity(0.75))

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)

                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.contentAnimation, value: refusal)
        // Coming back to the tab drops the explanation: the permission may well
        // have been granted in between, and the pane should not still be asking.
        .onAppear { lock.clearRefusal() }
    }

    private var title: String {
        switch refusal {
        case nil: return localized("Lock Keyboard")
        case .noAccess: return localized("Allow in Settings")
        case .secureInput: return localized("Input is protected")
        case .tapFailed: return localized("Could not take over input")
        case .busy: return localized("Still unlocking")
        }
    }

    private var caption: String {
        switch refusal {
        case nil:
            return localized("Wipe the keys and the screen. Hold Esc or − for three\nseconds to unlock; it also unlocks by itself after a minute")
        case .noAccess:
            return localized("Cyclop needs Accessibility to swallow keys and clicks.\nSystem Settings → Privacy & Security → Accessibility")
        case .secureInput:
            return localized("An app is holding secure keyboard entry — a password field,\na password manager, a terminal. Close it and press again")
        case .tapFailed:
            return localized("The system refused the event tap. Re-granting Accessibility\nusually fixes it — the permission is tied to the app's signature")
        case .busy:
            return localized("The previous lock is still being taken down.\nPress again in a moment")
        }
    }

    private func press() {
        // A second press on an explained refusal is the way to Settings: for a
        // missing permission because that is where it is granted, and for a
        // failed tap because a rebuilt app is a new signature to TCC and the
        // stale entry has to be replaced by hand. The other two reasons pass
        // through to another attempt — that is what they are waiting for.
        if let refusal, refusal == .noAccess || refusal == .tapFailed {
            lock.openSettings()
            return
        }

        // The system dialog comes with the explanation, not before it.
        if lock.lock() == .noAccess { lock.requestAccess() }
    }
}
