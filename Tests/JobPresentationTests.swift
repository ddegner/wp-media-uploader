import Foundation
import XCTest
@testable import WordpressMediaUploaderApp

final class JobPresentationTests: XCTestCase {
    func testFailedUploadCountsAsAttemptedDuringNextActiveUploadProgress() {
        var failedFile = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/failed.jpg"),
            filename: "failed.jpg",
            sizeBytes: 10
        )
        failedFile.status = .failed

        let activeFile = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/active.jpg"),
            filename: "active.jpg",
            sizeBytes: 10
        )

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [failedFile, activeFile],
            logsPath: "/tmp/job.log"
        )
        job.step = .uploading
        job.activeFileId = activeFile.id
        job.uploadProgress = 0.75

        let presentation = JobPresentation.make(
            for: job,
            activeFileStatus: .uploading,
            now: Date(),
            anchor: nil
        )

        XCTAssertEqual(presentation.overallProgress, 0.5625, accuracy: 0.0001)
    }
}
