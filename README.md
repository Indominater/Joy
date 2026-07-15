# Joy

Joy is a compact, always-on macOS panel for monitoring up to three existing ChatGPT conversations and Codex tasks. It is a single app: there is no browser extension, native-messaging host, helper executable, account connection, or API key.

Joy does **not** send prompts or store conversation text.

## Requirements

- macOS 13 or newer
- Google Chrome for ChatGPT monitoring
- The Codex or ChatGPT desktop app for `codex://threads/...` links
- Swift 6 command-line tools (only needed to build)

## Build and install

1. Run `./scripts/build-app.sh` from this folder.
2. Quit any older copy of Joy, move `build/Joy.app` to `/Applications`, and open it.
3. In Chrome, enable **View → Developer → Allow JavaScript from Apple Events** once.
4. Paste up to three supported links into Joy:
   - `https://chatgpt.com/c/...`
   - `codex://threads/...`

Link rows are display-only. Click an empty row, identified by its native
`#43DDE6` teal caret,
then paste to fill it. A configured row rejects Paste until its × button is
used to clear it. Configured rows use calm labels such as
`ChatGPT · 3bda4b` and `Codex · 8aac6b`; click a label to open its target, or
drag it to move Joy. Right-click anywhere in a configured link field to the
left of ×, including its padding, to copy the full link. After clearing a link,
that row's status capsule offers Undo for five seconds; Command-Z performs the
same single Undo. Only the newest clear is kept, and there is no Redo.

The first configured ChatGPT link causes macOS to ask whether Joy may control Google Chrome. Allow it so Joy can inspect response controls and focus matching tabs. Codex monitoring requires no permission prompt.

## How monitoring works

- **ChatGPT:** Joy asks Chrome for the status of visible response controls in all open `chatgpt.com` tabs. It never reads assistant or user message text.
- **Codex:** Joy incrementally reads only lifecycle records from the task's existing local rollout log under `~/.codex/sessions`. The task ID in the deep link identifies the matching log.

Clicking a ChatGPT row focuses its existing Chrome tab. Clicking a Codex row opens its task through the `codex://` deep link.

## Statuses

- **Ready** — no link is configured.
- **Idle** — the conversation or task exists, but no response is active.
- **Running** — a response is active; the elapsed timer stays live.
- **Done** — a response Joy observed has completed; its duration is frozen.
- **Failed** — the response failed or was interrupted. ChatGPT rows also use this state when Chrome Automation is unavailable.
- **Closed** — no matching open ChatGPT tab or local Codex task log was found.

Codex completion durations come from Codex's lifecycle event. ChatGPT durations are measured by Joy's polling interval and can differ by about one second.

## Fullscreen behavior

Joy uses a nonactivating panel that joins every Space and other apps' fullscreen sets. It stays above normal and fullscreen windows. macOS can still hide overlays on the lock screen, secure system dialogs, and protected fullscreen surfaces.

Joy appears in the Dock and also keeps a menu bar icon. Its panel independently joins other applications' Spaces without becoming part of their window sets. Closing Joy's window leaves the app available from either location. Click Joy in the Dock or use **Show Joy** from its menu bar icon to restore the panel; choose **Quit Joy** to stop monitoring.

## Privacy and compatibility

Configured links are saved locally in macOS preferences. Joy does not create a shared status file or transmit monitoring data.

ChatGPT does not expose a supported consumer-chat status API, so its monitor depends on page controls that may change. Codex monitoring depends on the local rollout lifecycle format used by the installed Codex app. Either integration may need a small update after a product UI or storage-format change.
