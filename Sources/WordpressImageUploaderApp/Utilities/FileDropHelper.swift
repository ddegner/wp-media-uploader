import AppKit
import Foundation
import UniformTypeIdentifiers

func resolveImageFileURLs(from urls: [URL]) -> [URL] {
    var collected: [URL] = []

    for url in urls {
        collected.append(contentsOf: imageFiles(from: url))
    }

    var seenPaths = Set<String>()
    var uniqueURLs: [URL] = []
    for url in collected {
        let key = url.standardizedFileURL.path
        if seenPaths.insert(key).inserted {
            uniqueURLs.append(url)
        }
    }
    return uniqueURLs
}

private func imageFiles(from url: URL) -> [URL] {
    guard url.isFileURL else { return [] }
    let fileManager = FileManager.default

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return []
    }

    if isDirectory.boolValue {
        return imageFiles(inDirectory: url)
    }

    if isRegularFile(url), isSupportedImageExtension(url) {
        return [url]
    }

    return []
}

private func imageFiles(inDirectory directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, _ in true }
    ) else {
        return []
    }

    var files: [URL] = []
    for case let fileURL as URL in enumerator {
        guard isRegularFile(fileURL) else { continue }
        guard isSupportedImageExtension(fileURL) else { continue }
        files.append(fileURL)
    }
    return files
}

private func isRegularFile(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
        return false
    }
    return values.isRegularFile == true
}
