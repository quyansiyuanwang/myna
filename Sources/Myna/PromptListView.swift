import SwiftUI

/// 提示词模板列表弹窗。
struct PromptListView: View {
    let prompts: [PromptTemplate]
    let onRescan: () -> Void
    let onOpenDir: () -> Void
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("提示词模板").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("重新扫描", action: onRescan).controlSize(.small)
                Button("打开目录", action: onOpenDir).controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            Divider()

            if prompts.isEmpty {
                Text("未找到模板。在 ~/.config/myna/prompts 放置 .md 文件即可。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .padding(.horizontal, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(prompts) { p in
                            Button { onPick(p.body) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.title).font(.system(size: 12)).lineLimit(1)
                                    Text(p.body.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 220)
            }
        }
        .frame(width: 300)
    }
}
