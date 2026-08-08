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
