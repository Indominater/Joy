import Foundation

enum ChromeProbeStatus: String, Sendable {
    case idle
    case running
    case failed
}

struct ChromeTabSample: Sendable {
    let url: String
    let status: ChromeProbeStatus
    let pageInstance: String
    let promptInstance: String?
    let responseInstance: String?

    init(
        url: String,
        status: ChromeProbeStatus,
        pageInstance: String,
        promptInstance: String? = nil,
        responseInstance: String? = nil
    ) {
        self.url = url
        self.status = status
        self.pageInstance = pageInstance
        self.promptInstance = promptInstance
        self.responseInstance = responseInstance
    }
}

enum ChromeMonitorResult: Sendable {
    case success([ChromeTabSample])
    case unavailable(String)
}

enum ChromeAppleEventsMonitor {
    private static let fieldSeparator = "|||JOY_FIELD|||"
    private static let recordSeparator = "|||JOY_RECORD|||"

    private static let script = #"""
    on run argv
        set probeScript to item 1 of argv
        set fieldSeparator to "|||JOY_FIELD|||"
        set recordSeparator to "|||JOY_RECORD|||"
        set outputText to ""
        set successfulProbeCount to 0
        set firstProbeError to ""

        if application "Google Chrome" is not running then return outputText

        tell application "Google Chrome"
            repeat with browserWindow in windows
                repeat with browserTab in tabs of browserWindow
                    try
                        set currentURL to URL of browserTab as text
                        if currentURL starts with "https://chatgpt.com/" then
                            try
                                set probeValue to execute browserTab javascript probeScript
                                set outputText to outputText & currentURL & fieldSeparator & probeValue & recordSeparator
                                set successfulProbeCount to successfulProbeCount + 1
                            on error errorMessage number errorNumber
                                if firstProbeError is "" then
                                    set firstProbeError to (errorNumber as text) & ": " & errorMessage
                                end if
                            end try
                        end if
                    end try
                end repeat
            end repeat
        end tell

        if successfulProbeCount is 0 and firstProbeError is not "" then
            return "__JOY_ERROR__" & firstProbeError
        end if
        return outputText
    end run
    """#

    private static let probeJavaScript = #"""
    (() => {
      const visible = (element) => {
        if (!element || element.getClientRects().length === 0) return false;
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
        '[data-testid*="error" i]',
        '[role="alert"]'
      ];
      const runningByText = Array.from(document.querySelectorAll('button')).some((button) =>
        visible(button) && /stop (generating|streaming|response)/i.test(
          `${button.getAttribute('aria-label') || ''} ${button.textContent || ''}`
        )
      );
      const failed = errorSelectors.some((selector) =>
        Array.from(document.querySelectorAll(selector)).some((element) =>
          visible(element) && /(error|failed|went wrong|network)/i.test(element.textContent || '')
        )
      );
      const status = visibleMatch(runningSelectors) || runningByText
        ? "running"
        : failed ? "failed" : "idle";
      const userMessages = Array.from(
        document.querySelectorAll('[data-message-author-role="user"]')
      );
      // Attribute-only identities stay stable across DOM rerenders without
      // inspecting either the prompt or response text.
      const latestUserMessage = userMessages[userMessages.length - 1];
      const latestUserTurn = latestUserMessage?.closest(
        '[data-testid^="conversation-turn-"]'
      );
      const promptInstance = latestUserMessage?.getAttribute('data-message-id')
        || latestUserTurn?.getAttribute('data-turn-id')
        || latestUserTurn?.getAttribute('data-testid')
        || "";
      const assistantMessages = Array.from(
        document.querySelectorAll('[data-message-author-role="assistant"]')
      ).filter(visible);
      const latestAssistantMessage = assistantMessages[assistantMessages.length - 1];
      const assistantFollowsPrompt = latestUserMessage && latestAssistantMessage
        && Boolean(
          latestUserMessage.compareDocumentPosition(latestAssistantMessage)
            & Node.DOCUMENT_POSITION_FOLLOWING
        );
      const latestAssistantTurn = assistantFollowsPrompt
        ? latestAssistantMessage.closest('[data-testid^="conversation-turn-"]')
        : null;
      const responseInstance = assistantFollowsPrompt
        ? latestAssistantMessage.getAttribute('data-message-id')
          || latestAssistantTurn?.getAttribute('data-turn-id')
          || latestAssistantTurn?.getAttribute('data-testid')
          || ""
        : "";
      return `${status}::JOY::${Math.round(
        performance.timeOrigin || Date.now()
      )}::JOY::${promptInstance}::JOY::${responseInstance}`;
    })()
    """#

    static func sample() -> ChromeMonitorResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, probeJavaScript]
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            return .unavailable(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return .unavailable("Chrome Automation timed out")
        }
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(message?.isEmpty == false ? message! : "Chrome Automation failed")
        }

        guard let output = String(data: outputData, encoding: .utf8) else {
            return .unavailable("Chrome returned unreadable status data")
        }
        if output.hasPrefix("__JOY_ERROR__") {
            return .unavailable(String(output.dropFirst("__JOY_ERROR__".count)))
        }

        let samples = output
            .components(separatedBy: recordSeparator)
            .compactMap { record -> ChromeTabSample? in
                guard !record.isEmpty else { return nil }
                let fields = record.components(separatedBy: fieldSeparator)
                guard fields.count == 2,
                      let normalizedURL = URLNormalizer.normalizeChatGPT(fields[0])
                else { return nil }

                let probeFields = fields[1].components(separatedBy: "::JOY::")
                guard probeFields.count >= 2,
                      let status = ChromeProbeStatus(rawValue: probeFields[0])
                else { return nil }
                let promptInstance = probeFields.count >= 3
                    && !probeFields[2].isEmpty
                    ? probeFields[2]
                    : nil
                let responseInstance = probeFields.count >= 4
                    && !probeFields[3].isEmpty
                    ? probeFields[3]
                    : nil

                return ChromeTabSample(
                    url: normalizedURL,
                    status: status,
                    pageInstance: probeFields[1],
                    promptInstance: promptInstance,
                    responseInstance: responseInstance
                )
            }

        return .success(samples)
    }
}

struct MonitorObservation: Equatable {
    var state: ChatState
    var observedAt: Date
    var pageInstance: String?
    var promptInstance: String?
    var responseInstance: String?
    var activeRunStartedAt: Date?
    var pendingTerminalAt: Date?
    var lastChromeSampleAt: Date?
    var consecutiveMissingSamples: Int

    init(
        state: ChatState,
        observedAt: Date,
        pageInstance: String? = nil,
        promptInstance: String? = nil,
        responseInstance: String? = nil,
        activeRunStartedAt: Date? = nil,
        pendingTerminalAt: Date? = nil,
        lastChromeSampleAt: Date? = nil,
        consecutiveMissingSamples: Int = 0
    ) {
        self.state = state
        self.observedAt = observedAt
        self.pageInstance = pageInstance
        self.promptInstance = promptInstance
        self.responseInstance = responseInstance
        self.activeRunStartedAt = activeRunStartedAt
        self.pendingTerminalAt = pendingTerminalAt
        self.lastChromeSampleAt = lastChromeSampleAt
        self.consecutiveMissingSamples = consecutiveMissingSamples
    }
}

enum ChatGPTRuntimeReducer {
    // ChatGPT briefly swaps controls between response phases. Require a stable
    // terminal signal before clearing the run epoch used by the live timer.
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
            guard let startedAt = observation.activeRunStartedAt,
                  let lastSampleAt = observation.lastChromeSampleAt
            else { return nil }
            if let previousPrompt = observation.promptInstance,
               let currentPrompt = sample.promptInstance,
               previousPrompt != currentPrompt {
                return nil
            }
            if let previousResponse = observation.responseInstance,
               let currentResponse = sample.responseInstance,
               previousResponse != currentResponse {
                return nil
            }

            let hasExactIdentity = observation.promptInstance != nil
                && observation.responseInstance != nil
                && observation.promptInstance == sample.promptInstance
                && observation.responseInstance == sample.responseInstance
            let isRecoveringToleratedMiss = observation.consecutiveMissingSamples == 1
                && observation.state == .running(startedAt: startedAt)
            if !hasExactIdentity, !isRecoveringToleratedMiss,
               observedAt.timeIntervalSince(lastSampleAt) > continuityGrace {
                return nil
            }
            return startedAt
        }

        switch sample.status {
        case .running:
            let startedAt = continuedRunStart ?? observedAt
            return MonitorObservation(
                state: .running(startedAt: startedAt),
                observedAt: observedAt,
                pageInstance: sample.pageInstance,
                promptInstance: resolvedPromptInstance,
                responseInstance: resolvedResponseInstance,
                activeRunStartedAt: startedAt,
                lastChromeSampleAt: observedAt
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
                        activeRunStartedAt: startedAt,
                        pendingTerminalAt: pendingTerminalAt,
                        lastChromeSampleAt: observedAt
                    )
                }
            }

            return MonitorObservation(
                state: .failed,
                observedAt: observedAt,
                pageInstance: sample.pageInstance,
                promptInstance: resolvedPromptInstance,
                responseInstance: resolvedResponseInstance,
                lastChromeSampleAt: observedAt
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
                        activeRunStartedAt: startedAt,
                        pendingTerminalAt: pendingTerminalAt,
                        lastChromeSampleAt: observedAt
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
                    lastChromeSampleAt: observedAt
                )
            }

            if previous?.pageInstance == sample.pageInstance,
               case .finished(let duration) = previous?.state {
                return MonitorObservation(
                    state: .finished(duration: duration),
                    observedAt: observedAt,
                    pageInstance: sample.pageInstance,
                    promptInstance: resolvedPromptInstance,
                    responseInstance: resolvedResponseInstance,
                    lastChromeSampleAt: observedAt
                )
            }

            return MonitorObservation(
                state: .idle,
                observedAt: observedAt,
                pageInstance: sample.pageInstance,
                promptInstance: resolvedPromptInstance,
                responseInstance: resolvedResponseInstance,
                lastChromeSampleAt: observedAt
            )
        }
    }

    static func interrupted(
        state: ChatState,
        previous: MonitorObservation?,
        observedAt: Date
    ) -> MonitorObservation {
        return MonitorObservation(
            state: state,
            observedAt: observedAt,
            pageInstance: previous?.pageInstance,
            promptInstance: previous?.promptInstance,
            responseInstance: previous?.responseInstance,
            activeRunStartedAt: previous?.activeRunStartedAt,
            pendingTerminalAt: previous?.pendingTerminalAt,
            lastChromeSampleAt: previous?.lastChromeSampleAt,
            consecutiveMissingSamples: previous?.consecutiveMissingSamples ?? 0
        )
    }

    static func missing(
        previous: MonitorObservation?,
        observedAt: Date
    ) -> MonitorObservation {
        let missingCount = (previous?.consecutiveMissingSamples ?? 0) + 1
        if missingCount == 1,
           case .running(let startedAt) = previous?.state {
            return MonitorObservation(
                state: .running(startedAt: startedAt),
                observedAt: observedAt,
                pageInstance: previous?.pageInstance,
                promptInstance: previous?.promptInstance,
                responseInstance: previous?.responseInstance,
                activeRunStartedAt: startedAt,
                pendingTerminalAt: previous?.pendingTerminalAt,
                lastChromeSampleAt: previous?.lastChromeSampleAt,
                consecutiveMissingSamples: missingCount
            )
        }

        return MonitorObservation(
            state: .closed,
            observedAt: observedAt,
            pageInstance: previous?.pageInstance,
            promptInstance: previous?.promptInstance,
            responseInstance: previous?.responseInstance,
            lastChromeSampleAt: previous?.lastChromeSampleAt,
            consecutiveMissingSamples: missingCount
        )
    }

    static func strongestSamples(
        _ samples: [ChromeTabSample],
        configuredURLs: Set<String>,
        preferredPageInstances: [String: String]
    ) -> [String: ChromeTabSample] {
        var strongest: [String: ChromeTabSample] = [:]

        for sample in samples where configuredURLs.contains(sample.url) {
            guard let current = strongest[sample.url] else {
                strongest[sample.url] = sample
                continue
            }

            let currentPriority = priority(current.status)
            let samplePriority = priority(sample.status)
            if samplePriority > currentPriority {
                strongest[sample.url] = sample
            } else if samplePriority == currentPriority,
                      current.pageInstance != preferredPageInstances[sample.url],
                      sample.pageInstance == preferredPageInstances[sample.url] {
                strongest[sample.url] = sample
            }
        }

        return strongest
    }

    private static func priority(_ status: ChromeProbeStatus) -> Int {
        switch status {
        case .running: 3
        case .failed: 2
        case .idle: 1
        }
    }
}
