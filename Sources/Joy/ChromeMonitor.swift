import AppKit
import Foundation
import ScriptingBridge

@objc private protocol ChromeScriptingApplication {
    @objc optional var windows: [ChromeScriptingWindow] { get }
}

@objc private protocol ChromeScriptingWindow {
    @objc(id) optional var windowIdentifier: String { get }
    @objc optional var tabs: [ChromeScriptingTab] { get }
}

@objc private protocol ChromeScriptingTab {
    @objc(URL) optional var url: String { get }
    @objc(executeJavascript:) optional func execute(
        javascript: String
    ) -> Any?
}

extension SBApplication: ChromeScriptingApplication {}
extension SBObject: ChromeScriptingWindow, ChromeScriptingTab {}

private final class ChromeScriptingErrorDelegate: NSObject,
    SBApplicationDelegate {
    private(set) var didFail = false

    func reset() {
        didFail = false
    }

    func eventDidFail(
        _ event: UnsafePointer<AppleEvent>,
        withError error: Error
    ) -> Any? {
        didFail = true
        return nil
    }
}

enum ChromeProbeStatus: String, Sendable {
    case idle
    case running
    case failed
    case unavailable
}

struct ChromeTabLocation: Equatable, Sendable {
    let windowID: Int
    let tabIndex: Int
    let processID: pid_t?

    init(windowID: Int, tabIndex: Int, processID: pid_t? = nil) {
        self.windowID = windowID
        self.tabIndex = tabIndex
        self.processID = processID
    }
}

struct ChromeTabSample: Sendable {
    let url: String
    let status: ChromeProbeStatus
    let pageInstance: String
    let promptInstance: String?
    let responseInstance: String?
    let location: ChromeTabLocation?

    init(
        url: String,
        status: ChromeProbeStatus,
        pageInstance: String,
        promptInstance: String?,
        responseInstance: String?,
        location: ChromeTabLocation? = nil
    ) {
        self.url = url
        self.status = status
        self.pageInstance = pageInstance
        self.promptInstance = promptInstance
        self.responseInstance = responseInstance
        self.location = location
    }
}

enum ChromeMonitorResult: Sendable {
    case success([ChromeTabSample], isComplete: Bool)
    case unavailable
}

struct ChromeFocusSnapshot: Equatable {
    let isMinimized: Bool?
    let isTargetFrontWindow: Bool
    let activeTabIndex: Int?
    let appleEventFailed: Bool

    func confirms(targetTabIndex: Int) -> Bool {
        isMinimized == false
            && isTargetFrontWindow
            && activeTabIndex == targetTabIndex
            && !appleEventFailed
    }
}

struct ChromeFocusSettleTracker {
    private(set) var consecutiveConfirmations = 0
    let requiredConfirmations: Int

    mutating func observe(
        _ snapshot: ChromeFocusSnapshot,
        targetTabIndex: Int
    ) -> Bool {
        if snapshot.confirms(targetTabIndex: targetTabIndex) {
            consecutiveConfirmations += 1
        } else {
            reset()
        }
        return consecutiveConfirmations >= requiredConfirmations
    }

    mutating func reset() {
        consecutiveConfirmations = 0
    }
}

struct ChromeProcessCandidate: Equatable {
    let processID: pid_t
    let isTerminated: Bool
    let activationPolicy: NSApplication.ActivationPolicy
}

@MainActor
enum ChromeProcessLocator {
    static func monitorableProcessIDs() -> [pid_t] {
        let candidates = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.google.Chrome"
        )
        .map {
            ChromeProcessCandidate(
                processID: $0.processIdentifier,
                isTerminated: $0.isTerminated,
                activationPolicy: $0.activationPolicy
            )
        }
        return monitorableProcessIDs(from: candidates)
    }

    nonisolated static func monitorableProcessIDs(
        from candidates: [ChromeProcessCandidate]
    ) -> [pid_t] {
        candidates
            .filter {
                !$0.isTerminated && $0.activationPolicy == .regular
            }
            .map(\.processID)
            .sorted()
    }
}

enum ChromeAppleEventsMonitor {
    private static let fieldSeparator = "|||JOY_FIELD|||"
    private static let recordSeparator = "|||JOY_RECORD|||"

    static let probeJavaScript = #"""
    (() => {
      const visible = (element) => {
        if (element.getClientRects().length === 0) return false;
        const style = getComputedStyle(element);
        return style.visibility !== "hidden" && style.display !== "none";
      };
      const visibleMatch = (selectors) => selectors.some((selector) =>
        Array.from(document.querySelectorAll(selector)).some(visible)
      );
      const runningSelectors = [
        'button[data-testid="stop-button"]',
        'button[aria-label*="Stop generating" i]',
        'button[aria-label*="Stop streaming" i]',
        'button[aria-label*="Stop response" i]'
      ];
      const errorSelectors = [
        '[data-testid="conversation-turn-error"]',
        '[data-testid^="conversation-turn-"] [data-testid*="error" i]',
        '[data-testid^="conversation-turn-"] [role="alert"]'
      ];
      const userMessages = Array.from(
        document.querySelectorAll('[data-message-author-role="user"]')
      );
      const latestUserMessage = userMessages[userMessages.length - 1];
      const latestUserTurn = latestUserMessage?.closest(
        '[data-testid^="conversation-turn-"]'
      );
      const runningByText = Array.from(document.querySelectorAll('button')).some((button) =>
        visible(button) && /stop (generating|streaming|response)/i.test(
          `${button.getAttribute('aria-label') || ''} ${button.textContent || ''}`
        )
      );
      const failed = errorSelectors.some((selector) =>
        Array.from(document.querySelectorAll(selector)).some((element) =>
          visible(element)
            && (!latestUserMessage || Boolean(
              latestUserMessage.compareDocumentPosition(element)
                & Node.DOCUMENT_POSITION_FOLLOWING
            ))
            && /(error|failed|went wrong|network)/i.test(element.textContent || '')
        )
      );
      const status = visibleMatch(runningSelectors) || runningByText
        ? "running"
        : failed ? "failed" : "idle";
      // Attribute-only identities avoid inspecting either prompt or response
      // text. The user turn slot is the hard new-prompt boundary; assistant
      // message IDs are only continuity evidence because phases can replace them.
      const promptTurnSlot = latestUserTurn?.getAttribute('data-testid') || "";
      const promptInstance = promptTurnSlot
        ? `turn-slot:${promptTurnSlot}`
        : "";
      const assistantMessages = Array.from(
        document.querySelectorAll('[data-message-author-role="assistant"]')
      ).filter(visible);
      const latestAssistantMessage = assistantMessages[assistantMessages.length - 1];
      const assistantFollowsPrompt = latestUserMessage && latestAssistantMessage
        && Boolean(
          latestUserMessage.compareDocumentPosition(latestAssistantMessage)
            & Node.DOCUMENT_POSITION_FOLLOWING
        );
      const responseMessageInstance = assistantFollowsPrompt
        ? latestAssistantMessage.getAttribute('data-message-id') || ""
        : "";
      const responseInstance = responseMessageInstance
        ? `message:${responseMessageInstance}`
        : "";
      return `${status}::JOY::${Math.round(
        performance.timeOrigin || Date.now()
      )}::JOY::${promptInstance}::JOY::${responseInstance}`;
    })()
    """#

    static func parseOutput(_ output: String) -> ChromeMonitorResult {
        if output.hasPrefix("__JOY_ERROR__") {
            return .unavailable
        }

        let partialPrefix = "__JOY_PARTIAL__" + recordSeparator
        let isMarkedPartial = output.hasPrefix(partialPrefix)
        let sampleOutput = isMarkedPartial
            ? String(output.dropFirst(partialPrefix.count))
            : output
        let samples = parseSamples(sampleOutput)
        let records = sampleOutput
            .components(separatedBy: recordSeparator)
            .filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        let intentionallyIgnoredRecordCount = records.filter(
            isIntentionallyUnsupportedChatGPTRouteRecord
        ).count
        let accountedRecordCount = samples.count
            + intentionallyIgnoredRecordCount

        return .success(
            samples,
            isComplete: !isMarkedPartial
                && accountedRecordCount == records.count
        )
    }

    private static func isIntentionallyUnsupportedChatGPTRouteRecord(
        _ record: String
    ) -> Bool {
        let fields = record.components(separatedBy: fieldSeparator)
        guard fields.count == 2 || fields.count == 4,
              let components = URLComponents(string: fields[0]),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "chatgpt.com"
        else { return false }

        // Chrome returns every ChatGPT tab. Home, settings, shared chats, and
        // GPT-builder pages are valid records, but are intentionally outside
        // Joy's /c/<conversation> monitor target set.
        return URLNormalizer.target(fields[0]) == nil
    }

    static func parseSamples(_ output: String) -> [ChromeTabSample] {
        output
            .components(separatedBy: recordSeparator)
            .compactMap { record -> ChromeTabSample? in
                guard !record.isEmpty else { return nil }
                let fields = record.components(separatedBy: fieldSeparator)
                guard fields.count == 2 || fields.count == 4,
                      let normalizedURL = URLNormalizer.normalizeChatGPT(fields[0])
                else { return nil }

                let probeValue = fields.count == 4 ? fields[3] : fields[1]
                let location: ChromeTabLocation?
                if fields.count == 4,
                   let windowID = Int(fields[1]),
                   let tabIndex = Int(fields[2]),
                   windowID > 0,
                   tabIndex > 0 {
                    location = ChromeTabLocation(
                        windowID: windowID,
                        tabIndex: tabIndex
                    )
                } else {
                    location = nil
                }

                let probeFields = probeValue.components(separatedBy: "::JOY::")
                guard probeFields.count >= 4,
                      let status = ChromeProbeStatus(rawValue: probeFields[0])
                else { return nil }
                let promptInstance = !probeFields[2].isEmpty
                    ? probeFields[2]
                    : nil
                let responseInstance = !probeFields[3].isEmpty
                    ? probeFields[3]
                    : nil

                return ChromeTabSample(
                    url: normalizedURL,
                    status: status,
                    pageInstance: probeFields[1],
                    promptInstance: promptInstance,
                    responseInstance: responseInstance,
                    location: location
                )
            }
    }

    static func parseProbe(
        url: String,
        probeValue: String,
        location: ChromeTabLocation?
    ) -> ChromeTabSample? {
        guard let normalizedURL = URLNormalizer.normalizeChatGPT(url) else {
            return nil
        }
        let probeFields = probeValue.components(separatedBy: "::JOY::")
        guard probeFields.count >= 4,
              let status = ChromeProbeStatus(rawValue: probeFields[0])
        else { return nil }

        return ChromeTabSample(
            url: normalizedURL,
            status: status,
            pageInstance: probeFields[1],
            promptInstance: probeFields[2].isEmpty ? nil : probeFields[2],
            responseInstance: probeFields[3].isEmpty ? nil : probeFields[3],
            location: location
        )
    }
}

enum ChromeScriptingBridgeMonitor {
    static func sample(processIDs: [pid_t]) -> ChromeMonitorResult {
        guard !processIDs.isEmpty else {
            return .success([], isComplete: true)
        }

        var samples: [ChromeTabSample] = []
        var completedEveryEnumeration = true
        var enumeratedProcessCount = 0

        for processID in processIDs {
            guard let application = SBApplication(
                processIdentifier: processID
            )
            else {
                completedEveryEnumeration = false
                continue
            }

            // Apple Event timeout units are ticks (60 per second).
            application.timeout = 5 * 60
            let errorDelegate = ChromeScriptingErrorDelegate()
            application.delegate = errorDelegate
            let chrome = application as ChromeScriptingApplication
            errorDelegate.reset()
            guard let windows = chrome.windows else {
                completedEveryEnumeration = false
                continue
            }
            if errorDelegate.didFail {
                completedEveryEnumeration = false
            }
            enumeratedProcessCount += 1

            for window in windows {
                errorDelegate.reset()
                guard let tabs = window.tabs else {
                    completedEveryEnumeration = false
                    continue
                }
                if errorDelegate.didFail {
                    completedEveryEnumeration = false
                }
                errorDelegate.reset()
                let windowID = window.windowIdentifier.flatMap(Int.init)

                for (zeroBasedIndex, tab) in tabs.enumerated() {
                    errorDelegate.reset()
                    guard let rawURL = tab.url else {
                        completedEveryEnumeration = false
                        continue
                    }
                    if errorDelegate.didFail {
                        completedEveryEnumeration = false
                    }
                    guard let normalizedURL = URLNormalizer.normalizeChatGPT(
                        rawURL
                    ) else {
                        continue
                    }

                    let location = windowID.map {
                        ChromeTabLocation(
                            windowID: $0,
                            tabIndex: zeroBasedIndex + 1,
                            processID: processID
                        )
                    }
                    errorDelegate.reset()
                    let probeValue = tab.execute?(
                        javascript: ChromeAppleEventsMonitor.probeJavaScript
                    ) as? String
                    let sample = probeValue.flatMap {
                        ChromeAppleEventsMonitor.parseProbe(
                            url: rawURL,
                            probeValue: $0,
                            location: location
                        )
                    } ?? ChromeTabSample(
                        url: normalizedURL,
                        status: .unavailable,
                        pageInstance: "",
                        promptInstance: nil,
                        responseInstance: nil,
                        location: location
                    )
                    samples.append(sample)
                }
            }
        }

        guard enumeratedProcessCount > 0 else { return .unavailable }
        return .success(
            samples,
            isComplete: completedEveryEnumeration
                && enumeratedProcessCount == processIDs.count
        )
    }
}

enum ChromeScriptingBridgeFocus {
    // Chrome's ScriptingBridge dictionary declares these element class codes.
    // class(forScriptingClass:) returns an SBPseudoClass, which cannot be cast
    // to SBObject.Type in Swift; constructing the correctly coded proxy is the
    // supported generic ScriptingBridge path.
    static let tabElementCode: DescType = 0x43725462 // "CrTb"
    static let windowElementCode: DescType = 0x6377696E // "cwin"
    static let focusRetryAttemptCount = 40
    static let focusRetryInterval: TimeInterval = 0.025
    static let requiredStableFocusConfirmations = 2

    static func orderedProcessIDs(
        _ processIDs: [pid_t],
        preferredProcessID: pid_t?
    ) -> [pid_t] {
        var ordered = Array(Set(processIDs)).sorted()
        guard let preferredProcessID,
              let index = ordered.firstIndex(of: preferredProcessID)
        else { return ordered }
        ordered.remove(at: index)
        ordered.insert(preferredProcessID, at: 0)
        return ordered
    }

    static func matchesConversation(
        _ candidateURL: String,
        targetURL: String
    ) -> Bool {
        guard let candidate = URLNormalizer.target(candidateURL),
              let target = URLNormalizer.target(targetURL)
        else { return false }
        return candidate.key == target.key
    }

    static func focus(
        url: String,
        location: ChromeTabLocation?,
        processIDs: [pid_t]
    ) -> Bool {
        let preferredProcessID = location.flatMap { hintedLocation in
            processIDs.contains(hintedLocation.processID ?? -1)
                ? hintedLocation.processID
                : nil
        }
        let orderedProcessIDs = orderedProcessIDs(
            processIDs,
            preferredProcessID: preferredProcessID
        )

        for processID in orderedProcessIDs {
            guard let application = configuredApplication(
                processID: processID
            ) else { continue }
            let errorDelegate = application.delegate
                as? ChromeScriptingErrorDelegate
            guard let windows = application.value(forKey: "windows")
                as? SBElementArray
            else { continue }

            var foundExistingTab = false

            if processID == preferredProcessID,
               let location,
               let window = window(
                id: String(location.windowID),
                in: windows
               ),
               let tabs = window.value(forKey: "tabs") as? SBElementArray,
               location.tabIndex > 0,
               location.tabIndex <= tabs.count,
               let tab = tabs[location.tabIndex - 1] as? SBObject,
               let currentURL = tab.value(forKey: "URL") as? String,
               matchesConversation(currentURL, targetURL: url) {
                foundExistingTab = true
                if reveal(
                    window: window,
                    tabIndex: location.tabIndex,
                    application: application,
                    errorDelegate: errorDelegate
                ) {
                    return true
                }
            }

            for case let window as SBObject in windows {
                guard let tabs = window.value(forKey: "tabs")
                    as? SBElementArray
                else { continue }
                for (zeroBasedIndex, value) in tabs.enumerated() {
                    guard let tab = value as? SBObject,
                          let currentURL = tab.value(forKey: "URL")
                            as? String,
                          matchesConversation(currentURL, targetURL: url)
                    else { continue }
                    foundExistingTab = true
                    if reveal(
                        window: window,
                        tabIndex: zeroBasedIndex + 1,
                        application: application,
                        errorDelegate: errorDelegate
                    ) {
                        return true
                    }
                }
            }

            // A matching tab must never fall through to the creation path.
            // Chrome can silently ignore a window-ordering command while its
            // activation is settling; opening here would create a duplicate.
            if foundExistingTab {
                return false
            }
        }

        guard let processID = orderedProcessIDs.first,
              let application = configuredApplication(processID: processID),
              let windows = application.value(forKey: "windows")
                as? SBElementArray
        else { return false }
        let errorDelegate = application.delegate
            as? ChromeScriptingErrorDelegate
        return open(
            url: url,
            windows: windows,
            application: application,
            errorDelegate: errorDelegate
        )
    }

    private static func configuredApplication(
        processID: pid_t
    ) -> SBApplication? {
        guard let application = SBApplication(processIdentifier: processID)
        else { return nil }
        application.timeout = 5 * 60
        application.delegate = ChromeScriptingErrorDelegate()
        return application
    }

    private static func rawWindowID(_ window: SBObject) -> String? {
        stringValue(window.value(forKey: "id"))
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    private static func property(
        _ key: String,
        from value: Any?
    ) -> Any? {
        if let properties = value as? [String: Any] {
            return properties[key]
        }
        if let properties = value as? NSDictionary {
            return properties[key]
        }
        return nil
    }

    private static func window(
        id: String,
        in windows: SBElementArray
    ) -> SBObject? {
        return windows.object(withID: id) as? SBObject
    }

    private static func reveal(
        window: SBObject,
        tabIndex: Int,
        application: SBApplication,
        errorDelegate: ChromeScriptingErrorDelegate?
    ) -> Bool {
        guard let targetWindowID = rawWindowID(window) else {
            return false
        }
        var tracker = ChromeFocusSettleTracker(
            requiredConfirmations: requiredStableFocusConfirmations
        )

        for attempt in 0..<focusRetryAttemptCount {
            errorDelegate?.reset()
            guard let windows = application.value(forKey: "windows")
                as? SBElementArray,
                  let currentWindow = self.window(
                    id: targetWindowID,
                    in: windows
                  )
            else {
                tracker.reset()
                if attempt + 1 < focusRetryAttemptCount {
                    Thread.sleep(forTimeInterval: focusRetryInterval)
                }
                continue
            }

            // Activation and Chrome's own key-window restoration are both
            // asynchronous. Reassert the stable-ID target on every attempt so
            // a delayed Chrome key-window restoration cannot win the race.
            currentWindow.setValue(false, forKey: "minimized")
            currentWindow.setValue(tabIndex, forKey: "activeTabIndex")
            currentWindow.setValue(1, forKey: "index")

            // The ordering write can invalidate position-based proxies. Fetch
            // the application window collection again before verification.
            let verificationWindows = application.value(forKey: "windows")
                as? SBElementArray
            let frontWindowProperties = (
                verificationWindows?.firstObject as? SBObject
            )?.value(forKey: "properties")
            let snapshot = ChromeFocusSnapshot(
                isMinimized: booleanValue(property(
                    "minimized",
                    from: frontWindowProperties
                )),
                isTargetFrontWindow: stringValue(property(
                    "id",
                    from: frontWindowProperties
                )) == targetWindowID,
                activeTabIndex: integerValue(property(
                    "activeTabIndex",
                    from: frontWindowProperties
                )),
                appleEventFailed: errorDelegate?.didFail == true
            )
            if tracker.observe(snapshot, targetTabIndex: tabIndex) {
                return true
            }

            if attempt + 1 < focusRetryAttemptCount {
                Thread.sleep(forTimeInterval: focusRetryInterval)
            }
        }
        return false
    }

    private static func open(
        url: String,
        windows: SBElementArray,
        application: SBApplication,
        errorDelegate: ChromeScriptingErrorDelegate?
    ) -> Bool {
        if windows.count > 0,
           let frontWindow = windows[0] as? SBObject {
            return addTab(
                url: url,
                to: frontWindow,
                application: application,
                errorDelegate: errorDelegate
            )
        }

        let newWindow = SBObject(
            elementCode: windowElementCode,
            properties: [:],
            data: nil
        )
        errorDelegate?.reset()
        windows.add(newWindow)
        guard errorDelegate?.didFail != true,
              newWindow.lastError() == nil,
              let tabs = newWindow.value(forKey: "tabs") as? SBElementArray
        else { return false }

        if tabs.count > 0,
           let firstTab = tabs[0] as? SBObject {
            errorDelegate?.reset()
            firstTab.setValue(url, forKey: "URL")
            guard errorDelegate?.didFail != true else { return false }
            return reveal(
                window: newWindow,
                tabIndex: 1,
                application: application,
                errorDelegate: errorDelegate
            )
        }
        return addTab(
            url: url,
            to: newWindow,
            application: application,
            errorDelegate: errorDelegate
        )
    }

    private static func addTab(
        url: String,
        to window: SBObject,
        application: SBApplication,
        errorDelegate: ChromeScriptingErrorDelegate?
    ) -> Bool {
        guard let tabs = window.value(forKey: "tabs") as? SBElementArray
        else { return false }
        let previousCount = tabs.count
        let tab = SBObject(
            elementCode: tabElementCode,
            properties: ["URL": url],
            data: nil
        )
        errorDelegate?.reset()
        tabs.add(tab)
        let createdTabIndex = tabs.count
        guard errorDelegate?.didFail != true,
              tab.lastError() == nil,
              createdTabIndex > previousCount
        else { return false }
        return reveal(
            window: window,
            tabIndex: createdTabIndex,
            application: application,
            errorDelegate: errorDelegate
        )
    }
}

struct MonitorObservation {
    struct RunContinuity {
        let startedAt: Date
        let lastSampleAt: Date
        let recoverableUntil: Date?

        init(
            startedAt: Date,
            lastSampleAt: Date,
            recoverableUntil: Date? = nil
        ) {
            self.startedAt = startedAt
            self.lastSampleAt = lastSampleAt
            self.recoverableUntil = recoverableUntil
        }
    }

    let state: ChatState
    let observedAt: Date
    let pageInstance: String?
    let promptInstance: String?
    let responseInstance: String?
    let runContinuity: RunContinuity?
    let pendingTerminalAt: Date?
    // Positive tab-presence evidence is distinct from an active run. A probe
    // can be unavailable even though Chrome successfully returned the tab.
    let lastPresentAt: Date?

    init(
        state: ChatState,
        observedAt: Date,
        pageInstance: String? = nil,
        promptInstance: String? = nil,
        responseInstance: String? = nil,
        runContinuity: RunContinuity? = nil,
        pendingTerminalAt: Date? = nil,
        lastPresentAt: Date? = nil
    ) {
        self.state = state
        self.observedAt = observedAt
        self.pageInstance = pageInstance
        self.promptInstance = promptInstance
        self.responseInstance = responseInstance
        self.runContinuity = runContinuity
        self.pendingTerminalAt = pendingTerminalAt
        self.lastPresentAt = lastPresentAt
    }
}

enum ChatGPTRuntimeReducer {
    // ChatGPT swaps controls and assistant nodes between response phases.
    // Debounce terminal signals and retain a bounded continuity lease.
    static let terminalConfirmationDelay: TimeInterval = 2
    static let continuityGrace: TimeInterval = 8

    static func transition(
        sample: ChromeTabSample,
        previous: MonitorObservation?,
        observedAt: Date
    ) -> MonitorObservation {
        let promptChanged = previous?.promptInstance != nil
            && sample.promptInstance != nil
            && previous?.promptInstance != sample.promptInstance
        let resolvedPromptInstance = sample.promptInstance
            ?? previous?.promptInstance
        let resolvedResponseInstance = promptChanged
            ? sample.responseInstance
            : sample.responseInstance ?? previous?.responseInstance

        let continuedRunStart = previous.flatMap { observation -> Date? in
            guard let continuity = observation.runContinuity else { return nil }
            let startedAt = continuity.startedAt
            let lastSampleAt = continuity.lastSampleAt
            if let recoverableUntil = continuity.recoverableUntil {
                guard sample.status == .running else { return nil }
                // A response phase can mount a new assistant message after a
                // false terminal signal. Within the recovery lease, only a new
                // prompt is a definitive boundary; leaf response IDs may churn.
                let hasExactResponseIdentity = observation.responseInstance?.hasPrefix(
                    "message:"
                ) == true && observation.responseInstance == sample.responseInstance
                if observedAt > recoverableUntil,
                   !hasExactResponseIdentity {
                    return nil
                }
            }
            if promptChanged { return nil }

            let hasExactIdentity = observation.promptInstance != nil
                && observation.responseInstance != nil
                && observation.promptInstance == sample.promptInstance
                && observation.responseInstance == sample.responseInstance
            if !hasExactIdentity,
               observedAt.timeIntervalSince(lastSampleAt) > continuityGrace {
                return nil
            }
            return startedAt
        }

        switch sample.status {
        case .unavailable:
            return interrupted(
                previous: previous,
                observedAt: observedAt,
                confirmsPresence: true
            )

        case .running:
            let startedAt = continuedRunStart ?? observedAt
            // A running sample admitted through the recovery lease is positive
            // evidence that the response resumed. Promote it back to normal
            // active continuity so tool/thinking phases without an assistant
            // message ID cannot expire a fixed deadline mid-run.
            return MonitorObservation(
                state: .running(startedAt: startedAt),
                observedAt: observedAt,
                pageInstance: sample.pageInstance,
                promptInstance: resolvedPromptInstance,
                responseInstance: resolvedResponseInstance,
                runContinuity: .init(
                    startedAt: startedAt,
                    lastSampleAt: observedAt
                ),
                lastPresentAt: observedAt
            )

        case .failed:
            if let startedAt = continuedRunStart {
                let pendingTerminalAt = previous?.pendingTerminalAt ?? observedAt
                if observedAt.timeIntervalSince(pendingTerminalAt)
                    < terminalConfirmationDelay {
                    return MonitorObservation(
                        state: .running(startedAt: startedAt),
                        observedAt: observedAt,
                        pageInstance: sample.pageInstance,
                        promptInstance: resolvedPromptInstance,
                        responseInstance: resolvedResponseInstance,
                        runContinuity: .init(
                            startedAt: startedAt,
                            lastSampleAt: observedAt
                        ),
                        pendingTerminalAt: pendingTerminalAt,
                        lastPresentAt: observedAt
                    )
                }
            }

            return MonitorObservation(
                state: .failed,
                observedAt: observedAt,
                pageInstance: sample.pageInstance,
                promptInstance: resolvedPromptInstance,
                responseInstance: resolvedResponseInstance,
                lastPresentAt: observedAt
            )

        case .idle:
            if let startedAt = continuedRunStart {
                let pendingTerminalAt = previous?.pendingTerminalAt ?? observedAt
                if observedAt.timeIntervalSince(pendingTerminalAt)
                    < terminalConfirmationDelay {
                    return MonitorObservation(
                        state: .running(startedAt: startedAt),
                        observedAt: observedAt,
                        pageInstance: sample.pageInstance,
                        promptInstance: resolvedPromptInstance,
                        responseInstance: resolvedResponseInstance,
                        runContinuity: .init(
                            startedAt: startedAt,
                            lastSampleAt: observedAt
                        ),
                        pendingTerminalAt: pendingTerminalAt,
                        lastPresentAt: observedAt
                    )
                }

                return MonitorObservation(
                    state: .finished(
                        duration: max(0, pendingTerminalAt.timeIntervalSince(startedAt))
                    ),
                    observedAt: observedAt,
                    pageInstance: sample.pageInstance,
                    promptInstance: resolvedPromptInstance,
                    responseInstance: resolvedResponseInstance,
                    runContinuity: .init(
                        startedAt: startedAt,
                        lastSampleAt: observedAt,
                        recoverableUntil: observedAt.addingTimeInterval(
                            continuityGrace
                        )
                    ),
                    lastPresentAt: observedAt
                )
            }

            if !promptChanged,
               case .finished(let duration) = previous?.state {
                return MonitorObservation(
                    state: .finished(duration: duration),
                    observedAt: observedAt,
                    pageInstance: sample.pageInstance,
                    promptInstance: previous?.promptInstance ?? sample.promptInstance,
                    responseInstance: previous?.responseInstance ?? sample.responseInstance,
                    runContinuity: previous?.runContinuity,
                    lastPresentAt: observedAt
                )
            }

            return MonitorObservation(
                state: .idle,
                observedAt: observedAt,
                pageInstance: sample.pageInstance,
                promptInstance: resolvedPromptInstance,
                responseInstance: resolvedResponseInstance,
                lastPresentAt: observedAt
            )
        }
    }

    static func interrupted(
        previous: MonitorObservation?,
        observedAt: Date,
        confirmsPresence: Bool = false
    ) -> MonitorObservation {
        return MonitorObservation(
            state: .failed,
            observedAt: observedAt,
            pageInstance: previous?.pageInstance,
            promptInstance: previous?.promptInstance,
            responseInstance: previous?.responseInstance,
            runContinuity: previous?.runContinuity,
            pendingTerminalAt: previous?.pendingTerminalAt,
            lastPresentAt: confirmsPresence
                ? observedAt
                : previous?.lastPresentAt
        )
    }

    static func absent(
        previous: MonitorObservation?,
        observedAt: Date,
        enumerationIsComplete: Bool
    ) -> MonitorObservation {
        enumerationIsComplete
            ? missing(previous: previous, observedAt: observedAt)
            : interrupted(previous: previous, observedAt: observedAt)
    }

    static func presentedState(
        for observation: MonitorObservation?,
        now: Date
    ) -> ChatState {
        guard let observation else { return .checking }
        guard now.timeIntervalSince(observation.observedAt) < continuityGrace
        else { return .failed }
        return observation.state
    }

    static func missing(
        previous: MonitorObservation?,
        observedAt: Date
    ) -> MonitorObservation {
        let retainedContinuity = previous?.runContinuity.flatMap { continuity in
            if let recoverableUntil = continuity.recoverableUntil {
                return observedAt <= recoverableUntil ? continuity : nil
            }
            if observedAt.timeIntervalSince(continuity.lastSampleAt) <= continuityGrace {
                return continuity
            }
            return nil
        }
        let hasRecentPresence = previous?.lastPresentAt.map {
            observedAt.timeIntervalSince($0) <= continuityGrace
        } ?? false
        let shouldRetainKnownTab = retainedContinuity != nil
            || hasRecentPresence

        if let previous, shouldRetainKnownTab {
            let retainedState: ChatState? = switch previous.state {
            case .idle, .running, .failed, .finished: previous.state
            case .unconfigured, .invalid, .checking, .closed: nil
            }
            if let retainedState {
                return MonitorObservation(
                    state: retainedState,
                    observedAt: observedAt,
                    pageInstance: previous.pageInstance,
                    promptInstance: previous.promptInstance,
                    responseInstance: previous.responseInstance,
                    runContinuity: retainedContinuity,
                    pendingTerminalAt: previous.pendingTerminalAt,
                    lastPresentAt: previous.lastPresentAt
                )
            }
        }

        return MonitorObservation(
            state: .closed,
            observedAt: observedAt,
            pageInstance: previous?.pageInstance,
            promptInstance: previous?.promptInstance,
            responseInstance: previous?.responseInstance,
            runContinuity: retainedContinuity,
            pendingTerminalAt: previous?.pendingTerminalAt,
            lastPresentAt: previous?.lastPresentAt
        )
    }

    static func strongestSamples(
        _ samples: [ChromeTabSample],
        configuredTargetKeys: Set<String>,
        preferredPageInstances: [String: String]
    ) -> [String: ChromeTabSample] {
        var strongest: [String: ChromeTabSample] = [:]

        for sample in samples {
            guard let targetKey = URLNormalizer.target(sample.url)?.key,
                  configuredTargetKeys.contains(targetKey)
            else { continue }

            guard let current = strongest[targetKey] else {
                strongest[targetKey] = sample
                continue
            }

            let currentPriority = priority(current.status)
            let samplePriority = priority(sample.status)
            let currentIsPreferred = current.pageInstance
                == preferredPageInstances[targetKey]
            let sampleIsPreferred = sample.pageInstance
                == preferredPageInstances[targetKey]
            let canUsePreferredPage = current.status != .running
                && sample.status != .running

            if canUsePreferredPage, currentIsPreferred != sampleIsPreferred {
                if sampleIsPreferred {
                    strongest[targetKey] = sample
                }
            } else if samplePriority > currentPriority {
                strongest[targetKey] = sample
            } else if samplePriority == currentPriority,
                      current.pageInstance != preferredPageInstances[targetKey],
                      sample.pageInstance == preferredPageInstances[targetKey] {
                strongest[targetKey] = sample
            }
        }

        return strongest
    }

    private static func priority(_ status: ChromeProbeStatus) -> Int {
        switch status {
        case .running: 4
        case .unavailable: 3
        case .failed: 2
        case .idle: 1
        }
    }
}
