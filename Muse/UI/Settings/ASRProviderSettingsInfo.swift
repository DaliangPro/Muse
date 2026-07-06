import Foundation

struct ASRProviderGuideLink {
    let label: String
    let url: URL
}

enum ASRProviderSettingsInfo {
    static func guideLinks(for provider: ASRProvider) -> [ASRProviderGuideLink] {
        switch provider {
        case .volcano:
            return [
                ASRProviderGuideLink(
                    label: L("配置地址", "Config URL"),
                    url: URL(string: "https://console.volcengine.com/speech/app")!
                ),
            ]
        default:
            return []
        }
    }
}
