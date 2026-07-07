import Foundation

struct SSHAuthContext: Sendable {
    var additionalSSHArgs: [String]
    var environment: [String: String]?
    var askPassScriptURL: URL?
    var securityScopedAccesses: [SecurityScopedFileAccess] = []
    var temporaryAskPassAccount: String?

    func cleanup() {
        if let askPassScriptURL {
            try? FileManager.default.removeItem(at: askPassScriptURL)
        }
        for access in securityScopedAccesses {
            access.stop()
        }
        if let temporaryAskPassAccount {
            try? KeychainService.deleteSecret(account: temporaryAskPassAccount)
        }
    }
}

struct ProfileTestResult: Sendable {
    var checks: [String]
    var success: Bool
}

@MainActor
final class SSHTransport {
    private let commandRunner = CommandRunner()
    private let profileStore: ProfileStore
    private var knownHostsPathCache: String?

    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
    }

    // MARK: - Stale askpass cleanup (B1)

    private func cleanupStaleAskPassScripts() {
        let fm = FileManager.default
        for directory in askPassDirectories() {
            guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }

            for filename in contents where filename.hasPrefix("askpass-") && filename.hasSuffix(".sh") {
                let fullPath = directory.appendingPathComponent(filename, isDirectory: false).path
                try? fm.removeItem(atPath: fullPath)
            }
        }
    }

    private func cleanupStaleAskPassScriptsIfNeeded() {
        // Always clean up stale scripts - small performance cost for better reliability
        cleanupStaleAskPassScripts()
    }

    // MARK: - Auth context

    func makeAuthContext(for profile: ServerProfile) throws -> SSHAuthContext {
        try makeAuthContext(
            for: profile,
            password: profileStore.loadPassword(for: profile),
            keyPassphrase: profileStore.loadKeyPassphrase(for: profile),
            passwordMissingDetail: "Password auth selected, but no password is stored in Keychain"
        )
    }

    func makeAuthContext(for profile: ServerProfile, password: String?, keyPassphrase: String?) throws -> SSHAuthContext {
        try makeAuthContext(
            for: profile,
            password: password,
            keyPassphrase: keyPassphrase,
            passwordMissingDetail: "Password auth selected, but no password provided"
        )
    }

    // MARK: - Auth context (private)

    private func makeAuthContext(
        for profile: ServerProfile,
        password: String?,
        keyPassphrase: String?,
        passwordMissingDetail: String
    ) throws -> SSHAuthContext {
        cleanupStaleAskPassScriptsIfNeeded()

        switch profile.authType {
        case .sshKey:
            var args: [String] = []
            var access: SecurityScopedFileAccess?
            if let keyPath = profile.keyPath,
               !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                access = try SecurityScopedFileAccess.start(
                    path: keyPath,
                    bookmarkData: profile.keyBookmarkData,
                    purpose: "SSH key file"
                )
                if let access {
                    args += ["-i", access.url.path]
                }
            }

            if let passphrase = keyPassphrase, !passphrase.isEmpty {
                let askPass = try makeAskPassEnv(secret: passphrase)
                args = ["-o", "BatchMode=no"] + args
                return SSHAuthContext(
                    additionalSSHArgs: args,
                    environment: askPass.environment,
                    askPassScriptURL: nil,
                    securityScopedAccesses: [access].compactMap { $0 },
                    temporaryAskPassAccount: askPass.keychainAccount
                )
            }

            args = ["-o", "BatchMode=yes"] + args
            return SSHAuthContext(
                additionalSSHArgs: args,
                environment: nil,
                askPassScriptURL: nil,
                securityScopedAccesses: [access].compactMap { $0 },
                temporaryAskPassAccount: nil
            )

        case .password:
            guard let password, !password.isEmpty else {
                throw JobRunnerError.profileIncomplete(passwordMissingDetail)
            }
            let askPass = try makeAskPassEnv(secret: password)

            let args = [
                "-o", "BatchMode=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1"
            ]

            return SSHAuthContext(
                additionalSSHArgs: args,
                environment: askPass.environment,
                askPassScriptURL: nil,
                temporaryAskPassAccount: askPass.keychainAccount
            )
        }
    }

    // MARK: - SSH execution

    func runSSH(
        profile: ServerProfile,
        auth: SSHAuthContext,
        remoteCommand: String,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> CommandResult {
        // Wrap in a login shell so the server's full PATH (including versioned PHP) is available.
        let loginCommand = "bash -lc \(shellSingleQuote(remoteCommand))"
        let args = sshBaseArgs(profile: profile, auth: auth) + [loginCommand]
        writer?.append("$ /usr/bin/ssh \(args.joined(separator: " "))")

        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: args,
            environment: auth.environment,
            currentDirectoryURL: nil,
            displayName: "ssh"
        )

        let result = try await commandRunner.run(spec, onLine: onLine)

        guard result.exitCode == 0 else {
            let tail = result.stderrLines.suffix(3).joined(separator: " | ")
            throw CommandRunnerError.nonZeroExit(code: result.exitCode, stderrTail: tail)
        }

        return result
    }

    // MARK: - Rsync execution

    func runRsyncFile(
        profile: ServerProfile,
        auth: SSHAuthContext,
        localFileURL: URL,
        localFileBookmarkData: Data? = nil,
        remoteTargetPath: String,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws {
        let fileAccess = try SecurityScopedFileAccess.start(
            url: localFileURL,
            bookmarkData: localFileBookmarkData,
            purpose: "Selected upload file"
        )
        defer { fileAccess.stop() }

        do {
            try await attemptRsyncFile(
                profile: profile, auth: auth,
                localFileURL: fileAccess.url, remoteTargetPath: remoteTargetPath,
                writer: writer, onLine: onLine
            )
        } catch let error as CommandRunnerError {
            guard case .nonZeroExit(let code, _) = error,
                  isTransientRsyncExitCode(code)
            else {
                throw error
            }

            writer?.append("Transient rsync error (exit \(code)), retrying in 2 seconds…")
            try await Task.sleep(for: .seconds(2))

            try await attemptRsyncFile(
                profile: profile, auth: auth,
                localFileURL: fileAccess.url, remoteTargetPath: remoteTargetPath,
                writer: writer, onLine: onLine
            )
        }
    }

    private func attemptRsyncFile(
        profile: ServerProfile,
        auth: SSHAuthContext,
        localFileURL: URL,
        remoteTargetPath: String,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws {
        var arguments = makeRsyncArguments(
            profile: profile,
            auth: auth,
            localFileURL: localFileURL,
            remoteTargetPath: remoteTargetPath,
            progressMode: .preferred
        )

        let firstAttempt = try await runRsync(
            arguments: arguments,
            environment: auth.environment,
            writer: writer,
            onLine: onLine
        )

        if firstAttempt.exitCode == 0 {
            return
        }

        if shouldFallbackForRsyncCompatibility(firstAttempt.stderrLines) {
            writer?.append("rsync compatibility fallback: retrying with --append --progress")
            arguments = makeRsyncArguments(
                profile: profile,
                auth: auth,
                localFileURL: localFileURL,
                remoteTargetPath: remoteTargetPath,
                progressMode: .compatible
            )

            let secondAttempt = try await runRsync(
                arguments: arguments,
                environment: auth.environment,
                writer: writer,
                onLine: onLine
            )

            guard secondAttempt.exitCode == 0 else {
                let stderrTail = secondAttempt.stderrLines.suffix(3).joined(separator: " | ")
                throw CommandRunnerError.nonZeroExit(code: secondAttempt.exitCode, stderrTail: stderrTail)
            }
            return
        }

        let stderrTail = firstAttempt.stderrLines.suffix(3).joined(separator: " | ")
        throw CommandRunnerError.nonZeroExit(code: firstAttempt.exitCode, stderrTail: stderrTail)
    }

    private func isTransientRsyncExitCode(_ code: Int32) -> Bool {
        // 12: Error in rsync protocol data stream
        // 23: Partial transfer due to error
        // 30: Timeout in data send/receive
        // 255: SSH connection error
        [12, 23, 30, 255].contains(code)
    }

    // MARK: - Remote helpers

    func fetchRemoteHomeDirectory(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> String {
        let result = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "printf '%s' \"$HOME\"",
            writer: writer,
            onLine: onLine
        )
        let home = result.stdoutLines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if home.isEmpty {
            throw JobRunnerError.profileIncomplete("Could not resolve remote $HOME path")
        }
        return home
    }

    func fetchRemoteFileSize(
        profile: ServerProfile,
        auth: SSHAuthContext,
        remotePath: String,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> Int64 {
        let command = "(stat -c%s \(shellSingleQuote(remotePath)) 2>/dev/null || stat -f%z \(shellSingleQuote(remotePath)) 2>/dev/null)"
        let result = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: command,
            writer: writer,
            onLine: onLine
        )

        guard let line = result.stdoutLines
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .last,
              let value = Int64(line)
        else {
            throw JobRunnerError.profileIncomplete("Could not parse remote file size for \(remotePath)")
        }

        return value
    }

    // MARK: - Shared preflight checks (S6)

    func runPreflightChecks(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws {
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "uname -a",
            writer: writer,
            onLine: onLine
        )
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "command -v wp",
            writer: writer,
            onLine: onLine
        )
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "command -v rsync",
            writer: writer,
            onLine: onLine
        )
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: wpCommand("wp --path=\(shellSingleQuote(profile.wpRootPath)) core is-installed"),
            writer: writer,
            onLine: onLine
        )
    }

    func cancelActiveProcess() async {
        await commandRunner.cancelActiveProcess()
    }

    // MARK: - Private helpers

    func sshBaseArgs(profile: ServerProfile, auth: SSHAuthContext) -> [String] {
        var args = [
            "-p", "\(profile.port)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1"
        ]
        if let knownHostsPath = knownHostsPath() {
            args += ["-o", "UserKnownHostsFile=\(knownHostsPath)"]
        }
        args += auth.additionalSSHArgs
        args.append("\(profile.username)@\(profile.host)")
        return args
    }

    private func rsyncSSHTransport(profile: ServerProfile, auth: SSHAuthContext) -> String {
        var parts = [
            "ssh",
            "-p", "\(profile.port)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1"
        ]
        if let knownHostsPath = knownHostsPath() {
            parts += ["-o", "UserKnownHostsFile=\(knownHostsPath)"]
        }
        parts += auth.additionalSSHArgs
        return parts.map(shellSingleQuote).joined(separator: " ")
    }

    private enum RsyncProgressMode {
        case preferred
        case compatible
    }

    private func makeRsyncArguments(
        profile: ServerProfile,
        auth: SSHAuthContext,
        localFileURL: URL,
        remoteTargetPath: String,
        progressMode: RsyncProgressMode
    ) -> [String] {
        var arguments = ["-az", "--partial"]

        switch progressMode {
        case .preferred:
            arguments += ["--append-verify", "--info=progress2"]
        case .compatible:
            arguments += ["--append", "--progress"]
        }

        arguments += ["-e", rsyncSSHTransport(profile: profile, auth: auth)]
        arguments.append(localFileURL.path)
        arguments.append("\(profile.username)@\(profile.host):\(shellSingleQuote(remoteTargetPath))")
        return arguments
    }

    private func runRsync(
        arguments: [String],
        environment: [String: String]?,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)?
    ) async throws -> CommandResult {
        writer?.append("$ /usr/bin/rsync \(arguments.joined(separator: " "))")

        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/rsync"),
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: nil,
            displayName: "rsync"
        )
        return try await commandRunner.run(spec, onLine: onLine)
    }

    private func shouldFallbackForRsyncCompatibility(_ stderrLines: [String]) -> Bool {
        let stderr = stderrLines.joined(separator: "\n").lowercased()
        let unknownOption = stderr.contains("unrecognized option") || stderr.contains("unknown option")
        guard unknownOption else { return false }
        return stderr.contains("append-verify") || stderr.contains("info=progress2")
    }

    // Use the app binary itself as SSH_ASKPASS. The sandbox blocks exec of dynamically-
    // created shell scripts but always allows exec of signed binaries in the app bundle.
    // main.swift detects WP_ASKPASS_MODE=1 and reads a temporary Keychain secret before SwiftUI starts.
    private func makeAskPassEnv(secret: String) throws -> (environment: [String: String], keychainAccount: String) {
        guard let executablePath = Bundle.main.executablePath else {
            throw JobRunnerError.authSetupFailed("Could not locate app binary for SSH authentication")
        }
        let account = "askpass-\(UUID().uuidString)"
        try KeychainService.setSecret(secret, account: account)
        return ([
            "SSH_ASKPASS": executablePath,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": "1",
            "WP_ASKPASS_MODE": "1",
            "WP_ASKPASS_KEYCHAIN_ACCOUNT": account
        ], account)
    }

    private func askPassDirectories() -> [URL] {
        [
            AppPaths.appSupportDirectory,
            askPassDirectory()
        ]
    }

    private func askPassDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WPMediaUploader", isDirectory: true)
            .appendingPathComponent("askpass", isDirectory: true)
    }

    private func knownHostsPath() -> String? {
        if let knownHostsPathCache {
            return knownHostsPathCache
        }

        let knownHostsFileURL = AppPaths.appSupportDirectory
            .appendingPathComponent("known_hosts", isDirectory: false)
        let fileManager = FileManager.default
        let parent = knownHostsFileURL.deletingLastPathComponent()
        AppPaths.ensureDirectory(parent)

        if !fileManager.fileExists(atPath: knownHostsFileURL.path) {
            fileManager.createFile(atPath: knownHostsFileURL.path, contents: Data())
        }

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsFileURL.path)
        knownHostsPathCache = knownHostsFileURL.path
        return knownHostsPathCache
    }
}

// MARK: - Shared utilities used by JobRunner

func resolvedStagingRoot(profile: ServerProfile, homeDirectory: String) -> String {
    if profile.remoteStagingRoot == "~" {
        return homeDirectory
    }

    if profile.remoteStagingRoot.hasPrefix("~/") {
        let suffix = String(profile.remoteStagingRoot.dropFirst(2))
        return "\(homeDirectory)/\(suffix)"
    }

    return profile.remoteStagingRoot
}
