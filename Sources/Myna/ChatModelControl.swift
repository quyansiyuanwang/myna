import SwiftUI
import AppKit

/// 聊天输入栏上方的「模型 + 思考强度」内联面板。
///
/// 面板直接渲染在聊天视图内部（消息列表与输入栏之间），**不使用嵌套 `NSPopover`**：
/// 面板模式的外层本身就是一个 `.transient` 的 `NSPopover`，嵌套弹层会被它抢先判定为
/// 「点击外部」而关闭，导致模型切换动作丢失、内容被裁剪；这与之前 SwiftUI `Menu` 的问题同源。
///
/// 顶部是「切换模型」行，点击后就地展开供应商 → 模型列表；
/// 下方是思考强度滑块，拖动即切换当前模型的等级（实时写入模型条目与扁平字段）。
struct ModelControlPanel: View {
    @ObservedObject var store = SettingsStore.shared
    let theme: ChatTheme

    /// 是否展开内联模型下拉（默认收起，面板首次打开时保持紧凑）。
    @State private var modelListExpanded = false

    private var levels: [String] { store.currentModelEntry?.thinkingLevels ?? [] }
    private var selectedLevel: String { store.currentModelEntry?.reasoningEffort ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modelSwitcherRow
            if modelListExpanded {
                modelList.padding(.top, 6)
            }
            Divider().padding(.vertical, 8)
            thinkingSection
        }
        .padding(theme.density.contentPadding)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.toolBubble))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.bubbleStroke, lineWidth: 1))
        .padding(.horizontal, theme.density.contentPadding)
        .padding(.bottom, 8)
    }

    // MARK: - 切换模型

    /// 顶部整行：标题 + 当前模型名 + 会旋转的箭头，点击展开 / 收起内联下拉。
    private var modelSwitcherRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { modelListExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cube")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("切换模型").font(theme.tinyFont).foregroundColor(.secondary)
                    Text(store.currentModelLabel.isEmpty ? "未选择" : store.currentModelLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(modelListExpanded ? 180 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var modelList: some View {
        if store.settings.providers.isEmpty {
            Text("暂无供应商。可在「设置 → 模型」中新建。")
                .font(theme.tinyFont).foregroundColor(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 6)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.settings.providers) { p in providerSection(p) }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 220)
        }
    }

    /// 一个供应商：头部是 `server.rack` + 半粗名称，下方直接列出它的模型。
    private func providerSection(_ p: Provider) -> some View {
        let active = p.id == store.currentProviderID
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 11))
                    .foregroundColor(active ? theme.accent : .secondary)
                Text(p.name.isEmpty ? "未命名" : p.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(active ? theme.accent : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if active {
                    Text("当前")
                        .font(.system(size: 8))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(theme.accent.opacity(0.16))
                        .foregroundColor(theme.accent)
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)

            if p.models.isEmpty {
                Text("暂无模型")
                    .font(theme.tinyFont).foregroundColor(.secondary)
                    .padding(.leading, 22)
            } else {
                ForEach(p.models) { m in modelRow(m, provider: p) }
            }
        }
    }

    /// 模型行：`cube` + 等宽字体，选中项用强调色标记；点击后收起下拉，面板保持打开。
    private func modelRow(_ m: ModelEntry, provider: Provider) -> some View {
        let active = provider.id == store.currentProviderID && m.id == store.currentModelID
        return Button {
            store.selectModel(providerID: provider.id, modelID: m.id)
            withAnimation(.easeInOut(duration: 0.15)) { modelListExpanded = false }
        } label: {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(active ? theme.accent : Color.clear)
                    .frame(width: 2)
                Image(systemName: "cube")
                    .font(.system(size: 9))
                    .foregroundColor(active ? theme.accent : .secondary)
                Text(m.label.isEmpty ? m.name : m.label)
                    .font(.system(size: 11, weight: active ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(active ? theme.accent : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(minHeight: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 思考强度

    /// 滑块取值：`0...levels.count - 1` 的离散下标；越界或空等级时钳到 0。
    private var levelBinding: Binding<Double> {
        Binding(
            get: {
                guard let i = levels.firstIndex(of: selectedLevel) else { return 0 }
                return Double(i)
            },
            set: { raw in
                guard !levels.isEmpty else { return }
                let i = max(0, min(levels.count - 1, Int(raw.rounded())))
                let level = levels[i]
                if level != selectedLevel { store.updateCurrentReasoning(effort: level) }
            }
        )
    }

    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("思考强度").font(theme.smallFont).foregroundColor(.secondary)
                Spacer(minLength: 0)
                if !levels.isEmpty {
                    Text(ThinkingLevel.displayName(selectedLevel))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accent)
                }
            }
            if levels.isEmpty {
                Text("该模型未声明可用的思考强度")
                    .font(theme.tinyFont).foregroundColor(.secondary)
            } else {
                Slider(value: levelBinding,
                       in: 0...Double(max(levels.count - 1, 1)),
                       step: 1)
                    .controlSize(.small)
                // 离散等级名均匀铺在滑块下方，让每一步都一目了然。
                HStack(spacing: 0) {
                    ForEach(levels, id: \.self) { level in
                        Text(ThinkingLevel.displayName(level))
                            .font(.system(size: 9))
                            .foregroundColor(level == selectedLevel ? theme.accent : .secondary)
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
