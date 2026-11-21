// 设置窗口：电脑名、备份位置、开机自动启动。
import AppKit
import ServiceManagement
import SwiftUI

struct EchoSettingsView: View {
    @State private var name = EchoPrefs.computerName
    @State private var root = EchoPrefs.backupRoot.path
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("电脑名").font(.subheadline.bold())
                TextField(EchoPrefs.defaultComputerName, text: $name)
                    .onSubmit(saveName)
                Text("两台电脑用不同的名字，备份各放一个文件夹").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("备份位置").font(.subheadline.bold())
                HStack {
                    Text(root).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择…", action: pick)
                }
                Text("放在 iCloud 同步的文件夹里，两台电脑都能看到全部会话").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("开机自动启动", isOn: $login).onChange(of: login) { _, on in setLogin(on) }
                if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
        .padding(EdgeInsets(top: 44, leading: 32, bottom: 28, trailing: 32))
        .frame(width: 480)
        .onDisappear(perform: saveName)
    }

    private func saveName() {
        guard name.trimmed != EchoPrefs.computerName else { return }
        EchoPrefs.computerName = name
        name = EchoPrefs.computerName
        EchoState.shared.lastSuccess = nil   // 换了文件夹，当天要重新备份一次
        EchoState.shared.backupNow()
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = EchoPrefs.backupRoot
        guard p.runModal() == .OK, let u = p.url else { return }
        EchoPrefs.backupRoot = u
        root = u.path
        EchoState.shared.lastSuccess = nil
        EchoState.shared.backupNow()
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            login = SMAppService.mainApp.status == .enabled
        }
    }
}
