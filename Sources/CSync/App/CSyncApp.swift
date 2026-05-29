import SwiftUI

@main
struct CSyncApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("CSync") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 620)
        }
        .commands {
            CommandMenu("同步") {
                Button("同步全部项目") {
                    appState.syncAllProjects()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appState)
                .frame(width: 380)
        } label: {
            Label("CSync", systemImage: appState.menuBarSymbolName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppSettingsView()
                .environmentObject(appState)
                .frame(width: 420)
                .padding(16)
        }
    }
}
