import SwiftUI
import AppKit

/// 聊天输入栏上方的「模型 + 思考强度」内联面板。
///
/// 面板直接渲染在聊天视图内部（消息列表与输入栏之间），**不使用嵌套 `NSPopover`**：
/// 面板模式的外层本身就是一个 `.transient` 的 `NSPopover`，嵌套弹层会被它抢先判定为
/// 「点击外部」而关闭，导致模型切换动作丢失、内容被裁剪；这与之前 SwiftUI `Menu` 的问题同源。
///
/// 设计目标：**尽量矮**。模型直接列成单行（不再有「切换模型」标题栏），
/// 思考强度压缩成「标签 + 滑块 + 当前值」一行，滑块下方不再铺等级名。
struct ModelControlPanel: View {
    @ObservedObject var store = SettingsStore.shared
    let theme: ChatTheme

    /// 模型列表实测内容高度：`ScrollView` 默认是贪婪的，会直接撑满 `maxHeight`，
    /// 只有少数模型时会留下大片空白；因此测量内容高度后取 `min(内容, 上限)`。
    @State private var listContentHeight: CGFloat = 0

    private var levels: [String] { store.currentModelEntry?.thinkingLevels ?? [] }
    private var selectedLevel: String { store.currentModelEntry?.reasoningEffort ?? "" }
    /// 供应商多于一个时才显示分组标题，单供应商时省掉这一行。
    private var showsProviderTitles: Bool { store.settings.providers.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modelList
            if !levels.isEmpty {
                Divider().padding(.vertical, 5)
                thinkingRow
            }
        }
        .padding(8)
        // 弹窗内的紧凑宽度（不再是内联卡片，不需要对齐到输入栏）。
        .frame(width: 268, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.bubbleStroke, lineWidth: 1))
    }

    // MARK: - 模型列表

    @ViewBuilder
    private var modelList: some View {
        if store.settings.providers.isEmpty {
            Text("暂无供应商，可在「设置 → 模型」中新建。")
                .font(theme.tinyFont).foregroundColor(.secondary)
                .padding(.vertical, 4)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(store.settings.providers) { p in providerGroup(p) }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ModelListHeightKey.self, value: g.size.height)
                })
            }
            .frame(height: min(max(listContentHeight, 1), 168))
            .onPreferenceChange(ModelListHeightKey.self) { listContentHeight = $0 }
        }
    }

    @ViewBuilder
    private func providerGroup(_ p: Provider) -> some View {
        if showsProviderTitles {
            Text(p.name.isEmpty ? "未命名" : p.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 1)
        }
        ForEach(p.models) { m in modelRow(m, provider: p) }
    }

    /// 单行模型行：名称 + 右侧勾选；选中项用强调色，不使用整行填充。
    private func modelRow(_ m: ModelEntry, provider: Provider) -> some View {
        let active = provider.id == store.currentProviderID && m.id == store.currentModelID
        return Button {
            store.selectModel(providerID: provider.id, modelID: m.id)
        } label: {
            HStack(spacing: 6) {
                Text(m.label.isEmpty ? m.name : m.label)
                    .font(.system(size: 12, weight: active ? .medium : .regular, design: .monospaced))
                    .foregroundColor(active ? theme.accent : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if m.discovered {
                    Text("探测")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .opacity(active ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.label.isEmpty ? m.name : m.label)
    }

    // MARK: - 思考强度（压缩为一行）

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

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            Text("思考")
                .font(theme.smallFont)
                .foregroundColor(.secondary)
                .fixedSize()
            Slider(value: levelBinding,
                   in: 0...Double(max(levels.count - 1, 1)),
                   step: 1)
                .controlSize(.mini)
            Text(ThinkingLevel.displayName(selectedLevel))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accent)
                .frame(width: 28, alignment: .trailing)
                .fixedSize()
        }
        .frame(height: 22)
    }
}

/// 测量模型列表内容高度的 preference key。
private struct ModelListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 弹窗开关状态

/// 模型 / 思考强度弹窗的开关状态。
///
/// 由 `ChatView` 的模型按钮切换，`AppDelegate` 据此显示 / 关闭弹窗；
/// 弹窗被外部点击关闭时由 `NSPopoverDelegate` 反向同步，避免按钮箭头状态残留。
@MainActor
final class ModelPopupState: ObservableObject {
    static let shared = ModelPopupState()
    @Published var isOpen = false
    private init() {}
}
