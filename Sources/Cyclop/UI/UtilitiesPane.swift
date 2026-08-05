import SwiftUI

/// One button across the whole pane. Deliberately not a list of one: a row
/// layout built for items that do not exist yet would have to be guessed now and
/// redone later anyway, and redoing the inside of a pane is cheap.
struct UtilitiesPane: View {
    @ObservedObject var lock: KeyboardLock

    /// Raised by a press with no permission granted. The system dialog is never
    /// the first thing that happens: being asked for Accessibility out of
    /// nowhere is indistinguishable from something helping itself to the input.
    @State private var explainsAccess = false

    var body: some View {
        Button {
            press()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: explainsAccess ? "hand.raised.fill" : "keyboard")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(explainsAccess ? Color.white.opacity(0.75) : .white)

                Text(explainsAccess ? localized("Allow in Settings") : localized("Lock Keyboard"))
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
        .animation(Theme.contentAnimation, value: explainsAccess)
        // Coming back to the tab drops the explanation: the permission may well
        // have been granted in between, and the pane should not still be asking.
        .onAppear { explainsAccess = false }
    }

    private var caption: String {
        explainsAccess
            ? localized("Cyclop needs Accessibility to swallow keys and clicks.\nSystem Settings → Privacy & Security → Accessibility")
            : localized("Wipe the keys and the screen. Hold Esc or − for three\nseconds to unlock; it also unlocks by itself after a minute")
    }

    private func press() {
        guard lock.hasAccess else {
            // First press explains and asks; a second one, still without the
            // permission, opens the pane in Settings where it is granted.
            if explainsAccess {
                lock.openSettings()
            } else {
                explainsAccess = true
                lock.requestAccess()
            }
            return
        }
        explainsAccess = false
        lock.lock()
    }
}
