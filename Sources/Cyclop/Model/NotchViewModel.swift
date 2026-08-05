import AppKit
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case shelf, clipboard, snippets, translate
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .shelf: return "tray.full.fill"
            case .clipboard: return "list.clipboard.fill"
            case .snippets: return "pin.fill"
            case .translate: return "translate"
            }
        }

        var title: String {
            switch self {
            case .shelf: return localized("Shelf")
            case .clipboard: return localized("Clipboard")
            case .snippets: return localized("Snippets")
            case .translate: return localized("Translate")
            }
        }

        /// Tabs with a field in them. Landing on one hands it the keyboard, so
        /// that arriving and typing is a single move.
        var needsKeyboard: Bool { self == .translate || self == .snippets }

        /// Icons the rail carries, in order. Four fit the panel height with
        /// room to spare — the upstream app needed a second rail on the right
        /// only because it carried seven.
        static let rail: [Tab] = allCases
    }

    @Published var isOpen = false
    @Published var isDropTargeted = false
    @Published var tab: Tab = .shelf {
        didSet {
            // The snippets file is edited from outside the app, so it is read
            // on the way in rather than held from launch.
            if tab == .snippets { snippets.reload() }
            // Leaving the tab that types gives the keyboard straight back.
            if !tab.needsKeyboard { wantsKeyboard = false }
        }
    }

    /// Whether the panel currently holds the keyboard.
    ///
    /// Tracked apart from `tab` because the two come apart in one direction:
    /// clicking into another app drops the claim without changing which tab is
    /// showing, so the text one was typing survives and the panel is free to
    /// collapse. Landing on a tab that types always raises it again — there is
    /// no such thing as a panel that shows a field but cannot receive a key.
    @Published var wantsKeyboard = false

    let geometry: NotchGeometry
    let shelf: ShelfStore
    let clipboard: ClipboardStore
    let translator: Translator
    let snippets: SnippetStore

    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        self.shelf = ShelfStore()
        self.clipboard = ClipboardStore()
        self.translator = Translator()
        self.snippets = SnippetStore()

        // The panel header reads through to the stores — the counters. Nested
        // ObservableObjects do not propagate on their own, so those would only
        // refresh when something else happened to redraw the view.
        //
        // Forwarded only while the panel is open. Collapsed, there is nothing
        // these redraws could change — the panel is a black shape — yet the
        // stores keep their own schedule: a copy whenever one happens, and each
        // send re-evaluated the whole view for nobody. Opening repaints from the
        // stores directly, because `isOpen` is itself @Published and its own
        // send does that.
        //
        // The stores with a text field in their pane — the translator and the
        // snippets — are deliberately absent. They change on every keystroke,
        // and redrawing the whole panel per letter costs more than a stale
        // counter: it rebuilds the field, which drops the focus, so the first
        // letter typed is also the last one that lands. Their panes observe
        // them directly, and the header counter refreshes anyway, because the
        // list is only ever re-read on the way into the tab.
        for child in [
            shelf.objectWillChange,
            clipboard.objectWillChange,
        ] {
            child
                .sink { [weak self] _ in
                    guard let self, self.isOpen || self.isDropTargeted else { return }
                    self.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
    }

    /// Size of the visible body for the current state.
    var bodySize: CGSize {
        isOpen || isDropTargeted ? geometry.expandedSize : geometry.notchSize
    }

    /// Off switch for people who copy images all day and do not want them kept.
    static let saveClipboardImagesKey = "saveClipboardImages"

    /// Defaults to on: the feature is the reason the folder exists.
    static var saveClipboardImagesEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: saveClipboardImagesKey) != nil else { return true }
        return defaults.bool(forKey: saveClipboardImagesKey)
    }

    /// Hover and click both land here. A tab that types takes the keyboard
    /// either way: showing a field one cannot type into is worse than briefly
    /// dimming the caret of the window underneath, and the dwell threshold on
    /// the rail already keeps a passing pointer from arriving here at all.
    func select(_ tab: Tab) {
        self.tab = tab
        if tab.needsKeyboard { wantsKeyboard = true }
    }

    func start() {
        shelf.load()
        snippets.reload()

        // Screenshots reach the shelf through here whether they were taken on
        // this Mac or on a phone: a copy made on the phone arrives in the same
        // pasteboard, carried over by Continuity.
        //
        // The switch is asked by the store before it touches image data, not
        // here after the fact: turned off, a copied picture used to be encoded
        // to PNG in full just to be dropped on this doorstep — pure heat on
        // exactly the machines whose owners turned the feature off.
        clipboard.wantsImages = { Self.saveClipboardImagesEnabled }
        clipboard.onImage = { [weak self] png in
            guard let self, let url = ScreenshotVault.save(png) else { return }
            self.shelf.add([url])
            self.tab = .shelf
        }
        clipboard.start()
    }

    func stop() {
        clipboard.stop()
    }

    func accept(urls: [URL]) -> Bool {
        shelf.add(urls)
        tab = .shelf
        return true
    }
}
