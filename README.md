# CopyCauldron

A fast, native macOS clipboard manager that lives in your menu bar. Captures text, files, and images; supports pinning, search, keyboard navigation, and one-tap auto-paste.

<!-- TODO: add a screenshot of the popover here -->
<!-- ![CopyCauldron screenshot](docs/screenshot.png) -->

## Features

- **Universal capture** — text, file URLs (copied from Finder), and images (e.g. `⌘⌃⇧4` screenshots).
- **Search** — instant filter across the entire history.
- **Pinned items** — keep favorites at the top, immune from the history-size cap and the Clear button. Configurable max (default 20).
- **Keyboard-first** — global hotkey opens the popover, then `↑/↓` to navigate, `Return` to activate, `/` to search, `Esc` to close.
- **Pin shortcuts** — press `1`–`9` while the popover is open to instantly paste a pinned item.
- **Auto-paste** — opt-in: the selected item is pasted directly into the previously active app (requires Accessibility permission).
- **Global hotkey** — customizable; defaults to `⌘⇧V`.
- **Auto-open on hover** — opt-in: popover opens when you hover the menu-bar icon.
- **Drag-to-resize** — drag the bottom-right grip; the size persists.
- **Right-click actions** — Reveal in Finder, Open, Copy path as text (files); Save as…, Open in Preview (images); Open in browser (URLs).
- **Launch at login** — toggle in Preferences.
- **Local-only** — all history lives on your Mac; nothing is sent anywhere.

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon or Intel Mac

## Install

### Pre-built (recommended)

1. Download `CopyCauldron.app.zip` from the latest [Releases](https://github.com/codexjdub/CopyCauldron/releases) page.
2. Unzip and drag `CopyCauldron.app` to `/Applications`.
3. Launch it. The cauldron icon appears in your menu bar.
4. (Optional) Open System Settings → Privacy & Security → Accessibility, enable **CopyCauldron**, and relaunch — required for auto-paste.

> First launch may require right-click → **Open** to bypass Gatekeeper since the app isn't notarized.

### Build from source

CopyCauldron builds with the Swift command-line tools — **no full Xcode required**.

```bash
git clone https://github.com/codexjdub/CopyCauldron.git
cd CopyCauldron
./scripts/build.sh           # debug build → .build/CopyCauldron.app
./scripts/build.sh release   # release build
open .build/CopyCauldron.app
```

The build script:

- Compiles the Swift package
- Assembles the `.app` bundle and `Info.plist`
- Code-signs with a local identity (override via `COPYCAULDRON_SIGN_IDENTITY="My Cert" ./scripts/build.sh`) or falls back to ad-hoc

To make auto-paste survive rebuilds, sign with a stable self-signed identity (see [Build notes](#build-notes)).

## Usage

### Default shortcuts

| Action | Shortcut |
|---|---|
| Open / close popover | `⌘⇧V` (configurable) |
| Move selection | `↑` / `↓` |
| Activate selected item | `Return` |
| Paste pinned item *n* | `1`–`9` |
| Focus search field | `/` |
| Clear search → unfocus → close | `Esc` |

Click the menu-bar icon to open the popover with the mouse. Click any item to activate it. Right-click for contextual actions.

### Preferences

Open via the gear icon in the popover footer.

- **Global Shortcut** — record your own combo.
- **General** — Launch at login, auto-open on hover, auto-paste on selection.
- **History** — total history size (10–500), max pinned items (1–100).

## Privacy

- Clipboard history is stored locally at `~/Library/Application Support/CopyCauldron/`.
- Images are cached as PNG files alongside `history.json`.
- Nothing is sent over the network. No telemetry.
- See [`TODO.md`](TODO.md) for planned exclusions (password-manager filtering).

## Build notes

- **Self-signed identity**: rebuilds change the ad-hoc cdhash, which makes macOS re-prompt for Accessibility permission every time. Create a self-signed certificate in Keychain Access (Certificate Assistant → Create a Certificate → Self Signed Root, Code Signing), then sign builds with it. `scripts/build.sh` picks up the identity named `dj` by default; override with `COPYCAULDRON_SIGN_IDENTITY="YourCertName"`.
- **No Xcode required**: the project uses Swift Package Manager. `xcodebuild` is not needed.

## Roadmap

See [`TODO.md`](TODO.md) for upcoming items, including:

- Exclude password managers from history (concealed-pasteboard convention).

## License

[MIT](LICENSE) © 2026 codexjdub.

---

Built with Swift, SwiftUI, and AppKit on macOS.
