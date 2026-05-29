import AppKit
import SwiftUI

private enum ProjectHostSelection: Hashable {
    case none
    case existing(UUID)
    case createNew
}

struct ProjectEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    private let original: Project?
    private let onSave: (Project) -> Void

    @State private var draft: Project
    @State private var excludesText: String
    @State private var hostSelection: ProjectHostSelection
    @State private var previousHostSelection: ProjectHostSelection
    @State private var isPresentingHostManager = false

    init(project: Project?, onSave: @escaping (Project) -> Void) {
        self.original = project
        self.onSave = onSave

        let value = project ?? .emptyDraft
        let selection: ProjectHostSelection
        if let hostID = value.hostID {
            selection = .existing(hostID)
        } else {
            selection = .none
        }

        _draft = State(initialValue: value)
        _excludesText = State(initialValue: value.excludes.joined(separator: ","))
        _hostSelection = State(initialValue: selection)
        _previousHostSelection = State(initialValue: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? "新增项目" : "编辑项目")
                .font(.title3.bold())

            Form {
                TextField("项目名称", text: $draft.name)

                Picker("主机配置", selection: $hostSelection) {
                    Text("请选择主机").tag(ProjectHostSelection.none)
                    ForEach(appState.hostStore.hosts) { host in
                        Text("\(host.displayName) (\(host.location))")
                            .tag(ProjectHostSelection.existing(host.id))
                    }
                    Text("新建主机...").tag(ProjectHostSelection.createNew)
                }
                .onChange(of: hostSelection) { _, newValue in
                    handleHostSelectionChange(newValue)
                }

                TextField("远端路径", text: $draft.remotePath)

                HStack(spacing: 8) {
                    TextField("本地目录", text: $draft.localPath)
                    Button("选择目录") {
                        pickLocalFolder()
                    }
                }

                TextField("排除规则（逗号分隔）", text: $excludesText)
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    draft.excludes = excludesText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }

                    draft.usePasswordAuth = selectedHost?.prefersPasswordAuth ?? false
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 620)
        .sheet(isPresented: $isPresentingHostManager) {
            HostManagerView(initialCreateHost: true)
                .environmentObject(appState)
        }
        .onChange(of: appState.hostStore.hosts.map(\.id)) { _, _ in
            normalizeHostSelectionIfNeeded()
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        selectedHost != nil
    }

    private var selectedHost: ManagedHost? {
        if case .existing(let hostID) = hostSelection {
            return appState.hostStore.host(for: hostID)
        }

        if let hostID = draft.hostID {
            return appState.hostStore.host(for: hostID)
        }

        return nil
    }

    private func handleHostSelectionChange(_ selection: ProjectHostSelection) {
        switch selection {
        case .none:
            draft.hostID = nil
            draft.remoteHost = ""
            draft.remoteUser = ""
            previousHostSelection = .none
        case .existing(let hostID):
            guard let host = appState.hostStore.host(for: hostID) else { return }
            draft.hostID = host.id
            draft.remoteHost = host.address
            draft.remoteUser = host.username
            draft.usePasswordAuth = host.prefersPasswordAuth
            previousHostSelection = selection
        case .createNew:
            hostSelection = previousHostSelection
            isPresentingHostManager = true
        }
    }

    private func normalizeHostSelectionIfNeeded() {
        guard case .existing(let hostID) = hostSelection else { return }
        guard appState.hostStore.host(for: hostID) == nil else { return }

        if let matched = appState.hostStore.hosts.first(where: {
            $0.address == draft.remoteHost && $0.username == draft.remoteUser
        }) {
            hostSelection = .existing(matched.id)
            previousHostSelection = .existing(matched.id)
            draft.hostID = matched.id
            draft.remoteHost = matched.address
            draft.remoteUser = matched.username
            draft.usePasswordAuth = matched.prefersPasswordAuth
            return
        }

        if let fallback = appState.hostStore.hosts.first {
            hostSelection = .existing(fallback.id)
            previousHostSelection = .existing(fallback.id)
            draft.hostID = fallback.id
            draft.remoteHost = fallback.address
            draft.remoteUser = fallback.username
            draft.usePasswordAuth = fallback.prefersPasswordAuth
            return
        }

        hostSelection = .none
        previousHostSelection = .none
        draft.hostID = nil
        draft.remoteHost = ""
        draft.remoteUser = ""
        draft.usePasswordAuth = false
    }

    private func pickLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"

        if panel.runModal() == .OK {
            draft.localPath = panel.url?.path ?? draft.localPath
        }
    }
}
