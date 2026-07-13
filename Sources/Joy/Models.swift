import Foundation

struct ChatSlot: Identifiable, Codable, Equatable {
    let id: Int
    var url: String
}

enum ChatState: Equatable {
    case unconfigured
    case invalid
    case closed
    case idle
    case running(startedAt: Date)
    case finished(duration: TimeInterval?)
    case failed
}

enum MonitorTarget: Equatable, Sendable {
    case chatGPT(url: String)
    case codex(threadID: String, deepLink: String)

    var key: String {
        switch self {
        case .chatGPT(let url): "chatgpt:\(url)"
        case .codex(let threadID, _): "codex:\(threadID)"
        }
    }
}

enum URLNormalizer {
    static func target(_ rawValue: String) -> MonitorTarget? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            return nil
        }

        if components.scheme?.lowercased() == "codex" {
            guard components.host?.lowercased() == "threads" else { return nil }
            let pathParts = components.path.split(separator: "/")
            guard pathParts.count == 1 else { return nil }

            let threadID = String(pathParts[0]).lowercased()
            guard threadID != "new", UUID(uuidString: threadID) != nil else { return nil }

            let deepLink = "codex://threads/\(threadID)"
            return .codex(threadID: threadID, deepLink: deepLink)
        }

        guard components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "chatgpt.com"
        else { return nil }

        components.scheme = "https"
        components.host = "chatgpt.com"
        components.query = nil
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        let pathParts = components.path.split(separator: "/")
        guard let conversationMarker = pathParts.firstIndex(of: "c"),
              pathParts.index(after: conversationMarker) < pathParts.endIndex
        else { return nil }

        guard let normalizedURL = components.url?.absoluteString else { return nil }
        return .chatGPT(url: normalizedURL)
    }

    static func normalizeChatGPT(_ rawValue: String) -> String? {
        guard case .chatGPT(let url) = target(rawValue) else { return nil }
        return url
    }
}
