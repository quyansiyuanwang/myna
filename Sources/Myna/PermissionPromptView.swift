import SwiftUI

/// 工具授权弹窗。由 `ToolPermissionCenter` 串行驱动。
struct PermissionPromptView: View {
    let prompt: PermissionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundColor(.orange)
                Text("允许 Myna 调用工具？")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            Text(prompt.tool)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(6)
            ScrollView {
                Text(prompt.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            Text("「允许一次」只对本次调用有效；「始终允许」会写入工具权限设置。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button("拒绝") {
                    ToolPermissionCenter.shared.resolve(id: prompt.id, allow: false, always: false)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("允许一次") {
                    ToolPermissionCenter.shared.resolve(id: prompt.id, allow: true, always: false)
                }
                .keyboardShortcut(.defaultAction)
                Button("始终允许") {
                    ToolPermissionCenter.shared.resolve(id: prompt.id, allow: true, always: true)
                }
            }
        }
        .padding(16)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
