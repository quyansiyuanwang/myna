import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 会话管理弹窗：切换 / 新建 / 重命名 / 删除 / 导出 / 导入。
struct ConversationListView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var convos = ConversationStore.shared
    @Binding var isPresented: Bool
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("会话").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.newConversation() } label: {
                    Label("新建", systemImage: "plus")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                TextField("搜索全部会话…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("清除搜索")
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 8)

            Divider()

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else if convos.conversations.isEmpty {
                Text("暂无会话")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(convos.conversations) { c in row(c) }
                    }
                    .padding(6)
                }
                .frame(height: 240)
            }

            Divider()

            HStack(spacing: 8) {
                Button("导出…") { if let c = convos.current { export(c) } }
                Button("导入…") { importFile() }
                Spacer()
                Button("清空") { model.clear() }
                    .help("清空当前对话内容（保留这段对话）")
                    .disabled(convos.current?.bubbles.isEmpty ?? true)
            }
            .controlSize(.small)
            .padding(8)
        }
        .frame(width: 320)
    }

    /// 全局搜索结果：命中所在的会话 + 片段，点击跳转并高亮该条消息。
    @ViewBuilder
    private var searchResults: some View {
        let hits = convos.search(query)
        if hits.isEmpty {
            Text("未找到匹配的消息")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Text("共 \(hits.count) 条命中")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .padding(.horizontal, 10).padding(.top, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(hits) { hit in hitRow(hit) }
                }
                .padding(6)
            }
            .frame(height: 260)
        }
    }

    private func hitRow(_ hit: ConversationStore.SearchHit) -> some View {
        Button {
            model.selectConversation(hit.conversationID, focusBubbleAt: hit.bubbleIndex)
            isPresented = false
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ChatRole.from(hit.role).name)
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    Text(hit.title).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
                Text(hit.snippet).font(.system(size: 11)).lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ c: Conversation) -> some View {
        let isCurrent = c.id == convos.currentID
        let isRunning = model.runningConversations.contains(c.id)
        return HStack(spacing: 6) {
            Button {
                model.selectConversation(c.id)
                isPresented = false
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                    Text("\(c.bubbles.count) 条 · \(c.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    if !c.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "folder").font(.system(size: 8))
                            Text(abbreviated(c.workingDirectory))
                                .font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                        }
                        .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                    .help("正在运行")
            }
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 10)).foregroundColor(.accentColor)
            }
            if isRunning {
                Button { model.stopConversation(c.id) } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 11))
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless).help("停止")
            }
            Button { rename(c) } label: { Image(systemName: "pencil").font(.system(size: 10)) }
                .buttonStyle(.borderless).help("重命名")
            Button { model.deleteConversation(c.id) } label: { Image(systemName: "trash").font(.system(size: 10)) }
                .buttonStyle(.borderless).help("删除")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("重命名…") { rename(c) }
            Button("工作目录…") { chooseWorkingDirectory(c) }
            if !c.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("清除工作目录") { model.setWorkingDirectory("", for: c.id) }
            }
            Button("导出…") { export(c) }
            Divider()
            Button("删除", role: .destructive) { model.deleteConversation(c.id) }
        }
    }

    /// 会话工作目录：显示为 `~/…/最后一级` 的紧凑形式。
    private func abbreviated(_ path: String) -> String {
        let expanded = ToolRunner.workingDirectory(path)
        let home = NSString(string: "~").expandingTildeInPath
        if expanded == home { return "~" }
        if expanded.hasPrefix(home + "/") {
            return "~/" + String(expanded.dropFirst(home.count + 1))
        }
        return expanded
    }

    private func chooseWorkingDirectory(_ c: Conversation) {
        guard let path = WorkingDirectoryPicker.choose(message: "选择「\(c.title)」的工作目录",
                                                      current: c.workingDirectory) else { return }
        model.setWorkingDirectory(path, for: c.id)
    }

    private func rename(_ c: Conversation) {
        let alert = NSAlert()
        alert.messageText = "重命名对话"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = c.title
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            convos.rename(c.id, to: field.stringValue)
        }
    }

    private func export(_ c: Conversation) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(c) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(c.title).json"
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            _ = model.importData(data)
            isPresented = false
        }
    }
}

/// 会话工作目录选择器：会话列表右键菜单与聊天顶栏胶囊共用。
enum WorkingDirectoryPicker {
    /// 弹出目录选择面板；取消时返回 nil。
    static func choose(message: String, current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = message
        let raw = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            let expanded = NSString(string: raw).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                panel.directoryURL = URL(fileURLWithPath: expanded)
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

// MARK: - 工作目录菜单

/// 顶栏工作目录胶囊的弹出菜单。
///
/// 用 AppKit `NSMenu`：SwiftUI `Menu` 嵌在聊天面板的 `NSPopover` 中时会被
/// transient 行为抢先关闭，菜单项点击不生效（提示词菜单与模型菜单都踩过这个坑）。
enum WorkingDirectoryMenu {
    /// 菜单项的闭包载体；`NSMenuItem.target` 是弱引用，因此需要在这里持有。
    private final class Action: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func fire() { handler() }
    }

    private static var retained: [Action] = []

    static func show(
        current: String,
        isCustom: Bool,
        onChoose: @escaping () -> Void,
        onUseDefault: @escaping () -> Void,
        onReveal: @escaping () -> Void
    ) {
        let menu = NSMenu()
        let info = NSMenuItem(title: current, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        var actions: [Action] = []
        func add(_ title: String, _ handler: @escaping () -> Void) {
            let a = Action(handler)
            actions.append(a)
            let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
            item.target = a
            menu.addItem(item)
        }
        add("选择目录…", onChoose)
        add("在 Finder 中打开", onReveal)
        if isCustom { add("使用默认目录", onUseDefault) }

        guard let view = NSApp.keyWindow?.contentView, let event = NSApp.currentEvent else { return }
        retained = actions
        menu.popUp(positioning: nil,
                   at: view.convert(event.locationInWindow, from: nil),
                   in: view)
        retained = []
    }
}
