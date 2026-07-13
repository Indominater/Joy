import AppKit
import Combine
import Foundation

@MainActor
final class MonitorStore: ObservableObject {
    @Published var slots: [ChatSlot]
    @Published private(set) var now = Date()

    private var observations: [String: MonitorObservation] = [:]
    private var timer: Timer?
    private var pollTask: Task<Void, Never>?
    private var clearUndoExpirationTask: Task<Void, Never>?
    private let codexMonitor = CodexSessionMonitor()
    private let userDefaults: UserDefaults
    private let clearUndoLifetime: Duration
    private let undoClock = ContinuousClock()
    private var pendingClear: PendingClear?

    private struct PendingClear {
        let token: UUID
        let slotID: Int
        let url: String
        let expiresAt: ContinuousClock.Instant
    }

    private enum Keys {
        static let slots = "joy.chat-slots"
    }

    init(
        userDefaults: UserDefaults = .standard,
        clearUndoLifetime: Duration = .seconds(5)
    ) {
        self.userDefaults = userDefaults
        self.clearUndoLifetime = max(clearUndoLifetime, .zero)

        if let data = userDefaults.data(forKey: Keys.slots),
           let saved = try? JSONDecoder().decode([ChatSlot].self, from: data) {
            let values = Array(saved.prefix(4))
            slots = values + (values.count..<4).map { ChatSlot(id: $0, url: "") }
        } else {
            slots = (0..<4).map { ChatSlot(id: $0, url: "") }
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
        pollTask?.cancel()
        clearUndoExpirationTask?.cancel()
    }

    func updateURL(for id: Int, to value: String) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        guard slots[index].url.isEmpty || value.isEmpty else { return }
        if pendingClear?.slotID == id {
            discardClearUndo()
        }
        slots[index].url = value
        persistSlots()
        refresh()
    }

    func clearURL(for id: Int) {
        guard let index = slots.firstIndex(where: { $0.id == id }),
              !slots[index].url.isEmpty
        else { return }

        discardClearUndo()

        let token = UUID()
        pendingClear = PendingClear(
            token: token,
            slotID: id,
            url: slots[index].url,
            expiresAt: undoClock.now.advanced(by: clearUndoLifetime)
        )

        slots[index].url = ""
        persistSlots()
        refresh()

        let lifetime = clearUndoLifetime
        clearUndoExpirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: lifetime)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expireClearUndo(token: token)
        }
    }

    var canUndoLastClear: Bool {
        guard let pendingClear else { return false }
        return undoClock.now < pendingClear.expiresAt
    }

    @discardableResult
    func undoLastClear() -> Bool {
        guard let pendingClear else { return false }
        discardClearUndo()

        guard undoClock.now < pendingClear.expiresAt,
              let index = slots.firstIndex(where: { $0.id == pendingClear.slotID }),
              slots[index].url.isEmpty
        else { return false }

        slots[index].url = pendingClear.url
        persistSlots()
        refresh()
        return true
    }

    func state(for slot: ChatSlot) -> ChatState {
        let raw = slot.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .unconfigured }
        guard let target = URLNormalizer.target(raw) else { return .invalid }
        guard let observation = observations[target.key] else { return .closed }
        guard now.timeIntervalSince(observation.observedAt) < 8 else { return .closed }
        return observation.state
    }

    func focus(_ slot: ChatSlot) {
        guard let target = URLNormalizer.target(slot.url) else {
            NSSound.beep()
            return
        }

        switch target {
        case .chatGPT(let url):
            ChromeTabFocus.focus(url: url)
        case .codex(_, let deepLink):
            guard let url = URL(string: deepLink) else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    private func refresh() {
        now = Date()
        guard pollTask == nil else { return }

        let targets = slots.compactMap { URLNormalizer.target($0.url) }
        let chatURLs = Set(targets.compactMap { target -> String? in
            guard case .chatGPT(let url) = target else { return nil }
            return url
        })
        let codexThreadIDs = Set(targets.compactMap { target -> String? in
            guard case .codex(let threadID, _) = target else { return nil }
            return threadID
        })

        let wantedKeys = Set(targets.map(\.key))
        observations = observations.filter { wantedKeys.contains($0.key) }
        guard !chatURLs.isEmpty || !codexThreadIDs.isEmpty else { return }

        let codexMonitor = self.codexMonitor
        pollTask = Task { [weak self] in
            async let codexSamples = codexMonitor.sample(threadIDs: codexThreadIDs)
            let chromeResult: ChromeMonitorResult
            if chatURLs.isEmpty {
                chromeResult = .success([])
            } else {
                chromeResult = await Task.detached(priority: .utility) {
                    ChromeAppleEventsMonitor.sample()
                }.value
            }

            let resolvedCodexSamples = await codexSamples
            guard !Task.isCancelled, let self else { return }
            self.applyChrome(chromeResult, configuredURLs: chatURLs)
            self.applyCodex(resolvedCodexSamples)
            self.pollTask = nil
        }
    }

    private func applyChrome(
        _ result: ChromeMonitorResult,
        configuredURLs: Set<String>
    ) {
        let observedAt = Date()

        switch result {
        case .unavailable:
            for url in configuredURLs {
                let key = MonitorTarget.chatGPT(url: url).key
                observations[key] = ChatGPTRuntimeReducer.interrupted(
                    state: .failed,
                    previous: observations[key],
                    observedAt: observedAt
                )
            }
        case .success(let samples):
            let preferredPageInstances = Dictionary(
                uniqueKeysWithValues: configuredURLs.compactMap { url in
                    let key = MonitorTarget.chatGPT(url: url).key
                    return observations[key]?.pageInstance.map { (url, $0) }
                }
            )
            let strongestSample = ChatGPTRuntimeReducer.strongestSamples(
                samples,
                configuredURLs: configuredURLs,
                preferredPageInstances: preferredPageInstances
            )

            for url in configuredURLs {
                let key = MonitorTarget.chatGPT(url: url).key
                guard let sample = strongestSample[url] else {
                    observations[key] = ChatGPTRuntimeReducer.missing(
                        previous: observations[key],
                        observedAt: observedAt
                    )
                    continue
                }
                observations[key] = ChatGPTRuntimeReducer.transition(
                    sample: sample,
                    previous: observations[key],
                    observedAt: observedAt
                )
            }
        }
    }

    private func applyCodex(_ samples: [CodexTaskSample]) {
        let observedAt = Date()
        for sample in samples {
            let state: ChatState
            switch sample.status {
            case .closed: state = .closed
            case .idle: state = .idle
            case .running(let startedAt): state = .running(startedAt: startedAt)
            case .finished(let duration): state = .finished(duration: duration)
            case .failed: state = .failed
            }

            let key = MonitorTarget.codex(
                threadID: sample.threadID,
                deepLink: "codex://threads/\(sample.threadID)"
            ).key
            observations[key] = MonitorObservation(state: state, observedAt: observedAt)
        }
    }

    private func persistSlots() {
        if let data = try? JSONEncoder().encode(slots) {
            userDefaults.set(data, forKey: Keys.slots)
        }
    }

    private func expireClearUndo(token: UUID) {
        guard pendingClear?.token == token else { return }
        pendingClear = nil
        clearUndoExpirationTask = nil
    }

    private func discardClearUndo() {
        clearUndoExpirationTask?.cancel()
        clearUndoExpirationTask = nil
        pendingClear = nil
    }
}

enum ChromeTabFocus {
    private static let script = #"""
    on run argv
        set targetURL to item 1 of argv
        if application "Google Chrome" is not running then return "missing"

        tell application "Google Chrome"
            repeat with browserWindow in windows
                set tabNumber to 0
                repeat with browserTab in tabs of browserWindow
                    set tabNumber to tabNumber + 1
                    set currentURL to URL of browserTab as text
                    if currentURL starts with targetURL then
                        set minimized of browserWindow to false
                        set active tab index of browserWindow to tabNumber
                        set index of browserWindow to 1
                        activate
                        return "found"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
    end run
    """#

    static func focus(url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, url]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSSound.beep()
        }
    }
}
