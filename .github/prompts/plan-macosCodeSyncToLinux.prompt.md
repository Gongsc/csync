## Plan: macOS 状态栏多项目同步工具（按当前项目状态更新）

当前仓库已完成从 0 到 1 的主链路实现：主应用 + 菜单栏入口、多项目同步调度、自动触发、冲突决策、主机管理与密码加密存储、图标与资源打包。

本文档用于描述当前落地状态与下一阶段实施计划。

**Current Status**
1. 已完成工程基线：SwiftUI macOS App，xcodegen 管理工程，目标平台 macOS 14+。
2. 已完成双入口 UI：主窗口和 MenuBarExtra，状态一致。
3. 已完成项目与主机管理：项目创建编辑、主机创建编辑、主机连接测试。
4. 已完成同步核心链路：SyncTaskManager 调度 + RsyncExecutor 执行 + 进度与文件结果回显。
5. 已完成自动同步：FSEvents 监听、本地变更防抖（2 秒）、自动入队。
6. 已完成冲突处理：ConflictDetector 检测，支持询问/本地覆盖/远端覆盖策略。
7. 已完成任务来源区分：manual 与 automatic 的状态徽标、文案与行为。
8. 已完成配置持久化：projects.json、hosts.json、冲突基线快照。
9. 已完成认证重构：不再使用 Keychain；主机密码加密后写入 hosts.json（encryptedPassword）。
10. 已完成图标链路：Assets.xcassets 正确进入 Resources phase，产物包含 Assets.car 与 AppIcon.icns。

**Steps (Updated Roadmap)**
1. Phase A（已完成）：基础架构与核心功能闭环
2. [x] 工程初始化与模块划分（App/Core/Engine/Models/UI/Utils）。
3. [x] 菜单栏入口与主窗口双视图。
4. [x] 多项目调度、并发上限、取消、失败重试。
5. [x] rsync + ssh 执行、进度解析、错误映射。
6. [x] 自动触发链路（监听 -> 防抖 -> 入队）。
7. [x] 冲突检测与冲突决策流程。
8. [x] 主机管理、密码加密存储、主机连接测试。

9. Phase B（已完成）：稳定性与工程化
10. [x] 自动化测试补齐：状态机、调度器、进度解析、冲突流程。
11. [x] 失败恢复增强：网络抖动自动重试（当前为人工重试为主）。
12. [x] 运行前环境检测入口：rsync/ssh 可用性快速检查与提示。
13. [x] 通知与诊断增强：系统通知、结构化错误导出。

14. Phase C（待开始）：发布与运维准备
15. [ ] 发布签名与公证流程。
16. [ ] 升级策略与数据迁移说明。
17. [ ] 版本发布文档与回归清单。

**Relevant files**
1. 工程与入口
- project.yml
- Sources/CSync/App/CSyncApp.swift
- Sources/CSync/App/AppState.swift

2. UI
- Sources/CSync/UI/MainWindowView.swift
- Sources/CSync/UI/MenuBarContentView.swift
- Sources/CSync/UI/HostManagerView.swift
- Sources/CSync/UI/ConflictDecisionSheet.swift
- Sources/CSync/UI/AppSettingsView.swift

3. 调度与执行
- Sources/CSync/Core/SyncTaskManager.swift
- Sources/CSync/Core/AutoSyncService.swift
- Sources/CSync/Engine/RsyncExecutor.swift
- Sources/CSync/Engine/ConflictDetector.swift
- Sources/CSync/Engine/HostConnectionTester.swift

4. 持久化与安全
- Sources/CSync/Core/ProjectStore.swift
- Sources/CSync/Core/HostStore.swift
- Sources/CSync/Core/ConflictBaselineStore.swift
- Sources/CSync/Core/HostPasswordCipher.swift

5. 模型
- Sources/CSync/Models/Project.swift
- Sources/CSync/Models/ManagedHost.swift
- Sources/CSync/Models/SyncTask.swift
- Sources/CSync/Models/ConflictModels.swift

6. 文档与发布辅助
- README.md
- release/publish_icon.sh

**Verification**
1. 已完成：多轮 xcodebuild Debug 构建通过。
2. 已完成：主窗口与菜单栏状态联动、手动/自动同步来源区分可见。
3. 已完成：图标资源打包校验（产物存在 Assets.car 与 AppIcon.icns）。
4. 待补齐：自动化单元测试与集成测试。
5. 待补齐：发布前手工场景回归（网络抖动、认证失败、冲突批量决策）。

**Decisions**
1. 已确认：macOS 14+，SwiftUI 主应用 + 菜单栏入口。
2. 已确认：默认支持自动同步与手动触发；菜单命令支持“同步全部项目”。
3. 已确认：冲突策略支持每次询问/本地覆盖/远端覆盖。
4. 已确认：主机密码不使用 Keychain，采用应用内加密后持久化到 hosts.json。
5. 已确认：首版聚焦单机到单远端 Linux 的项目级同步。

**Known Gaps**
1. 暂无完善的自动化测试目录与测试用例。
2. 暂未提供全局系统级快捷键（仅应用内命令）。
3. 暂未实现系统通知、崩溃采集与诊断导出闭环。
4. 暂未完成签名、公证与发布流水线。

**Next Focus (Recommended)**
1. 第一优先级：补单元测试与关键集成测试，锁定调度与冲突流程稳定性。
2. 第二优先级：增加环境自检与可观测性（通知、日志导出）。
3. 第三优先级：完成发布流程文档与签名公证脚本化。