import XCTest
@testable import WordpressMediaUploaderApp

final class ServerProfileCodingTests: XCTestCase {
    func testDecodingLegacyProfileWithoutDeprecatedSoundSettingStillSucceeds() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Production",
          "host": "example.com",
          "port": 22,
          "username": "deploy",
          "authType": "password",
          "wpRootPath": "/var/www/html",
          "remoteStagingRoot": "~/wp-media-import",
          "keepRemoteFiles": false
        }
        """

        let decoded = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertFalse(decoded.keepRemoteFiles)
        XCTAssertNil(decoded.keyBookmarkData)
    }

    func testDecodingLegacyProfileWithDeprecatedSoundSettingIgnoresField() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "With sound",
          "host": "example.com",
          "port": 22,
          "username": "deploy",
          "authType": "password",
          "wpRootPath": "/var/www/html",
          "remoteStagingRoot": "~/wp-media-import",
          "keepRemoteFiles": false,
          "playCompletionSoundOnCompletion": true
        }
        """

        let decoded = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(decoded)
        let encodedString = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(decoded.name, "With sound")
        XCTAssertFalse(encodedString.contains("playCompletionSoundOnCompletion"))
    }

    func testDecodingLegacyJobWithoutBookmarkDataStillSucceeds() throws {
        let jobId = UUID()
        let profileId = UUID()
        let fileId = UUID()
        let json = """
        {
          "id": "\(jobId.uuidString)",
          "profileId": "\(profileId.uuidString)",
          "createdAt": 0,
          "remoteJobDir": "/tmp/job",
          "localFiles": [
            {
              "id": "\(fileId.uuidString)",
              "localURL": "file:///tmp/a.jpg",
              "filename": "a.jpg",
              "sizeBytes": 10,
              "status": "queued",
              "remotePath": null,
              "importAttachmentId": null,
              "errorMessage": null
            }
          ],
          "step": "preflight",
          "uploadProgress": 0,
          "importProgress": 0,
          "activeFileId": null,
          "errorMessage": null,
          "logsPath": "/tmp/job.log",
          "importedIds": []
        }
        """

        let decoded = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, jobId)
        XCTAssertEqual(decoded.localFiles.first?.id, fileId)
        XCTAssertNil(decoded.localFiles.first?.bookmarkData)
    }
}
