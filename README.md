# Joy

Joy is a compact macOS overlay for monitoring ChatGPT and Codex tasks.

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
