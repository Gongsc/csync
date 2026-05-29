import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var appState: AppState

    private var maxConcurrentBinding: Binding<Int> {
        Binding(
            get: { appState.syncManager.maxConcurrentTasks },
            set: { appState.syncManager.maxConcurrentTasks = $0 }
        )
    }

    var body: some View {
        Form {
            Stepper(value: maxConcurrentBinding, in: 1...8) {
                Text("最大并发任务数：\(appState.syncManager.maxConcurrentTasks)")
            }

            Text("默认自动同步由项目开关控制，使用文件系统事件监听变更，并做 2 秒防抖聚合。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
    }
}
