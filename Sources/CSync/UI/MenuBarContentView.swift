import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("menuBarConfirmQuitEnabled") private var menuBarConfirmQuitEnabled = true
    @State private var pendingDeleteProject: Project?
    @State private var activeSubmenuProjectID: UUID?
    @State private var pendingSubmenuCloseWorkItem: DispatchWorkItem?
    @State private var hoveredProjectRowID: UUID?
    @State private var projectRowFrames: [UUID: CGRect] = [:]
    @State private var menuWindow: NSWindow?
    @StateObject private var submenuPanelController = SubmenuPanelController()

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
                        HStack(spacing: 8) {
                            Image(systemName: statusSymbolName(for: project))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusColor(for: project))
                                .frame(width: 14)
                                .help(statusHelpText(for: project))

                            Text(project.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(hostConfigText(for: project))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 170, alignment: .center)

                            Text(project.autoSync ? "自动" : "手动")
                                .font(.caption2)
                                .foregroundStyle(project.autoSync ? .blue : .secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background((project.autoSync ? Color.blue : Color.gray).opacity(0.12), in: Capsule())

                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            if isHovering {
                                hoveredProjectRowID = project.id
                                openSubmenu(for: project.id)
                            } else {
                                if hoveredProjectRowID == project.id {
                                    hoveredProjectRowID = nil
                                }
                                scheduleSubmenuClose(for: project.id)
                            }
                        }
                        .onTapGesture {
                            openSubmenu(for: project.id)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill((hoveredProjectRowID == project.id || activeSubmenuProjectID == project.id) ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(
                                        key: ProjectRowFramePreferenceKey.self,
                                        value: [project.id: proxy.frame(in: .global)]
                                    )
                            }
                        )
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
                HoverIconButton(systemImage: "arrow.triangle.2.circlepath", helpText: "手动同步全部项目") {
                    appState.syncAllProjects()
                }

                HoverIconButton(systemImage: "plus.circle", helpText: "新增项目") {
                    appState.requestCreateProjectEditor()
                }

                HoverIconButton(systemImage: "macwindow", helpText: "打开主窗口") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }

                Spacer()

                HoverIconButton(systemImage: "power", helpText: "退出", isDestructive: true) {
                    requestTerminateApp()
                }
            }
        }
        .padding(12)
        .background(WindowAccessor(window: $menuWindow))
        .onPreferenceChange(ProjectRowFramePreferenceKey.self) { frames in
            projectRowFrames = frames
            if let activeSubmenuProjectID {
                presentSubmenuPanel(for: activeSubmenuProjectID)
            }
        }
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
        .onDisappear {
            cancelPendingSubmenuClose()
            submenuPanelController.close()
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

    private func autoSyncTitle(for project: Project) -> String {
        project.autoSync ? "✓ 自动同步" : "自动同步"
    }

    private func hostConfigText(for project: Project) -> String {
        "\(project.remoteUser)@\(project.remoteHost)"
    }

    private func taskState(for project: Project) -> SyncTaskState? {
        appState.syncManager.tasks[project.id]?.state
    }

    private func statusSymbolName(for project: Project) -> String {
        guard let state = taskState(for: project) else {
            return "circle"
        }

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

    private func statusColor(for project: Project) -> Color {
        guard let state = taskState(for: project) else {
            return .secondary
        }

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

    private func statusHelpText(for project: Project) -> String {
        guard let state = taskState(for: project) else {
            return "尚未同步"
        }

        switch state {
        case .queued:
            return "同步排队中"
        case .running:
            return "同步进行中"
        case .succeeded:
            return "最近一次同步成功"
        case .failed:
            return "最近一次同步失败"
        case .cancelled:
            return "同步已取消"
        }
    }

    private func requestTerminateApp() {
        guard menuBarConfirmQuitEnabled else {
            terminateApplication()
            return
        }

        presentQuitConfirmationAlert()
    }

    private func presentQuitConfirmationAlert() {
        let alert = NSAlert()
        alert.messageText = "确认退出 CSync"
        alert.informativeText = "退出后将停止当前自动同步任务。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        terminateApplication()
    }

    private func terminateApplication() {
        let app = NSApplication.shared
        _ = app.sendAction(#selector(NSApplication.terminate(_:)), to: nil, from: nil)

        // Fallback for menu-bar-only interaction contexts where the first quit request can be swallowed.
        DispatchQueue.main.async {
            app.terminate(nil)
        }
    }

    private func submenuView(for project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            submenuButton(title: "立即同步", helpText: "立即触发该项目同步") {
                appState.syncNow(project: project)
                activeSubmenuProjectID = nil
            }

            submenuButton(
                title: autoSyncTitle(for: project),
                helpText: project.autoSync ? "关闭该项目自动同步" : "开启该项目自动同步"
            ) {
                appState.setAutoSyncEnabled(!project.autoSync, for: project.id)
                activeSubmenuProjectID = nil
            }

            Divider()
                .padding(.vertical, 4)

            submenuButton(title: "编辑", helpText: "编辑该项目配置") {
                appState.requestEditProjectEditor(project: project)
                activeSubmenuProjectID = nil
            }

            submenuButton(title: "删除", helpText: "删除该项目及其配置", isDestructive: true) {
                pendingDeleteProject = project
                activeSubmenuProjectID = nil
            }
        }
        .padding(6)
        .frame(width: submenuWidth(for: project), alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.25), lineWidth: 0.6)
        )
    }

    private func submenuButton(title: String, helpText: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        HoverSubmenuButton(title: title, helpText: helpText, isDestructive: isDestructive, action: action)
    }

    private func openSubmenu(for projectID: UUID) {
        cancelPendingSubmenuClose()
        activeSubmenuProjectID = projectID
        hoveredProjectRowID = projectID
        presentSubmenuPanel(for: projectID)
    }

    private func scheduleSubmenuClose(for projectID: UUID) {
        guard activeSubmenuProjectID == projectID else { return }

        cancelPendingSubmenuClose()
        let workItem = DispatchWorkItem {
            if activeSubmenuProjectID == projectID {
                activeSubmenuProjectID = nil
                submenuPanelController.close()
                if hoveredProjectRowID == projectID {
                    hoveredProjectRowID = nil
                }
            }
        }
        pendingSubmenuCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: workItem)
    }

    private func cancelPendingSubmenuClose() {
        pendingSubmenuCloseWorkItem?.cancel()
        pendingSubmenuCloseWorkItem = nil
    }

    private func presentSubmenuPanel(for projectID: UUID) {
        guard let project = visibleProjects.first(where: { $0.id == projectID }) else { return }
        guard let rowFrame = projectRowFrames[projectID] else { return }

        let content = submenuView(for: project)
            .onHover { isHoveringSubmenu in
                if isHoveringSubmenu {
                    cancelPendingSubmenuClose()
                    activeSubmenuProjectID = project.id
                } else {
                    scheduleSubmenuClose(for: project.id)
                }
            }

        submenuPanelController.show(anchorFrame: rowFrame, menuWindow: menuWindow, content: content)
    }
}

private struct ProjectRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            window = nsView.window
        }
    }
}

private struct HoverSubmenuButton: View {
    let title: String
    let helpText: String
    let isDestructive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(isDestructive ? Color.red : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? hoverColor : Color.clear)
                )
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .onHover { isHovering = $0 }
        .help(helpText)
    }

    private var hoverColor: Color {
        isDestructive ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.12)
    }
}

private extension MenuBarContentView {
    func submenuWidth(for project: Project) -> CGFloat {
        let titles = [
            "立即同步",
            autoSyncTitle(for: project),
            "编辑",
            "删除"
        ]

        let font = NSFont.systemFont(ofSize: 13)
        let textWidth = titles
            .map { title in
                NSString(string: title).size(withAttributes: [.font: font]).width
            }
            .max() ?? 0

        let horizontalPadding: CGFloat = 10 * 2
        let containerPadding: CGFloat = 6 * 2
        return ceil(textWidth + horizontalPadding + containerPadding)
    }
}

@MainActor
private final class SubmenuPanelController: ObservableObject {
    private var panel: NSPanel?

    func show<Content: View>(anchorFrame: CGRect, menuWindow: NSWindow?, content: Content) {
        let hostingView = NSHostingView(rootView: content)
        hostingView.wantsLayer = true

        let fitting = hostingView.fittingSize
        let width = max(fitting.width, 120)
        let height = max(fitting.height, 40)

        let frame = panelFrame(
            anchorFrame: anchorFrame,
            panelSize: CGSize(width: width, height: height),
            menuWindow: menuWindow
        )

        if panel == nil {
            let newPanel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.hidesOnDeactivate = false
            newPanel.level = .floating
            newPanel.collectionBehavior = [.transient, .fullScreenAuxiliary]
            panel = newPanel
        }

        panel?.contentView = hostingView
        panel?.setFrame(frame, display: true)
        panel?.orderFront(nil)
    }

    private func panelFrame(anchorFrame: CGRect, panelSize: CGSize, menuWindow: NSWindow?) -> CGRect {
        let horizontalGap: CGFloat = 6
        let screen = menuWindow?.screen ?? NSScreen.main

        var x = anchorFrame.maxX + horizontalGap
        var rowMidY = anchorFrame.midY

        if let menuWindow {
            // `GeometryProxy.frame(in: .global)` may differ by coordinate space; pick the Y estimate closest to cursor.
            let mouseY = NSEvent.mouseLocation.y
            let candidateWindowBase = menuWindow
                .convertToScreen(NSRect(origin: anchorFrame.origin, size: anchorFrame.size))
                .midY
            let candidateFlipped = menuWindow.frame.maxY - anchorFrame.midY

            rowMidY = abs(candidateWindowBase - mouseY) <= abs(candidateFlipped - mouseY)
                ? candidateWindowBase
                : candidateFlipped

            x = menuWindow.frame.maxX + horizontalGap
        }

        var y = rowMidY - panelSize.height / 2

        if let visibleFrame = screen?.visibleFrame {
            if x + panelSize.width > visibleFrame.maxX - 4, let menuWindow {
                x = menuWindow.frame.minX - horizontalGap - panelSize.width
            }

            y = min(max(y, visibleFrame.minY + 4), visibleFrame.maxY - panelSize.height - 4)
        }

        return CGRect(origin: CGPoint(x: x, y: y), size: panelSize)
    }

    func close() {
        panel?.orderOut(nil)
    }

    deinit {
        let panel = panel
        Task { @MainActor in
            panel?.orderOut(nil)
        }
    }
}

private struct HoverIconButton: View {
    let systemImage: String
    let helpText: String
    var isDestructive: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(foregroundColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor)
                )
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .onHover { isHovering = $0 }
        .help(helpText)
    }

    private var foregroundColor: Color {
        if isDestructive {
            return isHovering ? .red : .primary
        }
        return .primary
    }

    private var backgroundColor: Color {
        if isDestructive {
            return isHovering ? Color.red.opacity(0.12) : Color.clear
        }
        return isHovering ? Color.accentColor.opacity(0.14) : Color.clear
    }
}
