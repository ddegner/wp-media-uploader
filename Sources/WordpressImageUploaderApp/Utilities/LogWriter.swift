import Foundation

final class LogWriter: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<Void>()

    private let queue = DispatchQueue(label: "WPMediaUploader.LogWriter")
    private var handle: FileHandle?

    init(fileURL: URL) {
        queue.setSpecific(key: Self.queueKey, value: ())

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        self.handle = try? FileHandle(forWritingTo: fileURL)
        if let handle = self.handle {
            do {
                _ = try handle.seekToEnd()
            } catch {
                print("Failed to seek log file: \(error)")
            }
        }
    }

    deinit {
        let closeHandle = {
            guard let handle = self.handle else { return }
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                // Best-effort close; nothing to do on failure.
            }
        }

        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            closeHandle()
        } else {
            queue.sync(execute: closeHandle)
        }
    }

    func append(_ line: String) {
        queue.async { [self] in
            let timestamp = Date.now.formatted(.iso8601)
            let payload = "[\(timestamp)] \(line)\n"
            guard let data = payload.data(using: .utf8) else { return }

            guard let handle = self.handle else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                print("Failed to write log: \(error)")
            }
        }
    }

    func flush() {
        guard DispatchQueue.getSpecific(key: Self.queueKey) == nil else { return }
        queue.sync {}
    }
}
