import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Marker Cyclop puts on pasteboard writes of its own.
    static let cyclopInternal = NSPasteboard.PasteboardType("com.cyclop.internal")
}

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// Starts as the file-type icon and is replaced by a real preview once
    /// QuickLook renders one — a shelf of identical PNG icons is useless when
    /// what it holds is screenshots.
    var icon: NSImage
    var name: String { url.lastPathComponent }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.url == rhs.url }
}

/// Drop zone contents. Files are referenced, never copied — the shelf is a
/// holding area, so moving the original away simply removes it from the shelf.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    /// Cards picked for a group drag. Empty means "drag whatever is grabbed".
    @Published private(set) var selection: Set<UUID> = []

    private let defaultsKey = "shelf.urls"
    /// Generous, because saved screenshots accumulate here. Cards past the limit
    /// leave the shelf, and their files stay on disk — where, if they are ones
    /// this app saved, the two-week sweep in `ScreenshotVault` eventually takes
    /// them. Files dragged onto the shelf from elsewhere are never touched.
    private let limit = 60
    /// Ceiling on the picture data a copy may carry: past it the file still goes
    /// to the pasteboard, just without its bytes read into memory.
    ///
    /// Guards one case only — a single very large picture. A multi-card copy
    /// carries no picture data at all (see `copy(_ urls:)`), so the sixty-card
    /// selection this once protected against cannot reach here any more.
    private let imageDataBudget = 64 * 1024 * 1024

    func load() {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        items = paths
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ShelfItem(url: $0, icon: NSWorkspace.shared.icon(forFile: $0.path)) }
        items.forEach(loadThumbnail)
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = ShelfItem(url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
            items.insert(item, at: 0)
            loadThumbnail(item)
        }
        if items.count > limit { items.removeLast(items.count - limit) }
        persist()
    }

    private func loadThumbnail(_ item: ShelfItem) {
        // A square box QuickLook fits the content into, whatever its shape.
        // Generous enough that a landscape screenshot still lands above the
        // card's pixel size once it has been fitted.
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 96, height: 96),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            // `nsImage` already carries the right point size for the
            // representation; deriving one from `contentRect` risks describing
            // a shape the bitmap does not have.
            let image = rep.nsImage
            Task { @MainActor in
                guard let self, let index = self.items.firstIndex(where: { $0.url == item.url }) else { return }
                self.items[index].icon = image
            }
        }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
        persist()
    }

    func clear() {
        items.removeAll()
        selection.removeAll()
        persist()
    }

    // MARK: - Selection

    /// Plain click replaces the selection; ⌘ or ⇧ adds to it, matching Finder.
    ///
    /// The pasteboard then mirrors whatever ended up selected, so that picking a
    /// card is the whole gesture — the shelf exists to hand a file onward, and
    /// ⌘C on top of the click would need the panel to hold the keyboard, which
    /// dims the window underneath for as long as it does.
    ///
    /// Mirroring, precisely: a ⌘-click that drops one card of three rewrites the
    /// pasteboard with the remaining two, because a selection on screen that
    /// disagrees with what would be pasted is worse than either. Only clearing
    /// the selection entirely leaves the pasteboard as it was — an empty write
    /// would take back what was copied and hand over nothing.
    ///
    /// A double click passes through here first, with `clickCount == 1`, so
    /// opening a card copies it on the way.
    func select(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        } else if selection == [item.id] {
            selection.removeAll()
        } else {
            selection = [item.id]
        }
        copySelection()
    }

    func isSelected(_ item: ShelfItem) -> Bool { selection.contains(item.id) }

    func clearSelection() { selection.removeAll() }

    /// Files a drag started on `item` should carry: the whole selection when
    /// the grabbed card belongs to it, otherwise just that card.
    func dragURLs(startingAt item: ShelfItem) -> [URL] {
        guard selection.contains(item.id) else { return [item.url] }
        return items.filter { selection.contains($0.id) }.map(\.url)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Puts the card back on the pasteboard. Images go as image data as well as
    /// a file reference, so pasting works both in Finder and in an editor.
    func copy(_ item: ShelfItem) {
        copy([item.url])
    }

    /// The current selection, as one pasteboard write. Empty does nothing at
    /// all — an empty write would clear whatever the pasteboard already held.
    func copySelection() {
        copy(items.filter { selection.contains($0.id) }.map(\.url))
    }

    /// One pasteboard item per file, each carrying the file reference, plus the
    /// paths as plain text.
    ///
    /// Picture bytes go along only when a single card was copied. A reader that
    /// finds an image in the pasteboard takes it and looks no further — Claude
    /// Code in a terminal does exactly that — so attaching a picture to a copy of
    /// several files is what turns "four screenshots" into "the first
    /// screenshot". Left without one, the same reader falls through to the text
    /// below and gets every path; whoever enumerates the items, like Finder or a
    /// messenger, was taking all the files either way.
    private func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let carriesPicture = urls.count == 1
        let items = urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if carriesPicture, let picture = image(of: url) {
                item.setData(picture.data, forType: picture.type)
            }
            return item
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        // Both land on the first item, which is why they are set after the write.
        // The marker tells ClipboardStore the change came from us, so a copied
        // screenshot is not saved to disk a second time.
        pasteboard.setData(Data(), forType: .cyclopInternal)
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Image bytes for the pasteboard, or nothing when the file is not a picture
    /// or is too big to be worth carrying.
    private func image(of url: URL) -> (data: Data, type: NSPasteboard.PasteboardType)? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= imageDataBudget else { return nil }
        // PNG goes as itself; anything else is re-encoded, because handing JPEG
        // bytes over under the TIFF type is a picture nobody can decode.
        if type == .png, let data = try? Data(contentsOf: url) { return (data, .png) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation else { return nil }
        return (tiff, .tiff)
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: defaultsKey)
    }
}
