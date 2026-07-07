import SwiftUI

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let jobRunner: JobRunner
    let onSave: (ServerProfile, String, String) throws -> Void

    @State private var profile: ServerProfile
    @State private var password: String
    @State private var keyPassphrase: String
    @State private var showKeyImporter = false
    @State private var saveError: String?

    @State private var isTesting = false
    @State private var testLines: [String] = []
    @State private var testSuccess = false

    init(
        profile: ServerProfile,
        initialPassword: String?,
        initialKeyPassphrase: String?,
        jobRunner: JobRunner,
        onSave: @escaping (ServerProfile, String, String) throws -> Void
    ) {
        self.jobRunner = jobRunner
        self.onSave = onSave
        _profile = State(initialValue: profile)
        _password = State(initialValue: initialPassword ?? "")
        _keyPassphrase = State(initialValue: initialKeyPassphrase ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                wordpressSection
                defaultsSection
                connectionTestSection
            }
            .formStyle(.grouped)
            .navigationTitle("Profile Editor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAndClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                }
            }
        }
        .fileImporter(
            isPresented: $showKeyImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                return
            }
            profile.keyPath = url.path
            profile.keyBookmarkData = try? SecurityScopedFileAccess.bookmarkData(for: url)
        }
        .frame(width: 720, height: 760)
        .alert("Save Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section(header: Text("Connection")) {
            TextField("Profile Name", text: $profile.name, prompt: Text("My WordPress Server"))
            TextField("Host", text: $profile.host, prompt: Text("example.com"))
            TextField("Username", text: $profile.username, prompt: Text("deploy"))

            LabeledContent("Port") {
                TextField("", value: $profile.port, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }

            Picker("Authentication", selection: $profile.authType) {
                ForEach(AuthenticationType.allCases) { auth in
                    Text(auth.displayName).tag(auth)
                }
            }
            .pickerStyle(.menu)

            if profile.authType == .sshKey {
                HStack {
                    TextField("Optional", text: Binding(
                        get: { profile.keyPath ?? "" },
                        set: {
                            profile.keyPath = trimmed($0).isEmpty ? nil : $0
                            profile.keyBookmarkData = nil
                        }
                    ))
                    .font(.body.monospaced())

                    Button("Choose…") {
                        showKeyImporter = true
                    }
                }
                SecureField("Key Passphrase (optional)", text: $keyPassphrase)
            } else {
                SecureField("Password", text: $password)
            }
        }
    }

    // MARK: - WordPress

    private var wordpressSection: some View {
        Section(header: Text("WordPress")) {
            TextField("WP Root Path", text: $profile.wpRootPath, prompt: Text("/var/www/html"))
                .font(.body.monospaced())
        }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        Section(header: Text("Defaults")) {
            TextField("Staging Root", text: $profile.remoteStagingRoot, prompt: Text("~/wp-media-import"))
                .font(.body.monospaced())

            Toggle("Keep remote files after success", isOn: $profile.keepRemoteFiles)
        }
    }

    private var connectionTestSection: some View {
        Section(header: Text("Validation")) {
            HStack {
                Button(isTesting ? "Testing…" : "Test Connection") {
                    runConnectionTest()
                }
                .disabled(isTesting || !canSave || jobRunner.isRunning)

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }

                if !testLines.isEmpty {
                    Label(testSuccess ? "Passed" : "Failed", systemImage: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testSuccess ? .green : .red)
                }
                Spacer()
            }

            if !testLines.isEmpty {
                ForEach(Array(testLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var canSave: Bool {
        ProfileValidation.canSave(profile: profile, password: password)
    }

    private func saveAndClose() {
        do {
            try onSave(
                profile,
                password,
                keyPassphrase
            )
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func runConnectionTest() {
        guard !jobRunner.isRunning else {
            testLines = ["Stop the active upload before running Test Connection."]
            testSuccess = false
            return
        }

        isTesting = true
        testLines = []
        testSuccess = false

        Task {
            let result = await jobRunner.testConnection(
                profile: profile,
                password: password.isEmpty ? nil : password,
                keyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase
            )
            await MainActor.run {
                testLines = result.checks
                testSuccess = result.success
                isTesting = false
            }
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
