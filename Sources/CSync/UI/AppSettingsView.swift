import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var appState: AppState

    private static let checkTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private var maxConcurrentBinding: Binding<Int> {
        Binding(
            get: { appState.syncManager.maxConcurrentTasks },
            set: { appState.syncManager.maxConcurrentTasks = $0 }
        )
    }

    var body: some View {
        Form {
            Section("同步") {
                Stepper(value: maxConcurrentBinding, in: 1...8) {
                    Text("最大并发任务数：\(appState.syncManager.maxConcurrentTasks)")
                }

                Text("默认自动同步由项目开关控制，使用文件系统事件监听变更，并做 2 秒防抖聚合。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("运行环境") {
                Button("运行环境检查") {
                    appState.runEnvironmentCheck()
                }

                if let status = appState.latestEnvironmentStatus {
                    Text("检查时间：\(Self.checkTimeFormatter.string(from: status.checkedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if status.isHealthy {
                        Text("环境正常，可执行路径：rsync=\(status.rsyncPath ?? "-")，ssh=\(status.sshPath ?? "-")")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text(status.issues.joined(separator: "\n"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("诊断") {
                Button("导出诊断日志") {
                    appState.exportDiagnostics()
                }

                if let url = appState.latestDiagnosticsExportURL {
                    Text("已导出：\(url.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("尚未导出日志，或当前无可导出的诊断数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
    }
}
