# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Twofold (formerly VisDiff; the directory and some history still use the old name) is a native macOS visual diff tool: two text files or two images side by side, or two folders with a sidebar of changed files. Swift 6.2 package, AppKit, macOS 26+, no third-party dependencies. Everything builds from the command line. There is no `.xcodeproj`, so don't create one. `RATIONALE.md` explains why the project exists: open source, no subscriptions, built with AI. Keep product decisions consistent with it. `PLAN.md` holds the design intent and scope of v1, and its section 11 is the roadmap from here (next: three-way merge). The public roadmap on the website must say the same.

## Commands

```sh
make app                       # swift build + scripts/bundle.sh → build/Twofold.app (ad-hoc signed)
make start ARGS="a.txt b.txt"  # build and open a comparison (files or folders)
make test                      # swift test
make bench                     # release-mode BenchmarkTests (diff and syntax, 100k lines)
make release                   # universal arm64 + x86_64 bundle
make icon                      # regenerate Resources/AppIcon.icns from scripts/make-icon.swift
```

Run a single test: `swift test --filter DiffTests/testInlineHighlightsWords` (classes are `TextDocumentTests`, `DiffTests`, `ImageDiffTests`, `SyntaxTests`, `FolderTests`, `BenchmarkTests`, all in `Tests/DiffCoreTests/DiffCoreTests.swift`). `testMatchesSystemDiff` cross-checks against `/usr/bin/diff`.

`swift build` alone produces a bare executable. Use `make app` / `scripts/bundle.sh` to get a runnable `.app` with its Info.plist and icon.

### Checking UI without a screen

The app renders a window offscreen to a PNG and exits. Use this to verify any visual change, in both appearances and both layouts:

```sh
build/Twofold.app/Contents/MacOS/Twofold --snapshot out.png [--appearance light|dark] [--layout fluid|blocks] \
  [--size 1360x860] [--change N] [--scale 2] [--wrap|--no-wrap] [--font-size 12] [--file rel/path] [--bench] \
  [--image-mode side-by-side|overlay|difference] [--zoom 2] [--syntax|--no-syntax] \
  [--copy left|right] [--caret left:12:4] [--type "text"] [--undo] [--save] A B
```

`--change` is 1-based and selects the current change. `--file` picks the initially selected file in a folder comparison. `--bench` prints frame render times while scrolling. `--image-mode` and `--zoom` (points per pixel) apply when A and B are images. `--copy` copies the current change to that side before capturing; `--caret side:line:column` (one-based) places the caret and `--type` types text there (`\n` is Return, and ← → ↑ ↓ ⌫ act as those keys); `--undo` then undoes the last step and `--save` writes the edited files. They exist to test editing without a screen. Options are parsed in `LaunchOptions` (`Sources/Twofold/AppDelegate.swift`), and snapshot overrides to preferences stay in memory only (`Preferences.overrides`).

## Architecture

Two targets. `DiffCore` has no AppKit dependency and is the only tested module. `Twofold` is the AppKit app and depends on `DiffCore`, never the reverse.

**DiffCore pipeline:** `TextDocument.decode` (BOM → UTF-8 → Latin-1 fallback; NUL byte means binary; LF/CRLF/CR all split lines, and a line-ending difference alone is not a change) → `TextDiff.init` interns lines to `Int32` → `Myers.matches` (own O(ND) implementation with a time limit fallback) → `makeBlocks` turns match flags into `equal/added/removed/modified` `DiffBlock`s → `splitModified` splits unequal-length modified blocks into similar line pairs plus plain adds/removes → `InlineDiff` computes word-then-character highlight ranges (UTF-16 offsets) for modified lines. Everything the UI draws derives from `TextDiff.blocks`. `FolderCompare` walks both trees, pairs by relative path, and resolves statuses concurrently, streaming results.

**Text diff view (`Sources/Twofold/TextDiff/`):** a single custom `DiffCanvasView` draws both panes, the centre ribbon with Bézier connectors, and the overview strip, and owns scrolling. It is not built from separate NSScrollViews or NSTextViews, which differs from the earlier sketch in PLAN.md §4. `DiffLayout` turns blocks into `LayoutSection`s (equal, fold, change) in a shared logical scroll space `t`, with a per-side `y`/`span`. Fluid mode maps `t` to each side piecewise-linearly so the centred change stays aligned. Blocks mode uses equal spans. Row counts for wrapping come from column arithmetic in `TextMetrics`/`Columns` (monospaced-font assumption), so lines are never typeset just to measure them. Typeset rows are cached as `CTLine`s. `DiffViewController` runs the diff off the main thread and hosts the canvas, path bars and bottom bar (`Bars.swift`).

**Syntax highlighting:** `DiffCore/Syntax.swift` is a lexical tokenizer with no dependencies. `SyntaxLanguage.detect` picks a language from the file name or `#!` line, and `highlight` returns a `SyntaxMap`: per-line `SyntaxSpan`s (UTF-16 ranges and a `SyntaxKind`), with state such as an open block comment carried across lines. Most languages are a `Grammar` (keywords, comment and string delimiters, a few flags) run by the shared `CodeLexer`; HTML/XML, CSS, YAML and Markdown have their own lexers, and HTML hands `<script>` and `<style>` bodies to the JavaScript and CSS ones. To add a language, add a `Grammar` case, its name and its extensions in `Languages`, plus a test. `DiffViewController.compute` tokenizes both sides concurrently with the diff, and `DiffCanvasView.ctline` applies `Theme.syntax` colours when it typesets a row. A row with tokens must give its plain text an explicit colour too, because Core Text leaves the last token's colour set in the context.

**Merging:** `TextDocument` is lossless: `lines`, per-line `terminators` and `textEncoding` reproduce the file byte for byte through `encoded()`, and `replacingLines` edits a range while keeping the terminators of untouched lines and the state of the file's end. Keep it that way; `testEncodedReproducesTheFile` and `testRandomTextRoundTrips` guard it. `DiffViewController` owns the working copies (`docs`), which equal the files until `copyChange(to:)` replaces the current change's lines on one side and `rediff()` diffs the copies again. `editCounts` tracks unsaved edits per side (up on change and redo, down on undo) and `undo` is the window's undo manager. `save()` is the only place that writes compared files (atomic, permissions kept, symlinks followed), which is also where sandbox access would go. `filesChanged()` ignores the app's own saves by comparing `FileStamp`s, reloads when nothing is edited, and asks when an edited side changed on disk. Everything that would drop edits (close, quit, reload, swap, switching file, drop) goes through `confirmUnsavedChanges`.

**Editing in place** lives in the extensions at the bottom of `DiffCanvasView.swift`. The canvas keeps the caret as an empty selection, implements `NSTextInputClient` (ranges are UTF-16 offsets within the caret's line, and text being composed by an input method is inserted into the document straight away as `marked`), and overrides the `NSResponder` movement and deletion commands. `keyDown` hands keys to `interpretKeyEvents` only when the comparison is editable and a selection exists; otherwise the keyboard scrolls. Every operation goes through `perform`, which queues it while `busy` (from the start of a re-diff until `setDiff` has shown the result), so each keystroke runs against the document on screen and none is dropped. Text changes go to `onEdit` → `DiffViewController.replaceText` → `TextDocument.replacingText`, and the caret for the new document arrives through `pendingSelection`. Consecutive keystrokes on one side share an undo step (`typingRun` in the canvas, `typingSide` in the controller). `setDiff(edit:)` takes a `LineEdit` and uses it to keep opened folds open and to move a selection on the edited side.

**Image diff (`Sources/Twofold/ImageDiff/`):** `DiffViewController.compute` tries text first; when either side is binary it calls `ImageComparison.load`, which decodes with ImageIO (first frame, EXIF orientation applied, sRGB RGBA8, scaled down above 64 megapixels) and falls back to the binary placard if a file is not an image. The pixel comparison itself is `ImageDiff` in DiffCore: plain buffers in; a per-pixel strength mask, a count and region bounding boxes out. The two images are aligned top left and missing pixels count as transparent. `ImageDiffView` draws the three `ImageMode`s (side by side, overlay, difference) and owns zoom and pan, shared by both sides. While an image is shown, `DiffViewController` swaps the bottom bar to image controls, and `ComparisonWindowController` routes ⌘+/⌘-/⌘0 to zoom and disables the Blocks/Fluid toolbar group.

**Shell:** `AppDelegate` (launch args, menus, open/drop handling), `ComparisonWindowController` (one window per comparison, toolbar, files vs folders kind), `FolderDiff/FolderSidebarController` (flat list grouped by directory breadcrumbs, filter, status toggles), `Welcome/` (start window and recent comparisons), `FileWatcher` (reload on disk change, keeping scroll position), `Preferences` (UserDefaults-backed, posts `Preferences.didChange`).

**Colours:** all colours are defined in `Theme.swift` as dynamic light/dark pairs. Don't put colour literals elsewhere. For drawing, `Palette` (bottom of `DiffCanvasView.swift`) resolves them to `CGColor` once per appearance. Change hues: blue for modified, green for added, red for removed. Purple is the app accent and is never used as a change colour.

## Other files

- `scripts/twofold` is the CLI launcher (`--wait` for `git difftool`). `make install` copies it to `~/.local/bin` with the app path baked in.
- `docs/` is the GitHub Pages site at https://twofoldapp.org (`docs/CNAME`): plain HTML with Tailwind from a CDN and no build step. `index.html` is the main page; `<slug>/index.html` are comparison pages (Kaleidoscope, Beyond Compare, FileMerge, Meld) that duplicate the nav, footer and Tailwind theme, so change those everywhere. Each page carries JSON-LD in `<head>`, and visible FAQ text must match its `FAQPage` data. New pages go into `sitemap.xml`; facts about the app (features, requirements, price) also live in `llms.txt` for AI assistants, so keep it current. Screenshots are real `--snapshot ... --scale 2` renders; `make social-card` rebuilds the 1200×630 link preview from them. Cloudflare Web Analytics loads from `assets/analytics.js` once its token is set there.
- Releases: pushing a `v*` tag runs `.github/workflows/release.yml` (tests, universal build stamped via `VERSION`/`BUILD` env for `bundle.sh`, optional Developer ID signing and notarization, zip + SHA-256 to a GitHub release).
- License is GPLv3, but the name and icon are reserved (`TRADEMARKS.md`). Contributions carry an extra licence grant for the App Store build (`CONTRIBUTING.md`).
