import AppKit
import Combine
import Foundation

@MainActor
final class MonitorStore: ObservableObject {
    @Published var slots: [ChatSlot]
    @Published private(set) var now = Date()
    @Published private(set) var undoableClearSlotID: Int?

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

    private static let slotCount = 3

    init(
        userDefaults: UserDefaults = .standard,
        clearUndoLifetime: Duration = .seconds(5)
    ) {
        self.userDefaults = userDefaults
        self.clearUndoLifetime = max(clearUndoLifetime, .zero)

        if let data = userDefaults.data(forKey: Keys.slots),
           let saved = try? JSONDecoder().decode([ChatSlot].self, from: data) {
            let values = Array(saved.prefix(Self.slotCount))
            slots = values + (values.count..<Self.slotCount).map {
                ChatSlot(id: $0, url: "")
            }
        } else {
            slots = (0..<Self.slotCount).map { ChatSlot(id: $0, url: "") }
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
        guard slots[index].url.isEmpty else { return }
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
        setPendingClear(PendingClear(
            token: token,
            slotID: id,
            url: slots[index].url,
            expiresAt: undoClock.now.advanced(by: clearUndoLifetime)
        ))

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

    @discardableResult
    func undoLastClear(for slotID: Int) -> Bool {
        guard pendingClear?.slotID == slotID else { return false }
        return undoLastClear()
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
        case .chatGPT(let url, _):
            ChromeTabFocus.focus(url: url)
        case .codex(let threadID):
            let deepLink = URL(string: "codex://threads/\(threadID)")!
            DeepLinkFocus.open(deepLink)
        }
    }

    private func refresh() {
        now = Date()
        guard pollTask == nil else { return }

        let targets = slots.compactMap { URLNormalizer.target($0.url) }
        let chatURLs = Set(targets.compactMap { target -> String? in
            guard case .chatGPT(let url, _) = target else { return nil }
            return url
        })
        let codexThreadIDs = Set(targets.compactMap { target -> String? in
            guard case .codex(let threadID) = target else { return nil }
            return threadID
        })

        // Keep the last observation warm during the brief Undo window so a
        // restored row immediately returns to its previous status instead of
        // flashing Closed while the next poll starts.
        let pendingClearKey = pendingClear.flatMap {
            URLNormalizer.target($0.url)?.key
        }
        let wantedKeys = Set(targets.map(\.key))
            .union(pendingClearKey.map { [$0] } ?? [])
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
                let key = MonitorTarget.chatGPTKey(url: url)
                observations[key] = ChatGPTRuntimeReducer.interrupted(
                    previous: observations[key],
                    observedAt: observedAt
                )
            }
        case .success(let samples):
            let preferredPageInstances = Dictionary(
                uniqueKeysWithValues: configuredURLs.compactMap { url in
                    let key = MonitorTarget.chatGPTKey(url: url)
                    return observations[key]?.pageInstance.map { (url, $0) }
                }
            )
            let strongestSample = ChatGPTRuntimeReducer.strongestSamples(
                samples,
                configuredURLs: configuredURLs,
                preferredPageInstances: preferredPageInstances
            )

            for url in configuredURLs {
                let key = MonitorTarget.chatGPTKey(url: url)
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

            let key = MonitorTarget.codexKey(threadID: sample.threadID)
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
        setPendingClear(nil)
        clearUndoExpirationTask = nil
    }

    private func discardClearUndo() {
        clearUndoExpirationTask?.cancel()
        clearUndoExpirationTask = nil
        setPendingClear(nil)
    }

    private func setPendingClear(_ pendingClear: PendingClear?) {
        self.pendingClear = pendingClear
        undoableClearSlotID = pendingClear?.slotID
    }
}

enum ChromeTabFocus {
    // Chrome can restore its previously key window while activation is still
    // settling. Keep the match's stable window ID and raise it only afterward.
    static let appleScript = #"""
    on run argv
        set targetURL to item 1 of argv

        tell application "Google Chrome"
            repeat with browserWindow in windows
                set tabNumber to 0
                repeat with browserTab in tabs of browserWindow
                    set tabNumber to tabNumber + 1
                    set currentURL to URL of browserTab as text
                    if currentURL starts with targetURL then
                        set targetWindowID to id of browserWindow
                        set minimized of window id targetWindowID to false
                        set active tab index of window id targetWindowID to tabNumber
                        activate
                        repeat 20 times
                            if frontmost then exit repeat
                            delay 0.01
                        end repeat
                        set index of window id targetWindowID to 1
                        return "found"
                    end if
                end repeat
            end repeat

            if (count of windows) is 0 then
                make new window
                set URL of active tab of front window to targetURL
            else
                tell front window
                    make new tab with properties {URL:targetURL}
                    set active tab index to (count of tabs)
                end tell
            end if
            activate
        end tell
    end run
    """#

    static func focus(url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript, url]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSSound.beep()
        }
    }
}

@MainActor
enum DeepLinkFocus {
    private static var bundleIdentifiersByScheme: [String: String] = [:]

    static func open(_ deepLink: URL) {
        let workspace = NSWorkspace.shared
        let scheme = deepLink.scheme ?? ""
        let bundleIdentifier = bundleIdentifiersByScheme[scheme]
            ?? workspace.urlForApplication(toOpen: deepLink).flatMap {
                Bundle(url: $0)?.bundleIdentifier
            }
        if let bundleIdentifier {
            bundleIdentifiersByScheme[scheme] = bundleIdentifier
        }
        if let bundleIdentifier,
           let application = NSRunningApplication.runningApplications(
               withBundleIdentifier: bundleIdentifier
           ).first {
            application.activate()
        }
        workspace.open(deepLink)
    }
}
