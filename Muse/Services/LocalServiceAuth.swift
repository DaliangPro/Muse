import Foundation
import Security

/// Muse 进程与本地推理子进程之间的会话鉴权。
/// token 只存在于当前进程内存，并通过子进程环境变量传递，不持久化。
enum LocalServiceAuth {
    static let headerName = "X-Muse-Local-Token"
    static let environmentName = "MUSE_LOCAL_AUTH_TOKEN"

    static let token: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            fatalError("无法生成本地服务会话 token")
        }

        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }()

    static func authorize(_ request: inout URLRequest) {
        request.setValue(token, forHTTPHeaderField: headerName)
    }

    static func serverEnvironment(
        inheriting environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = environment
        result[environmentName] = token
        return result
    }
}
