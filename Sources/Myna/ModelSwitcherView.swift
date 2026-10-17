import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 顶栏「配置方案与模型」弹窗：配置方案切换、供应商 → 模型两级切换、导入导出。
///
/// 之所以不用 `Menu`：SwiftUI 的菜单嵌在 `NSPopover` 中时，点击菜单项会被
/// popover 的 transient 行为抢先关闭，导致选择无效。
struct ModelSwitcherView: View {
    @ObservedObject var store = SettingsStore.shared
    @Binding var isPresented: Bool
    var onOpenSettings: () -> Void = {}

    @State private var profiles: [String] = []
    @State private var expandedProviderID: UUID?
    @State private var savingProfile = false
    @State private var newProfileName = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: 配置方案
            sectionHeader("配置方案")
            if profiles.isEmpty {
                hint("暂无方案。保存后可在任意设置组合之间一键切换。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(profiles, id: \.self) { name in profileRow(name) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 132)
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

            // MARK: 供应商 → 模型
            sectionHeader("供应商 / 模型")
            Text("当前：\(currentSelectionLabel)")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 4)
            if store.settings.providers.isEmpty {
                hint("暂无供应商。可在「设置 → 模型」中新建。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(store.settings.providers) { p in
                            providerRow(p)
                            if expandedProviderID == p.id {
                                ForEach(p.models) { m in modelRow(m, provider: p) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 236)
            }

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
        .frame(width: 340)
        .onAppear {
            profiles = store.listProfiles()
            expandedProviderID = store.currentProviderID
        }
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

    private func profileRow(_ name: String) -> some View {
        Button {
            if store.applyProfile(named: name) {
                message = "已应用方案「\(name)」"
                isPresented = false
            } else {
                message = "读取方案「\(name)」失败"
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 10)).foregroundColor(.secondary)
                Text(name).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .contextMenu {
            Button("导出…") { exportProfile(named: name) }
            Button("删除", role: .destructive) {
                store.deleteProfile(named: name)
                profiles = store.listProfiles()
                message = "已删除方案「\(name)」"
            }
        }
    }

    /// 顶栏显示的当前选择。
    private var currentSelectionLabel: String {
        guard let pid = store.currentProviderID,
              let provider = store.settings.providers.first(where: { $0.id == pid }) else { return "未选择" }
        let name = provider.name.isEmpty ? "未命名" : provider.name
        if let entry = store.currentModelEntry { return "\(name) / \(entry.label)" }
        return name
    }

    private func providerRow(_ p: Provider) -> some View {
        let current = p.id == store.currentProviderID
        let expanded = p.id == expandedProviderID
        return HStack(spacing: 6) {
            // 箭头只负责展开 / 收起，不改变当前供应商。
            Button {
                expandedProviderID = expanded ? nil : p.id
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8)).foregroundColor(.secondary)
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 行体切换当前供应商并关闭弹窗。
            Button {
                store.selectProvider(id: p.id)
                message = "已切换到供应商「\(p.name)」"
                isPresented = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: current ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundColor(current ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name.isEmpty ? "未命名" : p.name)
                            .font(.system(size: 12, weight: current ? .semibold : .regular))
                            .lineLimit(1)
                        Text("\(APIType.from(p.api).label) · \(p.models.count) 个模型")
                            .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .background(current ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }

    private func modelRow(_ m: ModelEntry, provider: Provider) -> some View {
        let active = m.id == store.currentModelID
        return Button {
            store.selectModel(providerID: provider.id, modelID: m.id)
            message = "已切换到模型「\(m.name)」"
            isPresented = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundColor(active ? .accentColor : .secondary)
                Text(m.label).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                if m.discovered {
                    Text("探测").font(.system(size: 8))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.14))
                        .cornerRadius(3)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 26).padding(.trailing, 8).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    // MARK: - 动作

    private func suggestedProfileName() -> String {
        let base = store.currentModelLabel
        return base.isEmpty ? "方案 \(profiles.count + 1)" : base
    }

    private func commitSaveProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { savingProfile = false; return }
        let existed = profiles.contains(name)
        if store.saveProfile(named: name) {
            message = existed ? "已覆盖方案「\(name)」" : "已保存方案「\(name)」"
        } else {
            message = "保存方案失败"
        }
        savingProfile = false
        profiles = store.listProfiles()
    }

    private func openSettings() {
        onOpenSettings()
        isPresented = false
    }

    private func exportProfile(named name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "myna-\(name).json"
        panel.message = "导出的方案包含 API Key，请妥善保管"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = store.exportProfile(named: name, to: url)
            ? "已导出到 \(url.lastPathComponent)"
            : "导出失败"
    }

    private func exportConfig() {
        guard let data = store.exportSettings() else { message = "导出失败"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "myna-config.json"
        panel.message = "导出的文件包含 API Key，请妥善保管"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            message = "已导出到 \(url.lastPathComponent)"
        } catch {
            message = "写入失败：\(error.localizedDescription)"
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        message = store.importSettings(from: data) ? "已导入 \(url.lastPathComponent)" : "文件格式不正确"
    }
}
