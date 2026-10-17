import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 顶栏「模型与配置」弹窗：全局配置方案切换、模型列表、导入导出。
///
/// 之所以不用 `Menu`：SwiftUI 的菜单嵌在 `NSPopover` 中时，点击菜单项会被
/// popover 的 transient 行为抢先关闭，导致选择无效。
struct ModelSwitcherView: View {
    @ObservedObject var store = SettingsStore.shared
    @ObservedObject var discovery = ModelDiscoveryStore.shared
    @Binding var isPresented: Bool
    var onOpenSettings: () -> Void = {}

    @State private var probing = false
    @State private var message: String?
    @State private var savingProfile = false
    @State private var newProfileName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("配置方案")
            if store.settings.modelProfiles.isEmpty {
                hint("暂无方案。填好模型后点「保存当前为新方案」，即可成套切换。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(store.settings.modelProfiles) { p in profileRow(p) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 140)
            }
            if savingProfile {
                HStack(spacing: 6) {
                    TextField("方案名称", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { commitSaveProfile() }
                    Button("保存") { commitSaveProfile() }.controlSize(.small)
                    Button("取消") { savingProfile = false }.controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
            } else {
                HStack(spacing: 6) {
                    Button("保存当前为新方案") {
                        newProfileName = suggestedProfileName()
                        savingProfile = true
                    }
                    .controlSize(.small)
                    Button("管理…") { openSettings() }.controlSize(.small)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }

            Divider()

            sectionHeader("模型列表")
            if store.settings.modelList.isEmpty {
                hint("暂无模型。可「加入当前」，或点「探测」从端点拉取。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(store.settings.modelList, id: \.self) { m in modelRow(m) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 170)
            }
            HStack(spacing: 6) {
                Button("加入当前") { store.addModel(store.settings.model) }
                    .controlSize(.small)
                Button(probing ? "探测中…" : "探测模型") { probe() }
                    .controlSize(.small).disabled(probing)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.bottom, 8)

            Divider()

            HStack(spacing: 6) {
                Button("导出配置…") { exportConfig() }.controlSize(.small)
                Button("导入配置…") { importConfig() }.controlSize(.small)
                Spacer()
            }
            .padding(10)

            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .frame(width: 330)
    }

    // MARK: - 组件

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private func profileRow(_ p: ModelProfile) -> some View {
        let active = p.id == store.settings.activeProfileID
        return Button {
            store.selectProfile(id: p.id)
            message = "已切换到「\(p.name)」"
            isPresented = false
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                    Text("\(p.model) · \(APIType.from(p.api).label)")
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if active { Image(systemName: "checkmark").font(.system(size: 10)).foregroundColor(.accentColor) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Color.accentColor.opacity(0.12) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .contextMenu {
            Button("复制") { store.duplicateProfile(id: p.id) }
            Button("删除", role: .destructive) { store.deleteProfile(id: p.id) }
        }
    }

    private func modelRow(_ m: String) -> some View {
        let active = m == store.settings.model
        return HStack(spacing: 4) {
            Button {
                store.settings.model = m
                store.addModel(m)
                message = "已切换到模型「\(m)」"
                isPresented = false
            } label: {
                HStack(spacing: 6) {
                    Text(m).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                    if active { Image(systemName: "checkmark").font(.system(size: 10)).foregroundColor(.accentColor) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { store.removeModel(m) } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("从列表移除")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(active ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }

    // MARK: - 动作

    private func suggestedProfileName() -> String {
        let m = store.settings.model
        return m.isEmpty ? "方案 \(store.settings.modelProfiles.count + 1)" : m
    }

    private func commitSaveProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = store.addProfile(from: store.settings)
        if !name.isEmpty { store.renameProfile(id: p.id, to: name) }
        savingProfile = false
        message = "已保存方案「\(name.isEmpty ? p.name : name)」"
    }

    private func openSettings() {
        onOpenSettings()
        isPresented = false
    }

    private func probe() {
        probing = true
        message = nil
        let s = store.settings
        Task {
            do {
                let ids = try await ModelDiscovery.discover(baseURL: s.baseURL, apiKey: s.apiKey, api: s.api)
                store.addModels(ids)
                discovery.store(ids, baseURL: s.baseURL, api: s.api)
                message = "探测到 \(ids.count) 个模型，已加入列表"
            } catch {
                message = error.localizedDescription
            }
            probing = false
        }
    }

    private func exportConfig() {
        guard let data = store.exportSettings() else { message = "导出失败"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "myna-config.json"
        panel.message = "导出的文件包含 API Key，请妥善保管"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                message = "已导出到 \(url.lastPathComponent)"
            } catch {
                message = "写入失败：\(error.localizedDescription)"
            }
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            message = store.importSettings(from: data) ? "已导入 \(url.lastPathComponent)" : "文件格式不正确"
        }
    }
}
