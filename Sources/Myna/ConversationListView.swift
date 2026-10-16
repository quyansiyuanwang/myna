import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 会话管理弹窗：切换 / 新建 / 重命名 / 删除 / 导出 / 导入。
struct ConversationListView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var convos = ConversationStore.shared
    @Binding var isPresented: Bool

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

            Divider()

            if convos.conversations.isEmpty {
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
            }
            .controlSize(.small)
            .padding(8)
        }
        .frame(width: 300)
    }

    private func row(_ c: Conversation) -> some View {
        let isCurrent = c.id == convos.currentID
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 10)).foregroundColor(.accentColor)
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
            Button("导出…") { export(c) }
            Divider()
            Button("删除", role: .destructive) { model.deleteConversation(c.id) }
        }
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
