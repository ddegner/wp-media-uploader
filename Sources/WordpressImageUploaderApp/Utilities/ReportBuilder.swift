import Foundation

enum ReportExportFormat {
    case text
    case json
    case csv

    var fileExtension: String {
        switch self {
        case .text:
            return "txt"
        case .json:
            return "json"
        case .csv:
            return "csv"
        }
    }
}

struct JobReportFileRecord: Codable {
    var filename: String
    var sizeBytes: Int64
    var status: String
    var attachmentId: Int?
    var remotePath: String?
    var errorMessage: String?
}

struct JobReport: Codable {
    var jobId: String
    var profileId: String
    var createdAt: String
    var status: String
    var remoteJobDir: String
    var logPath: String
    var uploadProgress: Double
    var importProgress: Double
    var importedIds: [Int]
    var files: [JobReportFileRecord]
}

enum ReportBuilder {
    static func textReport(for job: Job) -> String {
        var lines: [String] = []
        lines.append("Job: \(job.id.uuidString)")
        lines.append("Profile: \(job.profileId.uuidString)")
        lines.append("Created: \(job.createdAt.formatted())")
        lines.append("Status: \(job.step.rawValue)")
        lines.append("Logs: \(job.logsPath)")
        lines.append("")

        for file in job.localFiles {
            var line = "\(file.filename): \(file.status.rawValue)"
            if let id = file.importAttachmentId {
                line += " (attachment \(id))"
            }
            if let error = file.errorMessage, !error.isEmpty {
                line += " | error: \(error)"
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    static func jsonReport(for job: Job) throws -> String {
        let report = JobReport(
            jobId: job.id.uuidString,
            profileId: job.profileId.uuidString,
            createdAt: job.createdAt.formatted(.iso8601),
            status: job.step.rawValue,
            remoteJobDir: job.remoteJobDir,
            logPath: job.logsPath,
            uploadProgress: job.uploadProgress,
            importProgress: job.importProgress,
            importedIds: job.importedIds,
            files: job.localFiles.map {
                JobReportFileRecord(
                    filename: $0.filename,
                    sizeBytes: $0.sizeBytes,
                    status: $0.status.rawValue,
                    attachmentId: $0.importAttachmentId,
                    remotePath: $0.remotePath,
                    errorMessage: $0.errorMessage
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }

    static func csvReport(for job: Job) -> String {
        var rows: [String] = []
        rows.append("filename,size_bytes,status,attachment_id,remote_path,error_message")

        for file in job.localFiles {
            rows.append([
                csvEscape(file.filename),
                "\(file.sizeBytes)",
                csvEscape(file.status.rawValue),
                file.importAttachmentId.map(String.init) ?? "",
                csvEscape(file.remotePath ?? ""),
                csvEscape(file.errorMessage ?? ""),
            ].joined(separator: ","))
        }

        return rows.joined(separator: "\n")
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\n") || value.contains("\"") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
