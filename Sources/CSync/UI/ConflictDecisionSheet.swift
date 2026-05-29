import SwiftUI

struct ConflictDecisionSheet: View {
    @EnvironmentObject private var appState: AppState

    let request: ConflictResolutionRequest

    private var previewFiles: [String] {
        Array(request.conflictingFiles.prefix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("检测到同步冲突")
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("项目：\(request.project.name)")
                    .font(.subheadline)
                Text("冲突文件：\(request.conflictingFiles.count) 个")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !previewFiles.isEmpty {
                GroupBox("冲突样例（最多显示 20 个）") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(previewFiles, id: \.self) { path in
                                Text(path)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 220)
                }
            }

            Text("请选择本次冲突处理策略：")
                .font(.subheadline)

            HStack(spacing: 10) {
                Button("本地覆盖远端") {
                    appState.resolveActiveConflict(.localOverride)
                }
                .buttonStyle(.borderedProminent)

                Button("远端覆盖本地") {
                    appState.resolveActiveConflict(.remoteOverride)
                }
                .buttonStyle(.bordered)

                Button("跳过") {
                    appState.resolveActiveConflict(.skip)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 680, height: 460)
    }
}
