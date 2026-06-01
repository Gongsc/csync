# CSync

CSync 是一个基于 SwiftUI 的 macOS 本地代码同步工具。

目标场景：把本地项目目录同步到远程 Linux 主机，支持手动同步与自动同步，并在主窗口和状态栏展示任务状态。

## 核心能力

- 多项目管理
- 主机管理（地址、用户名、密码）
- 主机密码加密存储（不依赖 macOS 钥匙串）
- 手动同步、批量同步
- 自动同步（基于文件系统事件监听 + 防抖）
- 冲突检测与冲突处理策略
- 同步任务状态与文件级结果展示
- 菜单栏快速查看任务与操作

## 技术栈

- Swift 6
- SwiftUI
- xcodegen
- rsync + ssh

## 目录结构

- Sources/CSync/App：应用入口与全局状态
- Sources/CSync/Core：存储、任务调度、自动同步
- Sources/CSync/Engine：rsync/ssh 执行、冲突检测
- Sources/CSync/Models：数据模型
- Sources/CSync/UI：主窗口、主机管理、设置、状态栏
- CSync/Assets.xcassets：图标与资源
- project.yml：xcodegen 工程定义

## 环境要求

- macOS 14+
- Xcode 15+
- xcodegen
- 系统可用 ssh
- 系统可用 rsync

可用以下命令检查依赖：

  xcodebuild -version
  xcodegen --version
  which ssh
  which rsync

## 快速开始

1. 生成 Xcode 工程

  xcodegen generate

2. 打开工程

  open CSync.xcodeproj

3. 在 Xcode 里选择 CSync scheme，直接 Run

## 命令行构建

  xcodebuild -project CSync.xcodeproj -scheme CSync -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

## 使用说明

### 1) 新建主机

在主窗口点击主机管理，填写：

- 主机名称
- 主机地址
- 用户名
- SSH 密码（可留空，表示优先走公钥）

可以先点测试连接，再保存。

### 2) 新建项目

在主窗口新增项目并填写：

- 项目名称
- 主机配置（从已保存主机中选择）
- 本地目录
- 远端路径
- 冲突默认处理策略
- 排除规则

### 3) 手动同步

- 在项目详情点击手动同步
- 或在顶部点击手动同步全部项目

### 4) 自动同步

- 对项目开启自动同步
- 文件变更后会自动触发同步
- 默认有 2 秒防抖聚合

### 5) 冲突处理

支持三种策略：

- 每次询问
- 本地覆盖远端
- 远端覆盖本地

## 数据与配置存储

运行后会在用户目录写入：

- ~/Library/Application Support/CSync/projects.json
- ~/Library/Application Support/CSync/hosts.json
- ~/Library/Application Support/CSync/conflict-baselines/

说明：

- hosts.json 中主机密码以密文形式存储在 encryptedPassword 字段
- 密码在内存中按需解密用于连接与同步

## 图标资源

图标资源来自 CSync/Assets.xcassets/AppIcon.appiconset。

若需要导出 icns，可执行：

  bash release/publish_icon.sh

## 常见问题

### 图标不显示

- 确保先执行 xcodegen generate 再构建
- 确保工程包含 Assets.xcassets 资源构建阶段
- 清理后重新构建：Product -> Clean Build Folder

### 同步失败（认证相关）

- 检查主机地址、用户名、密码是否正确
- 如果使用公钥，确认远端 authorized_keys 与权限设置
- 先在主机管理中执行测试连接

### 自动同步没有触发

- 确认项目已开启自动同步
- 确认本地目录真实存在
- 确认变更文件不在排除规则中

## 开发说明

- 本仓库使用 xcodegen 管理工程，建议优先修改 project.yml
- 修改 project.yml 后执行 xcodegen generate 以同步 CSync.xcodeproj

## 版本

当前版本：1.2.0

## 许可证

本项目采用 GNU General Public License v3.0（GPL-3.0）。

详见 [LICENSE](LICENSE)。
