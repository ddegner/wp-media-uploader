import Foundation
import XCTest
@testable import WordpressMediaUploaderApp

final class CommandRunnerTests: XCTestCase {
    func testRunCollectsStdoutStderrAndExitCode() async throws {
        let runner = CommandRunner()
        let result = try await runner.run(
            CommandSpec(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'out\\n'; printf 'err\\n' >&2; exit 3"],
                environment: nil,
                currentDirectoryURL: nil,
                displayName: "shell"
            )
        )

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdoutLines, ["out"])
        XCTAssertEqual(result.stderrLines, ["err"])
    }

    func testRunWaitsForProcessAfterPipesClose() async throws {
        let runner = CommandRunner()
        let start = Date()
        let result = try await runner.run(
            CommandSpec(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec 1>&- 2>&-; sleep 0.2; exit 7"],
                environment: nil,
                currentDirectoryURL: nil,
                displayName: "shell"
            )
        )

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.15)
    }

    func testCancellationTerminatesActiveProcess() async {
        let runner = CommandRunner()
        let task = Task {
            try await runner.run(
                CommandSpec(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "sleep 10"],
                    environment: nil,
                    currentDirectoryURL: nil,
                    displayName: "shell"
                )
            )
        }

        try? await Task.sleep(for: .milliseconds(150))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}
