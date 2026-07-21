import Foundation

enum AppURLCommandHandler {
    static func handle(_ urls: [URL]) {
        for url in urls {
            guard url.scheme == "muse" else { continue }
            switch url.host {
            case "reload-vocabulary":
                AppLogger.log("[Muse] URL command: reload-vocabulary")
                SnippetStorage.reloadFromDisk()
                HotwordStorage.reloadFromDisk()
            default:
                AppLogger.log("[Muse] Unknown URL command: \(url)")
            }
        }
    }
}
