import SwiftUI
import AppKit

/// 命令面板里的一条可执行项。
struct PaletteItem: Identifiable {
    let id = UUID()
    /// 分组标题（会话 / 动作 / 提示词）。
    let group: String
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    /// 供搜索匹配的文本（标题 + 副标题 + 分组）。
    var searchText: String { "\(group) \(title) \(subtitle)".lowercased() }
}

/// ⌘K 命令面板。
///
/// 直接在聊天视图中以覆盖层呈现（不是嵌套 `NSPopover`——那会在面板模式下被外层抢先关闭）。
/// 支持：模糊筛选、↑↓ 选择、⏎ 执行、Esc 关闭。
struct CommandPalette: View {
    let theme: ChatTheme
    let items: [PaletteItem]
    /// 消息全文搜索：随输入实时求值（父视图预建会在打字时不更新）。
    var messageSearch: ((String) -> [PaletteItem])? = nil
    /// 初始查询（调试/自动化预填）。
    var initialQuery: String = ""
    var onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @State private var cachedQuery = ""
    @State private var cachedMessageHits: [PaletteItem] = []
    @FocusState private var focused: Bool

    /// 命令/会话/设置/提示词条目（本地过滤）。
    private var staticMatches: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        let words = q.split(separator: " ").map(String.init)
        return items.filter { item in
            words.allSatisfy { item.searchText.contains($0) }
        }
    }

    /// 合并静态条目与消息搜索结果（消息结果排在后面，避免压过命令项）。
    private var filtered: [PaletteItem] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 1 else { return items }
        return staticMatches + cachedMessageHits
    }

    /// 按分组聚合，保持原始顺序。
    private var grouped: [(String, [PaletteItem])] {
        var order: [String] = []
        var map: [String: [PaletteItem]] = [:]
        for item in filtered {
            if map[item.group] == nil { order.append(item.group) }
            map[item.group, default: []].append(item)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command").font(.system(size: 12)).foregroundColor(.secondary)
                TextField("搜索会话、执行动作、插入提示词…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { run() }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("清除")
                }
                Text("esc").font(.system(size: 9, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08))
                    .cornerRadius(3)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            Divider()

            if filtered.isEmpty {
                Text("没有匹配项")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(grouped.enumerated()), id: \.offset) { _, entry in
                            Text(entry.0)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                            ForEach(entry.1) { item in
                                row(item)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.bubbleStroke, lineWidth: 1))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
        .onChange(of: query) { value in
            selection = 0
            refreshMessageHits(for: value)
        }
        .onAppear {
            if query.isEmpty, !initialQuery.isEmpty {
                query = initialQuery
                refreshMessageHits(for: initialQuery)
            }
            focused = true
            selection = 0
        }
        .onExitCommand { onClose() }
    }

    /// 只在查询变化时扫描一次消息正文（避免每次重绘都全量扫描）。
    private func refreshMessageHits(for value: String) {
        let q = value.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let messageSearch else {
            cachedQuery = q
            cachedMessageHits = []
            return
        }
        guard q != cachedQuery else { return }
        cachedQuery = q
        cachedMessageHits = messageSearch(q)
    }

    private func row(_ item: PaletteItem) -> some View {
        let index = filtered.firstIndex(where: { $0.id == item.id }) ?? 0
        let active = index == selection
        return Button {
            run(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 11))
                    .foregroundColor(active ? theme.accent : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12, weight: active ? .medium : .regular))
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? theme.accent.opacity(0.14) : Color.clear)
            .cornerRadius(6)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selection = index } }
    }

    private func run(_ item: PaletteItem? = nil) {
        let target = item ?? filtered[safe: selection]
        onClose()
        target?.action()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
