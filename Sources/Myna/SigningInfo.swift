import Foundation
import Security

/// 当前进程的代码签名状态（用于诊断 TCC 授权为什么会被重置）。
enum SigningInfo {
    /// ad-hoc 签名的 designated requirement 是 cdhash，每次构建都会变化。
    static var isAdHoc: Bool {
        guard let flags = signingFlags else { return true }
        return flags & 0x2 != 0
    }

    static var summary: String {
        guard let flags = signingFlags else { return "未知" }
        if flags & 0x2 != 0 {
            return "ad-hoc（更新 / 重新编译后需重新授权）"
        }
        if let team = teamIdentifier, !team.isEmpty {
            return "Developer ID（\(team)）"
        }
        return "本地稳定证书（授权可跨构建保留）"
    }

    private static var signingFlags: UInt32? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
    }

    private static var teamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
