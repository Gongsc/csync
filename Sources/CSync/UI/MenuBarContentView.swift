import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pendingDeleteProject: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("同步任务")
                .font(.headline)

            Divider()

            if appState.projectStore.projects.isEmpty {
                Text("暂无项目")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleProjects) { project in
                        let task = appState.syncManager.tasks[project.id]
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: statusSymbolName(for: task?.state))
                                        .foregroundStyle(statusColor(for: task?.state))
                                        .font(.caption)
                                    Text(project.name)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text(task?.modeBadgeText ?? (project.autoSync ? "自动" : "手动"))
                                        .font(.caption2)
                                        .foregroundStyle(((task?.triggerKind == .automatic) || (task == nil && project.autoSync)) ? .blue : .secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background((((task?.triggerKind == .automatic) || (task == nil && project.autoSync)) ? Color.blue : Color.gray).opacity(0.12), in: Capsule())
                                    Spacer()
                                    if let task {
                                        Text(task.updatedAt, style: .time)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Text(task?.state.summaryText ?? (project.autoSync ? "自动同步中" : "尚未触发同步"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)

                                if let task {
                                    if task.state.isRunning {
                                        Text(task.runningModeText)
                                            .font(.caption2)
                                            .foregroundStyle(task.triggerKind == .automatic ? .blue : .secondary)
                                    } else if task.state.isQueued {
                                        Text(task.queuedModeText)
                                            .font(.caption2)
                                            .foregroundStyle(task.triggerKind == .automatic ? .blue : .secondary)
                                    } else if project.autoSync {
                                        Text("自动同步中")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                    }
                                } else if project.autoSync {
                                    Text("自动同步中")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }

                                if let progress = task?.state.progressValue {
                                    ProgressView(value: progress)
                                        .progressViewStyle(.linear)
                                }
                            }

                            Menu {
                                Button(controlActionTitle(for: task?.state)) {
                                    runControlAction(for: project, state: task?.state)
                                }

                                Button(autoSyncActionTitle(for: project)) {
                                    toggleAutoSync(for: project)
                                }

                                Divider()

                                Button("编辑") {
                                    appState.requestEditProjectEditor(project: project)
                                }

                                Button("删除", role: .destructive) {
                                    pendingDeleteProject = project
                                }
                            } label: {
                                Label("操作", systemImage: "ellipsis.circle")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if hiddenProjectCount > 0 {
                        Text("其余 \(hiddenProjectCount) 个项目请在主窗口查看")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    appState.syncAllProjects()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("手动同步全部项目")

                Button {
                    appState.requestCreateProjectEditor()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .help("新增项目")

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                } label: {
                    Image(systemName: "macwindow")
                }
                .help("打开主窗口")

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.bordered)
                .help("退出")
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .alert("确认删除项目", isPresented: Binding(
            get: { pendingDeleteProject != nil },
            set: { if !$0 { pendingDeleteProject = nil } }
        )) {
            Button("删除", role: .destructive) {
                guard let project = pendingDeleteProject else { return }
                appState.removeProject(project)
                pendingDeleteProject = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteProject = nil
            }
        } message: {
            Text(pendingDeleteProject.map { "将删除项目“\($0.name)”及其密码信息。" } ?? "")
        }
    }

    private var projectsForMenu: [Project] {
        appState.projectStore.projects.sorted { lhs, rhs in
            let lhsTaskTime = appState.syncManager.tasks[lhs.id]?.updatedAt
            let rhsTaskTime = appState.syncManager.tasks[rhs.id]?.updatedAt

            switch (lhsTaskTime, rhsTaskTime) {
            case let (l?, r?):
                if l != r { return l > r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var maxVisibleProjects: Int { 6 }

    private var visibleProjects: [Project] {
        Array(projectsForMenu.prefix(maxVisibleProjects))
    }

    private var hiddenProjectCount: Int {
        max(0, projectsForMenu.count - maxVisibleProjects)
    }

    private func controlActionTitle(for state: SyncTaskState?) -> String {
        guard let state else { return "手动同步" }

        switch state {
        case .queued, .running:
            return "取消"
        case .failed:
            return "重试"
        case .succeeded, .cancelled:
            return "手动同步"
        }
    }

    private func runControlAction(for project: Project, state: SyncTaskState?) {
        guard let state else {
            appState.syncNow(project: project)
            return
        }

        switch state {
        case .queued, .running:
            appState.syncManager.cancel(projectID: project.id)
        case .failed:
            appState.syncManager.retryFailed(projectID: project.id)
        case .succeeded, .cancelled:
            appState.syncNow(project: project)
        }
    }

    private func autoSyncActionTitle(for project: Project) -> String {
        project.autoSync ? "关闭自动同步" : "开启自动同步"
    }

    private func toggleAutoSync(for project: Project) {
        appState.setAutoSyncEnabled(!project.autoSync, for: project.id)
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
