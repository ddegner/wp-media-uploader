import Foundation
import SwiftUI

// Support SSH askpass helper mode.
// When ssh(1) needs a password, it execs SSH_ASKPASS and reads stdout.
// We point SSH_ASKPASS at this binary and set WP_ASKPASS_MODE=1.
// The sandbox allows exec of signed app-bundle binaries; shell scripts are blocked.
if ProcessInfo.processInfo.environment["WP_ASKPASS_MODE"] == "1" {
    if let account = ProcessInfo.processInfo.environment["WP_ASKPASS_KEYCHAIN_ACCOUNT"],
       let secret = try? KeychainService.getSecret(account: account)
    {
        print(secret)
        exit(0)
    }
    exit(1)
}

WordpressMediaUploaderApp.main()
