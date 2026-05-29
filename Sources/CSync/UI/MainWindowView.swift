import AppKit
import SwiftUI

private enum InlineHostSelection: Hashable {
    case none
    case existing(UUID)
    case createNew
}

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedProjectID: UUID?
    @State private var previousSelectedProjectIDBeforeCreate: UUID?

    @State private var isPresentingHostManager = false
    @State private var hostManagerCreatesHost = false
    @State private var hostIDsBeforeManager: Set<UUID> = []

    @State private var hasActiveEditor = false
    @State private var isCreatingProject = false
    @State private var editingDraft = Project.emptyDraft
    @State private var editingBaseline: Project?
    @State private var excludesText = ""
    @State private var hostSelection: InlineHostSelection = .none
    @State private var previousHostSelection: InlineHostSelection = .none

    private var currentTask: SyncTask? {
        appState.syncManager.tasks[editingDraft.id]
    }

    private var selectedStoredProject: Project? {
        appState.projectStore.project(for: selectedProjectID)
    }

    private var selectedProjectAutoSyncEnabled: Bool {
        selectedStoredProject?.autoSync ?? false
    }

    private var selectedHost: ManagedHost? {
        switch hostSelection {
        case .existing(let hostID):
            return appState.hostStore.host(for: hostID)
        case .none, .createNew:
            return nil
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 12) {
                List(selection: $selectedProjectID) {
                    ForEach(appState.projectStore.projects) { project in
                        let task = appState.syncManager.tasks[project.id]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.name)
                                .font(.headline)
                            Text(project.remoteLocation)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(conflictModeTagText(project.conflictHandlingMode ?? .askEveryTime))
                                .font(.caption2)
                                .foregroundStyle(conflictModeTagColor(project.conflictHandlingMode ?? .askEveryTime))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.1), in: Capsule())

                            Text(project.autoSync ? "自动同步：已开启" : "自动同步：已关闭")
                                .font(.caption2)
                                .foregroundStyle(project.autoSync ? .blue : .secondary)

                            HStack(spacing: 6) {
                                Image(systemName: statusSymbolName(for: task?.state))
                                    .foregroundStyle(statusColor(for: task?.state))
                                    .font(.caption)
                                Text(task?.state.summaryText ?? (project.autoSync ? "自动同步中" : "尚未触发同步"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                Text(task?.modeBadgeText ?? (project.autoSync ? "自动" : "手动"))
                                    .font(.caption2)
                                    .foregroundStyle(((task?.triggerKind == .automatic) || (task == nil && project.autoSync)) ? .blue : .secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background((((task?.triggerKind == .automatic) || (task == nil && project.autoSync)) ? Color.blue : Color.gray).opacity(0.12), in: Capsule())
                            }

                            if let progress = task?.state.progressValue {
                                ProgressView(value: progress)
                                    .progressViewStyle(.linear)
                            }
                        }
                        .tag(project.id)
                    }

                    if isCreatingProject {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(editingDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新建项目" : editingDraft.name)
                                .font(.headline)
                            Text("请填写配置")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(editingDraft.id)
                    }
                }

                HStack {
                    Button {
                        beginCreateProject()
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .help("新增项目")

                    Button {
                        beginEditSelectedProject()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("编辑选中项目")
                    .disabled(selectedStoredProject == nil)

                    Button {
                        guard let selected = appState.projectStore.project(for: selectedProjectID) else { return }
                        appState.removeProject(selected)
                        selectedProjectID = appState.projectStore.projects.first?.id
                        if let next = appState.projectStore.project(for: selectedProjectID) {
                            beginEditing(project: next)
                        } else {
                            hasActiveEditor = false
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("删除选中项目")
                    .disabled(selectedStoredProject == nil)

                    Spacer()

                    Button {
                        appState.syncAllProjects()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("手动同步全部项目")
                    .disabled(appState.projectStore.projects.isEmpty)

                    Button {
                        toggleAutoSyncForSelectedProject()
                    } label: {
                        Image(systemName: selectedProjectAutoSyncEnabled ? "bolt.slash.circle" : "bolt.circle")
                    }
                    .help(selectedProjectAutoSyncEnabled ? "关闭自动同步" : "开启自动同步")
                    .disabled(selectedStoredProject == nil)

                    Button {
                        openHostManager(createHost: false)
                    } label: {
                        Image(systemName: "server.rack")
                    }
                    .help("主机管理")
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .navigationTitle("项目")
        } detail: {
            if hasActiveEditor {
                detailEditorView
                    .navigationTitle(isCreatingProject ? "新增项目" : "编辑项目")
            } else {
                ContentUnavailableView("请选择或新增项目", systemImage: "folder")
                    .navigationTitle("同步状态")
            }
        }
        .sheet(isPresented: $isPresentingHostManager, onDismiss: handleHostManagerDismiss) {
            HostManagerView(initialCreateHost: hostManagerCreatesHost)
                .environmentObject(appState)
        }
        .sheet(item: $appState.activeConflictRequest) { request in
            ConflictDecisionSheet(request: request)
                .environmentObject(appState)
        }
        .onAppear {
            initializeSelectionIfNeeded()
        }
        .onChange(of: selectedProjectID) { _, newValue in
            guard !isCreatingProject else { return }
            guard let project = appState.projectStore.project(for: newValue) else {
                hasActiveEditor = false
                return
            }
            beginEditing(project: project)
        }
        .onChange(of: appState.projectEditorContext?.id) { _, _ in
            consumeExternalEditorContext()
        }
        .onChange(of: appState.hostStore.hosts.map(\.id)) { _, _ in
            normalizeHostSelectionIfNeeded()
        }
    }

    private var detailEditorView: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 420)
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("项目配置") {
                    Form {
                        TextField("项目名称", text: Binding(
                            get: { editingDraft.name },
                            set: { editingDraft.name = $0 }
                        ))

                        Picker("主机配置", selection: $hostSelection) {
                            Text("请选择主机").tag(InlineHostSelection.none)
                            ForEach(appState.hostStore.hosts) { host in
                                Text("\(host.displayName) (\(host.location))")
                                    .tag(InlineHostSelection.existing(host.id))
                            }
                            Text("新建主机...").tag(InlineHostSelection.createNew)
                        }
                        .onChange(of: hostSelection) { _, newValue in
                            handleHostSelectionChange(newValue)
                        }

                        TextField("远端路径", text: Binding(
                            get: { editingDraft.remotePath },
                            set: { editingDraft.remotePath = $0 }
                        ))

                        HStack(spacing: 8) {
                            TextField("本地目录", text: Binding(
                                get: { editingDraft.localPath },
                                set: { editingDraft.localPath = $0 }
                            ))
                            Button("选择目录") {
                                pickLocalFolder()
                            }
                        }

                        Picker("冲突默认处理", selection: Binding(
                            get: { editingDraft.conflictHandlingMode ?? .askEveryTime },
                            set: { editingDraft.conflictHandlingMode = $0 }
                        )) {
                            ForEach(ConflictHandlingMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }

                        TextField("排除规则（逗号分隔）", text: $excludesText)
                    }
                }

                if !isCreatingProject {
                    GroupBox("任务状态") {
                        VStack(alignment: .leading, spacing: 10) {
                            if let task = currentTask {
                                HStack(spacing: 8) {
                                    Image(systemName: statusSymbolName(for: task.state))
                                        .foregroundStyle(statusColor(for: task.state))
                                    if task.state.isFailed {
                                        Text(summaryText(for: task.state, width: width))
                                            .font(.subheadline)
                                            .lineLimit(detailLineLimit(for: task.state, width: width))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        Text(summaryText(for: task.state, width: width))
                                            .font(.subheadline)
                                            .lineLimit(detailLineLimit(for: task.state, width: width))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }

                                if task.state.isRunning {
                                    Text(task.runningModeText)
                                        .font(.caption)
                                        .foregroundStyle(task.triggerKind == .automatic ? .blue : .secondary)
                                } else if task.state.isQueued {
                                    Text(task.queuedModeText)
                                        .font(.caption)
                                        .foregroundStyle(task.triggerKind == .automatic ? .blue : .secondary)
                                } else if isAutoSyncEnabled(for: editingDraft.id) {
                                    Text("自动同步中")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }

                                if task.state.isFailed {
                                    Text("失败文件将显示在下方“同步文件明细”。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if let progress = task.state.progressValue {
                                    ProgressView(value: progress)
                                        .progressViewStyle(.linear)
                                }
                            } else {
                                Text(isAutoSyncEnabled(for: editingDraft.id) ? "自动同步中" : "尚未触发同步")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let task = currentTask {
                        GroupBox("同步文件明细") {
                            if task.fileResults.isEmpty {
                                Text("暂无文件明细（执行同步后会显示本次成功/失败文件）。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                let failedFiles = task.fileResults.filter { $0.status == .failed }
                                let succeededFiles = task.fileResults.filter { $0.status == .succeeded }

                                ScrollView {
                                    VStack(alignment: .leading, spacing: 10) {
                                        if !failedFiles.isEmpty {
                                            fileLevelSection(title: "失败文件", symbol: "xmark.circle.fill", color: .red, files: failedFiles)
                                        }

                                        if !succeededFiles.isEmpty {
                                            fileLevelSection(title: "成功文件", symbol: "checkmark.circle.fill", color: .green, files: succeededFiles)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: width < 760 ? 140 : 220)
                            }
                        }
                    }

                    if let task = currentTask, case .failed(let message) = task.state {
                        GroupBox("错误详情") {
                            ScrollView {
                                Text(message)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: width < 760 ? 120 : 220)
                        }
                    }

                    HStack {
                        Button {
                            if let project = appState.projectStore.project(for: editingDraft.id) {
                                appState.syncNow(project: project)
                            }
                        } label: {
                            Text("手动同步")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("手动同步")

                        Button {
                            appState.syncManager.cancel(projectID: editingDraft.id)
                        } label: {
                            Text("取消任务")
                        }
                        .buttonStyle(.bordered)
                        .help("取消当前任务")

                        if let project = appState.projectStore.project(for: editingDraft.id) {
                            Button {
                                toggleAutoSync(for: project)
                            } label: {
                                Text(project.autoSync ? "关闭自动同步" : "开启自动同步")
                            }
                            .buttonStyle(.bordered)
                            .help(project.autoSync ? "关闭自动同步" : "开启自动同步")
                        }

                        if let task = currentTask, task.state.isFailed {
                            Button {
                                appState.syncManager.retryFailed(projectID: editingDraft.id)
                            } label: {
                                Text("重试")
                            }
                            .buttonStyle(.bordered)
                            .help("重试")
                        }

                        Spacer()
                    }
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
                    .disabled(!canSaveEditor)
                }
            }
            .padding(16)
        }
    }

    private var canSaveEditor: Bool {
        guard hasActiveEditor else { return false }

        return !editingDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !editingDraft.localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !editingDraft.remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            selectedHost != nil
    }

    private func beginCreateProject() {
        previousSelectedProjectIDBeforeCreate = selectedProjectID

        var project = Project.emptyDraft
        project.usePasswordAuth = false
        project.conflictHandlingMode = .askEveryTime
        selectedProjectID = project.id
        beginEditing(project: project, baseline: nil, creating: true)
    }

    private func beginEditSelectedProject() {
        guard let project = appState.projectStore.project(for: selectedProjectID) else { return }
        beginEditing(project: project)
    }

    private func beginEditing(project: Project, baseline: Project? = nil, creating: Bool = false) {
        hasActiveEditor = true
        isCreatingProject = creating
        editingDraft = project
        editingBaseline = baseline ?? (creating ? nil : project)
        excludesText = project.excludes.joined(separator: ",")

        let resolvedSelection = resolveHostSelection(for: project)
        hostSelection = resolvedSelection
        previousHostSelection = resolvedSelection

        if case .existing(let hostID) = resolvedSelection {
            applySelectedHost(hostID: hostID)
        }
    }

    private func resolveHostSelection(for project: Project) -> InlineHostSelection {
        if let hostID = project.hostID, appState.hostStore.host(for: hostID) != nil {
            return .existing(hostID)
        }

        if let matched = appState.hostStore.hosts.first(where: {
            $0.address == project.remoteHost && $0.username == project.remoteUser
        }) {
            return .existing(matched.id)
        }

        return .none
    }

    private func handleHostSelectionChange(_ selection: InlineHostSelection) {
        switch selection {
        case .none:
            editingDraft.hostID = nil
            editingDraft.remoteHost = ""
            editingDraft.remoteUser = ""
            previousHostSelection = .none
        case .existing(let hostID):
            applySelectedHost(hostID: hostID)
            previousHostSelection = selection
        case .createNew:
            hostSelection = previousHostSelection
            openHostManager(createHost: true)
        }
    }

    private func applySelectedHost(hostID: UUID) {
        guard let host = appState.hostStore.host(for: hostID) else { return }
        editingDraft.hostID = host.id
        editingDraft.remoteHost = host.address
        editingDraft.remoteUser = host.username
        editingDraft.usePasswordAuth = host.prefersPasswordAuth
    }

    private func openHostManager(createHost: Bool) {
        hostManagerCreatesHost = createHost
        hostIDsBeforeManager = Set(appState.hostStore.hosts.map(\.id))
        isPresentingHostManager = true
    }

    private func handleHostManagerDismiss() {
        defer {
            hostManagerCreatesHost = false
            hostIDsBeforeManager = []
        }

        guard hostManagerCreatesHost else { return }

        if let createdHost = appState.hostStore.hosts.first(where: { !hostIDsBeforeManager.contains($0.id) }) {
            hostSelection = .existing(createdHost.id)
            applySelectedHost(hostID: createdHost.id)
            previousHostSelection = .existing(createdHost.id)
            return
        }

        if case .none = hostSelection, let fallbackHost = appState.hostStore.hosts.first {
            hostSelection = .existing(fallbackHost.id)
            applySelectedHost(hostID: fallbackHost.id)
            previousHostSelection = .existing(fallbackHost.id)
        }

        normalizeHostSelectionIfNeeded()
    }

    private func consumeExternalEditorContext() {
        guard let context = appState.projectEditorContext else { return }
        defer { appState.projectEditorContext = nil }

        if let project = context.project {
            let actualProject = appState.projectStore.project(for: project.id) ?? project
            selectedProjectID = actualProject.id
            beginEditing(project: actualProject)
            return
        }

        beginCreateProject()
    }

    private func initializeSelectionIfNeeded() {
        if selectedProjectID == nil {
            selectedProjectID = appState.projectStore.projects.first?.id
        }

        if let selected = appState.projectStore.project(for: selectedProjectID) {
            beginEditing(project: selected)
        } else {
            hasActiveEditor = false
        }
    }

    private func normalizedExcludes() -> [String] {
        excludesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func preparedDraftForSave() -> Project? {
        guard let host = selectedHost else { return nil }

        var project = editingDraft
        project.hostID = host.id
        project.remoteHost = host.address
        project.remoteUser = host.username
        project.usePasswordAuth = host.prefersPasswordAuth
        project.conflictHandlingMode = project.conflictHandlingMode ?? .askEveryTime
        project.excludes = normalizedExcludes()
        return project
    }

    private func normalizeHostSelectionIfNeeded() {
        switch hostSelection {
        case .none, .createNew:
            return
        case .existing(let hostID):
            guard appState.hostStore.host(for: hostID) == nil else { return }

            if let matched = appState.hostStore.hosts.first(where: {
                $0.address == editingDraft.remoteHost && $0.username == editingDraft.remoteUser
            }) {
                hostSelection = .existing(matched.id)
                previousHostSelection = .existing(matched.id)
                applySelectedHost(hostID: matched.id)
                return
            }

            if let fallback = appState.hostStore.hosts.first {
                hostSelection = .existing(fallback.id)
                previousHostSelection = .existing(fallback.id)
                applySelectedHost(hostID: fallback.id)
                return
            }

            hostSelection = .none
            previousHostSelection = .none
            editingDraft.hostID = nil
            editingDraft.remoteHost = ""
            editingDraft.remoteUser = ""
            editingDraft.usePasswordAuth = false
        }
    }

    private func saveEditing() {
        guard let project = preparedDraftForSave() else { return }

        appState.upsertProject(project)

        isCreatingProject = false
        previousSelectedProjectIDBeforeCreate = nil
        selectedProjectID = project.id

        let refreshed = appState.projectStore.project(for: project.id) ?? project
        beginEditing(project: refreshed)
    }

    private func isAutoSyncEnabled(for projectID: UUID) -> Bool {
        appState.projectStore.project(for: projectID)?.autoSync ?? editingDraft.autoSync
    }

    private func toggleAutoSync(for project: Project) {
        let enabled = !project.autoSync
        appState.setAutoSyncEnabled(enabled, for: project.id)
        if editingDraft.id == project.id {
            editingDraft.autoSync = enabled
        }
    }

    private func toggleAutoSyncForSelectedProject() {
        guard let project = selectedStoredProject else { return }
        toggleAutoSync(for: project)
    }

    private func cancelEditing() {
        if isCreatingProject {
            isCreatingProject = false

            if let previousID = previousSelectedProjectIDBeforeCreate,
               let previousProject = appState.projectStore.project(for: previousID) {
                selectedProjectID = previousID
                beginEditing(project: previousProject)
            } else if let firstProject = appState.projectStore.projects.first {
                selectedProjectID = firstProject.id
                beginEditing(project: firstProject)
            } else {
                hasActiveEditor = false
            }

            previousSelectedProjectIDBeforeCreate = nil
            return
        }

        if let selectedProject = appState.projectStore.project(for: selectedProjectID) {
            beginEditing(project: selectedProject)
            return
        }

        if let baseline = editingBaseline {
            beginEditing(project: baseline)
        }
    }

    private func pickLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"

        if panel.runModal() == .OK {
            editingDraft.localPath = panel.url?.path ?? editingDraft.localPath
        }
    }

    private func summaryText(for state: SyncTaskState, width: CGFloat) -> String {
        guard case .failed(let message) = state else {
            return state.summaryText
        }

        if width >= 900 {
            return "失败 · \(message)"
        }

        let flattened = message
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " | ")
        return "失败 · \(flattened)"
    }

    private func detailLineLimit(for state: SyncTaskState, width: CGFloat) -> Int? {
        guard state.isFailed else { return 1 }
        if width < 520 { return 2 }
        if width < 760 { return 4 }
        if width < 980 { return 7 }
        return nil
    }

    @ViewBuilder
    private func fileLevelSection(title: String, symbol: String, color: Color, files: [SyncFileResult]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text("\(title)（\(files.count)）")
                    .font(.caption.weight(.semibold))
            }

            ForEach(files) { file in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                        .font(.caption2)
                    Text(file.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func statusSymbolName(for state: SyncTaskState?) -> String {
        guard let state else { return "circle" }

        switch state {
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .running:
            return "arrow.triangle.2.circlepath.circle"
        case .queued:
            return "clock"
        case .cancelled:
            return "minus.circle"
        }
    }

    private func statusColor(for state: SyncTaskState?) -> Color {
        guard let state else { return .secondary }

        switch state {
        case .queued:
            return .orange
        case .running:
            return .blue
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }

    private func conflictModeTagText(_ mode: ConflictHandlingMode) -> String {
        switch mode {
        case .askEveryTime:
            return "冲突策略：每次询问"
        case .localOverride:
            return "冲突策略：自动本地覆盖远端"
        case .remoteOverride:
            return "冲突策略：自动远端覆盖本地"
        }
    }

    private func conflictModeTagColor(_ mode: ConflictHandlingMode) -> Color {
        switch mode {
        case .askEveryTime:
            return .secondary
        case .localOverride:
            return .orange
        case .remoteOverride:
            return .blue
        }
    }
}
