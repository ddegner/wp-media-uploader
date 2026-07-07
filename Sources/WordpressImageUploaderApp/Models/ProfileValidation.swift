import Foundation

enum ProfileValidationContext {
    case editor
    case execution
}

enum ProfileValidation {
    static func firstError(
        for profile: ServerProfile,
        password: String?,
        context: ProfileValidationContext
    ) -> String? {
        if context == .editor, trimmed(profile.name).isEmpty {
            return "Profile name is required"
        }

        if trimmed(profile.host).isEmpty {
            return "Host is required"
        }

        if trimmed(profile.username).isEmpty {
            return "Username is required"
        }

        if profile.port <= 0 {
            return "Port must be greater than 0"
        }

        if trimmed(profile.wpRootPath).isEmpty {
            return "WordPress root path is required"
        }

        if trimmed(profile.remoteStagingRoot).isEmpty {
            return "Remote staging root is required"
        }

        if profile.authType == .password {
            guard let password, !trimmed(password).isEmpty else {
                if context == .execution {
                    return "Password auth selected, but no password is stored in Keychain"
                }
                return "Password is required"
            }
        }

        if profile.authType == .sshKey,
           let keyPath = profile.keyPath,
           !trimmed(keyPath).isEmpty
        {
            if let keyBookmarkData = profile.keyBookmarkData {
                do {
                    let access = try SecurityScopedFileAccess.start(
                        path: keyPath,
                        bookmarkData: keyBookmarkData,
                        purpose: "SSH key file"
                    )
                    access.stop()
                } catch {
                    return error.localizedDescription
                }
            } else if !FileManager.default.fileExists(atPath: keyPath) {
                return "SSH key file not found at \(keyPath)"
            }
        }

        return nil
    }

    static func canSave(profile: ServerProfile, password: String) -> Bool {
        firstError(for: profile, password: password, context: .editor) == nil
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
