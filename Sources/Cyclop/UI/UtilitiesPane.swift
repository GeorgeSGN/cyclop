import SwiftUI

/// One button across the whole pane. Deliberately not a list of one: a row
/// layout built for items that do not exist yet would have to be guessed now and
/// redone later anyway, and redoing the inside of a pane is cheap.
struct UtilitiesPane: View {
    @ObservedObject var lock: KeyboardLock

    /// Why the last press did not lock, if it did not. The system permission
    /// dialog is never the first thing that happens: being asked for
    /// Accessibility out of nowhere is indistinguishable from something helping
    /// itself to the input.
    @State private var refusal: KeyboardLock.Refusal?

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
        .onAppear { refusal = nil }
    }

    private var title: String {
        switch refusal {
        case nil: return localized("Lock Keyboard")
        case .noAccess: return localized("Allow in Settings")
        case .secureInput: return localized("Input is protected")
        case .tapFailed: return localized("Could not take over input")
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
        }
    }

    private func press() {
        // A second press on an explained refusal is the way to Settings: for a
        // missing permission because that is where it is granted, and for a
        // failed tap because a rebuilt app is a new signature to TCC and the
        // stale entry has to be replaced by hand.
        if let refusal, refusal == .noAccess || refusal == .tapFailed {
            lock.openSettings()
            return
        }

        refusal = lock.lock()
        // The system dialog comes with the explanation, not before it.
        if refusal == .noAccess { lock.requestAccess() }
    }
}
