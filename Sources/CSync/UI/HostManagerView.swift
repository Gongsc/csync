import SwiftUI

struct HostManagerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let initialCreateHost: Bool

    @State private var selectedHostID: UUID?
    @State private var previousSelectedHostIDBeforeCreate: UUID?

    @State private var hasActiveEditor = false
    @State private var isCreatingHost = false
    @State private var editingDraft = ManagedHost.emptyDraft
    @State private var editingBaseline: ManagedHost?
    @State private var passwordText = ""

    @State private var pendingDeleteHost: ManagedHost?
    @State private var testResultMessage: String?
    @State private var testResultTitle = "连接测试"
    @State private var isPresentingTestResult = false
    @State private var isTesting = false
    @State private var didApplyInitialCreate = false

    init(initialCreateHost: Bool = false) {
        self.initialCreateHost = initialCreateHost
    }

    private var selectedHost: ManagedHost? {
        appState.hostStore.host(for: selectedHostID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("主机管理")
                    .font(.title3.bold())
                Spacer()
                Button("关闭") {
                    dismiss()
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                    List(selection: $selectedHostID) {
                        ForEach(appState.hostStore.hosts) { host in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.displayName)
                                    .font(.headline)
                                Text(host.location)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(host.id)
                        }

                        if isCreatingHost {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(editingDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新建主机" : editingDraft.name)
                                    .font(.headline)
                                Text("请填写连接信息")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(editingDraft.id)
                        }
                    }

                    HStack {
                        Button {
                            beginCreateHost()
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .help("新增主机")
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            pendingDeleteHost = selectedHost
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("删除选中主机")
                        .buttonStyle(.bordered)
                        .disabled(selectedHost == nil)
                    }
                }
                .frame(minWidth: 320, maxWidth: 360)

                GroupBox(isCreatingHost ? "新增主机" : "编辑主机") {
                    if hasActiveEditor {
                        VStack(alignment: .leading, spacing: 12) {
                            Form {
                                TextField("主机名称", text: $editingDraft.name)
                                TextField("主机地址", text: $editingDraft.address)
                                TextField("用户名", text: $editingDraft.username)
                                SecureField("SSH 密码", text: $passwordText)
                                Text(passwordHint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Button {
                                    testConnection()
                                } label: {
                                    Label("测试连接", systemImage: "network")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isTesting || !canTest)

                                if isTesting {
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                Spacer()
                            }

                            Spacer()

                            HStack {
                                Spacer()
                                Button("取消") {
                                    cancelEditing()
                                }
                                .buttonStyle(.bordered)

                                Button("保存") {
                                    saveEditing()
                                }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                                .disabled(!canSave)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ContentUnavailableView("请选择或新增主机", systemImage: "server.rack")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(width: 860, height: 540)
        .onAppear {
            if selectedHostID == nil {
                selectedHostID = appState.hostStore.hosts.first?.id
            }

            if initialCreateHost, !didApplyInitialCreate {
                beginCreateHost()
                didApplyInitialCreate = true
            } else if let host = selectedHost {
                beginEditing(host: host)
            }
        }
        .onChange(of: selectedHostID) { _, newValue in
            guard !isCreatingHost else { return }
            guard let host = appState.hostStore.host(for: newValue) else {
                hasActiveEditor = false
                return
            }
            beginEditing(host: host)
        }
        .alert("确认删除主机", isPresented: Binding(
            get: { pendingDeleteHost != nil },
            set: { if !$0 { pendingDeleteHost = nil } }
        )) {
            Button("删除", role: .destructive) {
                guard let host = pendingDeleteHost else { return }
                appState.removeHost(host)

                if selectedHostID == host.id {
                    selectedHostID = appState.hostStore.hosts.first?.id
                }

                if let selected = appState.hostStore.host(for: selectedHostID) {
                    beginEditing(host: selected)
                } else {
                    hasActiveEditor = false
                }

                pendingDeleteHost = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteHost = nil
            }
        } message: {
            Text(pendingDeleteHost.map { "将删除主机“\($0.displayName)”及其保存密码。" } ?? "")
        }
        .alert(testResultTitle, isPresented: $isPresentingTestResult) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(testResultMessage ?? "")
        }
    }

    private var canSave: Bool {
        !editingDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !editingDraft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !editingDraft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canTest: Bool {
        !editingDraft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !editingDraft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var passwordHint: String {
        if isCreatingHost {
            return "可留空以使用免密（公钥）登录；输入密码则使用密码登录。"
        }
        return "留空将保留已有密码；输入新值将覆盖。如无密码则按免密（公钥）登录测试。"
    }

    private func beginCreateHost() {
        previousSelectedHostIDBeforeCreate = selectedHostID

        hasActiveEditor = true
        isCreatingHost = true
        editingDraft = .emptyDraft
        editingBaseline = nil
        passwordText = ""
        selectedHostID = editingDraft.id
    }

    private func beginEditing(host: ManagedHost) {
        hasActiveEditor = true
        isCreatingHost = false
        editingDraft = host
        editingBaseline = host
        passwordText = ""
    }

    private func saveEditing() {
        let trimmedPassword = passwordText.trimmingCharacters(in: .whitespacesAndNewlines)
        let keepExistingPassword = !isCreatingHost && trimmedPassword.isEmpty
        let passwordToSave = trimmedPassword.isEmpty ? nil : trimmedPassword

        let saved = appState.upsertHost(editingDraft, password: passwordToSave, keepExistingPassword: keepExistingPassword)
        if saved {
            selectedHostID = editingDraft.id
            if let host = appState.hostStore.host(for: editingDraft.id) {
                beginEditing(host: host)
            }
            previousSelectedHostIDBeforeCreate = nil
            return
        }

        testResultTitle = "保存失败"
        testResultMessage = "主机保存成功，但密码加密存储失败，请重试。"
        isPresentingTestResult = true
    }

    private func cancelEditing() {
        if isCreatingHost {
            isCreatingHost = false

            if let previousID = previousSelectedHostIDBeforeCreate,
               let previousHost = appState.hostStore.host(for: previousID) {
                selectedHostID = previousID
                beginEditing(host: previousHost)
            } else if let firstHost = appState.hostStore.hosts.first {
                selectedHostID = firstHost.id
                beginEditing(host: firstHost)
            } else {
                hasActiveEditor = false
            }

            previousSelectedHostIDBeforeCreate = nil
            return
        }

        if let selected = appState.hostStore.host(for: selectedHostID) {
            beginEditing(host: selected)
            return
        }

        if let baseline = editingBaseline {
            beginEditing(host: baseline)
        }
    }

    private func testConnection() {
        isTesting = true

        let trimmedPassword = passwordText.trimmingCharacters(in: .whitespacesAndNewlines)
        let overridePassword = trimmedPassword.isEmpty ? nil : trimmedPassword

        appState.testHostConnection(host: editingDraft, passwordOverride: overridePassword) { result in
            isTesting = false
            switch result {
            case .success(let message):
                testResultTitle = "连接测试成功"
                testResultMessage = message
            case .failure(let error):
                testResultTitle = "连接测试失败"
                testResultMessage = error.localizedDescription
            }
            isPresentingTestResult = true
        }
    }
}
