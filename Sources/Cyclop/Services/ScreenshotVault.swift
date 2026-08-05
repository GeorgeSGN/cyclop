import AppKit

/// Where clipboard screenshots are kept.
///
/// A screenshot taken to the clipboard exists only in memory: paste it once and
/// it is gone. The vault writes it to disk so the shelf can hold on to it.
/// Nothing here is ever deleted automatically — the folder is the user's.
enum ScreenshotVault {
    /// `~/Pictures/Cyclop` when it can be created — it is findable, and unlike
    /// Desktop or Documents it is not behind a TCC prompt. Falls back to the
    /// app's own support folder, which always works.
    static let folder: URL = {
        let fm = FileManager.default
        let pictures = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Cyclop", isDirectory: true)
        if (try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)) != nil {
            return pictures
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cyclop", isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = localized("yyyy-MM-dd 'at' HH.mm.ss")
        return formatter
    }()

    static func save(_ png: Data, at date: Date = Date()) -> URL? {
        let base = "\(localized("Screenshot")) \(stamp.string(from: date))"
        var url = folder.appendingPathComponent("\(base).png")
        // Two screenshots inside one second would otherwise collide.
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(attempt)).png")
            attempt += 1
        }
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("Cyclop: failed to save image: \(error.localizedDescription)")
            return nil
        }
    }

    static func reveal() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    /// What the folder holds right now — for the menu item that offers to
    /// clear it, so the offer names its price.
    static func usage() -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        let bytes = urls.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (urls.count, bytes)
    }

    /// How long a screenshot is kept before the sweep takes it.
    static let retention: TimeInterval = 14 * 24 * 60 * 60

    /// Deletes screenshots past `retention`, for good rather than to the Trash:
    /// what lands here is a throwaway copy of something that was on the
    /// clipboard, and a Trash slowly filling with those is the same problem one
    /// folder further along. Returns how many went, so the caller can refresh
    /// the shelf only when something actually changed.
    ///
    /// Cards on the shelf are no exception — two weeks means two weeks, or the
    /// shelf quietly becomes the permanent storage this sweep exists to prevent.
    /// Files dragged onto the shelf from anywhere else are untouched: only this
    /// folder is ever swept.
    static func prune(now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for url in urls {
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
                now.timeIntervalSince(modified) > retention else { continue }
            do {
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                NSLog("Cyclop: failed to sweep \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return removed
    }

    /// To the Trash, not gone. This one is the user's own hand on a menu item,
    /// and a deliberate press deserves to stay reversible — unlike the sweep
    /// above, which nobody asked for at the moment it runs.
    static func clear() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
    }
}
