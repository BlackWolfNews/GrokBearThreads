import Foundation

/// Pictures dropped from a temp folder, copied somewhere they'll stay.
///
/// Dragging a screenshot's floating thumbnail hands over a file in
/// `.../T/TemporaryItems/NSIRD_screencaptureui_*`, and macOS deletes it as
/// the drop ends: by the time the runner's `media.import` reads it, it's
/// gone, and that showed as "Not a supported image" (issue #2). Copying it
/// during the drop, in the app, keeps it.
public enum DroppedFiles {
    /// Where the composer keeps its own copies (pasted image data goes
    /// here too).
    public static var keepFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("threadbear-paste", isDirectory: true)
    }

    /// Whether `url` is in a temp folder that may be cleared under us,
    /// other than the composer's own.
    public static func isTransient(_ url: URL, temp: URL = FileManager.default.temporaryDirectory, keep: URL = keepFolder) -> Bool {
        let path = canonical(url.path)
        if path.hasPrefix(canonical(keep.path) + "/") { return false }
        return path.hasPrefix("/var/folders/")
            || path.contains("/TemporaryItems/")
            || path.hasPrefix(canonical(temp.path) + "/")
    }

    /// `urls` with each transient one swapped for a copy under `folder`,
    /// keeping its name (the runner's messages name the file). One that
    /// can't be copied is passed on as it was, for the runner to explain.
    public static func keepingTransient(_ urls: [URL], temp: URL = FileManager.default.temporaryDirectory, into folder: URL = keepFolder) -> [URL] {
        urls.map { url in
            guard isTransient(url, temp: temp, keep: folder) else { return url }
            let dir = folder.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
            let copy = dir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: copy)
                return copy
            } catch {
                try? FileManager.default.removeItem(at: dir)
                return url
            }
        }
    }

    /// Whether `url` is inside a Photos library. Copying a photo in Photos
    /// puts such a file on the clipboard, which only apps with Photos
    /// access can read, alongside the image itself.
    public static func isInPhotosLibrary(_ url: URL) -> Bool {
        url.path.contains(".photoslibrary/")
    }

    /// Writes image data from the clipboard to a folder of its own under
    /// `folder`, as `name`. Nil if it couldn't be written.
    public static func save(_ data: Data, named name: String, into folder: URL = keepFolder) -> URL? {
        let dir = folder.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// `/private/var/...` and `/var/...` are the same folder.
    private static func canonical(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }
}
