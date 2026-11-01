import Foundation
import os

/// One photo's copy in file storage, started the moment the photo's picked
/// so that Send usually has nothing left to wait for.
///
/// That means uploading photos that might never be sent, and the backend only
/// deletes a photo once a command that carried it has finished. So this owns
/// its copy until `keep()`: dropped before then (the photo's taken out of the
/// composer, or the composer goes away), it stops the upload and takes the
/// copy back, wherever the dropping happened. A photo left behind by the app
/// being killed before that stays in storage.
public final class PhotoUpload: Sendable {
    private let task: Task<String, Error>
    private let discard: @Sendable (String) async -> Void
    private let kept = OSAllocatedUnfairLock(initialState: false)

    public init(upload: @escaping @Sendable () async throws -> String, discard: @escaping @Sendable (String) async -> Void) {
        task = Task(priority: .userInitiated) { try await upload() }
        self.discard = discard
    }

    public var storageId: String {
        get async throws { try await task.value }
    }

    /// It's gone with a message, so it's the backend's to delete from here.
    public func keep() {
        kept.withLock { $0 = true }
    }

    deinit {
        guard !kept.withLock({ $0 }) else { return }
        task.cancel()
        Task { [task, discard] in
            if let id = try? await task.value { await discard(id) }
        }
    }
}
