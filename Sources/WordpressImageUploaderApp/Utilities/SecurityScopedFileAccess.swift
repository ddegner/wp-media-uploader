import Foundation

enum SecurityScopedFileAccessError: LocalizedError {
    case missingFile(path: String, purpose: String)
    case unresolvedBookmark(path: String, purpose: String, detail: String)
    case denied(path: String, purpose: String)

    var errorDescription: String? {
        switch self {
        case let .missingFile(path, purpose):
            return "\(purpose) is no longer available at \(path). Reselect or re-add it."
        case let .unresolvedBookmark(path, purpose, detail):
            return "\(purpose) access could not be restored for \(path). Reselect or re-add it. (\(detail))"
        case let .denied(path, purpose):
            return "\(purpose) access was denied for \(path). Reselect or re-add it."
        }
    }
}

final class SecurityScopedFileAccess: @unchecked Sendable {
    let url: URL

    private let didStartAccessing: Bool
    private let lock = NSLock()
    private var isStopped = false

    private init(url: URL, didStartAccessing: Bool) {
        self.url = url
        self.didStartAccessing = didStartAccessing
    }

    deinit {
        stop()
    }

    static func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func start(url: URL, bookmarkData: Data?, purpose: String) throws -> SecurityScopedFileAccess {
        try start(path: url.path, bookmarkData: bookmarkData, purpose: purpose)
    }

    static func start(path: String, bookmarkData: Data?, purpose: String) throws -> SecurityScopedFileAccess {
        if let bookmarkData {
            do {
                var isStale = false
                let resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let didStart = resolvedURL.startAccessingSecurityScopedResource()
                guard didStart || FileManager.default.isReadableFile(atPath: resolvedURL.path) else {
                    throw SecurityScopedFileAccessError.denied(path: resolvedURL.path, purpose: purpose)
                }
                return SecurityScopedFileAccess(url: resolvedURL, didStartAccessing: didStart)
            } catch let accessError as SecurityScopedFileAccessError {
                throw accessError
            } catch {
                throw SecurityScopedFileAccessError.unresolvedBookmark(
                    path: path,
                    purpose: purpose,
                    detail: error.localizedDescription
                )
            }
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw SecurityScopedFileAccessError.missingFile(path: path, purpose: purpose)
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw SecurityScopedFileAccessError.denied(path: path, purpose: purpose)
        }
        return SecurityScopedFileAccess(url: URL(fileURLWithPath: path), didStartAccessing: false)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard !isStopped else { return }
        isStopped = true
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
