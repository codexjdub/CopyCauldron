# CopyCauldron

A fast, native macOS clipboard manager that lives in your menu bar. Captures text, files, and images; supports pinning, search, drag-out workflows, keyboard navigation, and one-tap auto-paste.

<!-- TODO: add a screenshot of the popover here -->
<!-- ![CopyCauldron screenshot](docs/screenshot.png) -->

## Features

- **Universal capture** — text, file URLs (copied from Finder), and images (e.g. `⌘⌃⇧4` screenshots). Image files (PNG/JPG/HEIC/etc.) get inline thumbnails.
- **Smart row icons** — text items are auto-categorized: URL, email, hex color (with a real color swatch), JSON, IP, UUID, Git SHA, Unix/ISO timestamp, base64, currency, hashtag, mention, phone.
- **Source app context** — new clipboard items remember the best-effort source app, show it in row metadata, and include app names / bundle IDs in search.
- **Search** — instant filter across the entire history.
- **Hover preview** — linger on a long text item for ~600ms to see a scrollable preview without copying it.
- **Pinned items** — keep favorites at the top, immune from the history-size cap and the Clear button. Configurable max (default 20, up to 100).
- **Keyboard-first** — global hotkey opens the panel, then `↑`/`↓` to navigate, `Return` to activate, `p` to pin/unpin, `/` to search, `Esc` to close.
- **Pin shortcuts** — press `1`–`9` then `a`–`o`, `q`–`z` while the panel is open to instantly paste pinned items #1–#34. (`p` is reserved for pin/unpin.)
- **Quick switcher HUD** — second hotkey (default `⌘⌥V`) pops a compact overlay anchored to the text caret of the focused field, showing your most-recent unpinned items. Press `1`–`N` (configurable 2–9) to paste, `↑`/`↓` + `Return` for keyboard nav, `Shift+number` or `Shift+Return` to invert plain-text mode for that paste, `Esc` to dismiss. Falls back to mouse cursor positioning when the focused app doesn't expose a text caret.
- **Persistent panel, two modes** — the panel stays open until you press `Esc` or click the **X** in its header. Use the **pin** in the header to flip between "floating above other windows" (always on top) and "regular window" (other apps can come forward over it). Move the panel by its top handle, resize it from any edge.
- **Drag out items** — drag text, images, and files from the panel into other apps.
- **Rich-text aware** — captures RTF and HTML alongside plain text so styled paste round-trips. Toggle plain-text mode in Preferences or hold `Shift` while activating to invert it for one paste.
- **Auto-paste** — opt-in: the selected item is pasted directly into the target app (requires Accessibility permission). CopyCauldron remembers the most recently activated non-CopyCauldron app and pastes there.
- **Global hotkeys** — two customizable combos: one for the main panel (default `⌘⇧V`), one for the quick switcher HUD (default `⌘⌥V`).
- **Auto-open on hover** — opt-in: panel opens when you hover the menu-bar icon.
- **Right-click actions** — Reveal in Finder, Open, Copy path as text (files); Save as…, Open in Preview (images); Open in browser (URLs).
- **Robust file references** — files copied from Finder are tracked by inode via bookmark data, so Reveal / Open / drag-out follow renames and moves; when the file is genuinely gone, an alert tells you instead of silently doing nothing.
- **Menu-bar context menu** — right-click the cauldron icon for Preferences or Quit.
- **Launch at login** — toggle in Preferences.
- **Auto-expire** — optional retention window (Off / 1h / 24h / 7d) automatically purges old unpinned items. Pinned items are never expired.
- **App exclusions** — choose apps in Preferences whose copied items should never enter history.
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

To make auto-paste survive rebuilds, sign with a stable self-signed identity by setting `COPYCAULDRON_SIGN_IDENTITY` to the name of your Keychain code-signing certificate.

## Usage

### Default shortcuts

**Main panel** (default `⌘⇧V`):

| Action | Shortcut |
|---|---|
| Toggle main panel | `⌘⇧V` (configurable) |
| Move selection | `↑` / `↓` |
| Activate selected item | `Return` |
| Activate with plain-text mode inverted | `Shift` + `Return` |
| Pin / unpin selected item | `p` |
| Paste pinned item #1–#9 | `1`–`9` |
| Paste pinned item #10–#34 | `a`–`o`, `q`–`z` *(skipping `p`)* |
| Focus search field | `/` |
| Clear search → unfocus → close panel | `Esc` |

**Quick switcher HUD** (default `⌘⌥V`):

| Action | Shortcut |
|---|---|
| Toggle quick switcher | `⌘⌥V` (configurable) |
| Move selection | `↑` / `↓` |
| Activate selected item | `Return` |
| Activate with plain-text mode inverted | `Shift` + `Return` |
| Paste item #1–#N directly | `1`–`N` (Shift+ inverts plain-text mode) |
| Dismiss without pasting | `Esc` or click outside |

Click the menu-bar icon to open the main panel. Click any item to activate it, or drag items into another app. Use the top handle to move the panel; resize from any edge; click the **pin** to flip between floating-on-top and regular-window modes; click the **X** to dismiss. Right-click items for contextual actions.

### Preferences

Open via the gear icon in the panel footer or by right-clicking the menu-bar icon.

- **Global Shortcut** — record the main-panel hotkey.
- **General** — Launch at login, auto-open on hover, auto-paste on selection, text size.
- **History** — total history size (10–500), max pinned items (1–100), auto-expire window.
- **Quick Switcher** — record the HUD hotkey, and choose how many rows it shows (2–9).
- **Privacy** — choose source apps whose copied items should never be saved.

The "Plain" chip in the panel footer toggles plain-text-only pasting for text items, stripping rich formatting and compacting runs of extra blank lines; hold `Shift` while activating (or pressing a digit shortcut) to invert it for a single paste.

## Privacy

- Clipboard history is stored locally in a SQLite database at `~/Library/Application Support/CopyCauldron/history.db`.
- Images are cached as PNG files in the same directory under `images/`.
- Nothing is sent over the network. No telemetry.
- **Excluded apps**: add password managers, browsers, or any other app in Preferences → Privacy to prevent copied items from that app from entering history. Browser extensions appear as their host browser, so excluding a password-manager extension means excluding that browser.

## License

[MIT](LICENSE) © 2026 codexjdub.

---

Built with Swift, SwiftUI, and AppKit on macOS.
