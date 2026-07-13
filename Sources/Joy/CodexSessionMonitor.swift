import Foundation

enum CodexTaskStatus: Sendable {
    case closed
    case idle
    case running(startedAt: Date)
    case finished(duration: TimeInterval?)
    case failed
}

struct CodexTaskSample: Sendable {
    let threadID: String
    let status: CodexTaskStatus
}

actor CodexSessionMonitor {
    private struct Cursor {
        let fileURL: URL
        var offset: UInt64
        var partialLine = Data()
        var status: CodexTaskStatus = .idle
    }

    private var cursors: [String: Cursor] = [:]
    private var knownFiles: [String: URL] = [:]
    private var lastDirectoryScan = Date.distantPast

    func sample(threadIDs: Set<String>) -> [CodexTaskSample] {
        cursors = cursors.filter { threadIDs.contains($0.key) }

        let missingIDs = threadIDs.filter { cursors[$0] == nil }
        if !missingIDs.isEmpty {
            indexSessionFilesIfNeeded(force: Date().timeIntervalSince(lastDirectoryScan) > 3)
            for threadID in missingIDs {
                guard let fileURL = knownFiles[threadID],
                      var cursor = makeCursor(for: fileURL)
                else { continue }
                readNewData(into: &cursor, initialRead: true)
                cursors[threadID] = cursor
            }
        }

        var samples: [CodexTaskSample] = []
        for threadID in threadIDs {
            guard var cursor = cursors[threadID] else {
                samples.append(CodexTaskSample(threadID: threadID, status: .closed))
                continue
            }

            readNewData(into: &cursor, initialRead: false)
            cursors[threadID] = cursor
            samples.append(CodexTaskSample(threadID: threadID, status: cursor.status))
        }
        return samples
    }

    private func indexSessionFilesIfNeeded(force: Bool) {
        guard force || knownFiles.isEmpty else { return }
        lastDirectoryScan = Date()

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let filename = fileURL.deletingPathExtension().lastPathComponent
            guard filename.hasPrefix("rollout-") else { continue }

            let parts = filename.split(separator: "-")
            guard parts.count >= 5 else { continue }
            let threadID = parts.suffix(5).joined(separator: "-")
            knownFiles[threadID] = fileURL
        }
    }

    private func makeCursor(for fileURL: URL) -> Cursor? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return Cursor(fileURL: fileURL, offset: 0)
    }

    private func readNewData(into cursor: inout Cursor, initialRead: Bool) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.fileURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            cursor.status = .closed
            return
        }

        if fileSize < cursor.offset {
            cursor.offset = 0
            cursor.partialLine.removeAll(keepingCapacity: true)
            cursor.status = .idle
        }
        guard initialRead || fileSize > cursor.offset else { return }

        do {
            let handle = try FileHandle(forReadingFrom: cursor.fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: cursor.offset)

            while true {
                let data = try handle.read(upToCount: 262_144) ?? Data()
                guard !data.isEmpty else { break }
                consume(data, into: &cursor)
            }
            cursor.offset = try handle.offset()
        } catch {
            cursor.status = .closed
        }
    }

    private func consume(_ data: Data, into cursor: inout Cursor) {
        var combined = cursor.partialLine
        combined.append(data)
        let lines = combined.split(separator: 0x0A, omittingEmptySubsequences: false)

        for line in lines.dropLast() {
            applyLifecycleEvent(Data(line), to: &cursor.status)
        }
        cursor.partialLine = Data(lines.last ?? Data.SubSequence())
    }

    private func applyLifecycleEvent(_ line: Data, to status: inout CodexTaskStatus) {
        guard let text = String(data: line, encoding: .utf8),
              text.contains("\"task_started\"")
                || text.contains("\"task_complete\"")
                || text.contains("\"turn_aborted\"")
        else { return }

        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              let eventType = payload["type"] as? String
        else { return }

        switch eventType {
        case "task_started":
            let timestamp = (payload["started_at"] as? NSNumber)?.doubleValue
                ?? Date().timeIntervalSince1970
            status = .running(startedAt: Date(timeIntervalSince1970: timestamp))
        case "task_complete":
            let duration = (payload["duration_ms"] as? NSNumber).map {
                $0.doubleValue / 1_000
            }
            status = .finished(duration: duration)
        case "turn_aborted":
            status = .failed
        default:
            break
        }
    }
}
