# Twofold — implementation plan

A native, open-source visual diff tool for macOS. Version 1 does two things and does them beautifully: compare two text files, and compare two folders.

Status: version 1 implemented. See README.md for usage. One addition beyond this plan: modified blocks with unequal line counts are split into similar line pairs and plain additions or removals, matching how the reference screenshots group changes. Image diff (side by side, overlay and pixel difference) has been added since; see README.md.

## 1. Scope

### In scope for v1

- Compare two text files side by side, read-only.
- Compare two folders recursively, with a sidebar of changed files and the file diff alongside.
- Light and dark themes, following the system by default, with a manual override.
- Open comparisons from the command line (`twofold a b`), by drag and drop, and from an open panel.
- Usable as `git difftool`.

### Explicitly out of scope for v1

- Editing, merging, three-way merge, copying changes between sides.
- Image diff, PDF diff, binary diff beyond "these files differ".
- Syntax highlighting (the first thing to add after v1; the renderer is designed to take coloured runs).
- Git integration beyond being a difftool (no changeset browsing, no history).
- Preferences window, auto-update, notarised distribution, App Store.

## 2. Decisions

These are made so that implementation needs no further input. Each can be vetoed before the go-ahead.

| Topic | Decision | Reason |
|---|---|---|
| Language | Swift 6, strict concurrency | Native, fast, current toolchain is 6.4 |
| UI framework | AppKit, custom-drawn diff views with Core Text | SwiftUI text and lists cannot hit the scroll performance target on 100k-line files |
| Build system | Swift Package Manager plus a script that assembles the `.app` | Pure CLI, no `.xcodeproj`, nothing to open in Xcode |
| Minimum macOS | 26 | Lets the app use the current system look directly, without availability branches |
| Architecture | arm64 and x86_64 universal in release builds | Costs one flag |
| Dependencies | None | Everything needed is in the SDK; keeps the build trivial |
| Sandbox | Off, ad-hoc code signature | A diff tool must read arbitrary paths passed on the command line |
| App name | Twofold, bundle id `org.twofold.app` | Renamed from the working name VisDiff after v1 |
| Licence | GPLv3, with the name and icon reserved as trademarks | Keeps the code open while stopping closed-source and app store copies |

## 3. What it looks like

The reference is Kaleidoscope's text and folder comparison. The elements that make it recognisable, and that v1 reproduces in its own styling:

- **Two panes with a narrow ribbon between them.** Each changed block is a full-width tinted band, edge to edge in its pane, with no rounding. A modified block is joined to its counterpart by a filled Bézier connector through the centre gutter. An added block appears on the right only; on the left it is a one-pixel green line at the insertion point, which curves across the ribbon and opens into the block. Removed blocks mirror that in red.
- **Connectors are stroked, not solid.** The connector is a coloured outline about two pixels wide that traces the edge of the block on its own side, crosses the ribbon as an S-curve, and continues as a horizontal rule across the full width of the other pane at the insertion point. Modified blocks get the outline of a band with a faint fill.
- **Three change colours plus an accent.** Blue for modified, green for added, red for removed. Purple is the app accent (selected toolbar segment, A and B badges, selection in lists) and is not a change colour.
- **Two strengths per block.** An unselected change has a pale body fill and a slightly stronger gutter. The current change has a saturated gutter with white line numbers and a stronger body fill. Changed characters inside a modified line get one more step of the same hue.
- **Blocks layout has no ribbon.** The panes are separated by a single hairline and blank filler rows keep matching lines level.
- **Folder sidebar.** A floating inset panel with rounded corners on the left, hidden and shown by a toolbar button. Its header gives the totals ("98 Files", then counts of modified, added and removed with their icons). Files are a flat list grouped under dimmed directory headings written as breadcrumbs ("lib ⟩ Driver"), not a disclosure tree. Each row has a status icon tile; the selected row is a purple rounded rectangle. At the bottom is a "Filter File Name" field with three status toggles. When the sidebar is present the window subtitle names the selected file and its counts.
- **Gutter markers.** Next to the line number each changed line carries a coloured `~`, `+` or `−`.
- **Collapsed unchanged regions.** Long unchanged runs fold into a bracketed placeholder reading "126 Unchanged Lines" with an ellipsis pill. Clicking it expands the run. Three lines of context are kept around each change.
- **Soft wrapping.** Long lines wrap to the pane width; continuation rows have no line number.
- **Invisibles in changed lines.** Line-end marks are drawn dimmed inside changed blocks, so whitespace-only changes are visible.
- **Fluid scrolling.** The two sides scroll at slightly different rates so that the change nearest the viewport centre is always aligned across the ribbon. No filler lines are inserted.
- **Change markers beside the scroller.** A thin strip at the right edge shows every change in the file as a coloured tick at its proportional position.
- **Chrome.** Lavender-tinted unified title bar in light mode. The title is "left name | right name"; the subtitle is "39 Additions, 15 Deletions, 43 Changes". Toolbar buttons sit in rounded capsule groups. Above each pane is a path bar: a purple A or B badge, then the path as chevron-separated breadcrumbs ending in a file icon and name. A swap-sides button sits between the two path bars. The bottom bar shows "Change 1 of 97" with up and down arrows.
- **Motion.** Jumping to the next change is a spring-animated scroll and the target block pulses once. Theme switches cross-fade.

Present in the reference but not built in v1: the git history sidebar and commit popover, the unified layout, syntax colouring, and the bottom-left option toggles other than wrapping and invisibles.

Two layouts are offered from a toolbar segmented control:

1. **Fluid** (default) — as described above.
2. **Blocks** — both sides are padded with filler so matching lines sit on the same row and the panes scroll rigidly together.

A unified single-column layout is a stretch item (section 9).

### Theme tokens

All colours come from one `Theme` value with a light and a dark variant: window background, pane background, gutter text, body text, the three change hues at three strengths each (block fill, inline-word fill, connector stroke), selection, current-change outline. No colour literal appears outside `Theme.swift`.

Default font is SF Mono 12 pt. Command-plus and Command-minus change the size; the choice persists in user defaults.

## 4. Architecture

```
twofold/
  Package.swift
  Makefile
  PLAN.md  README.md  LICENSE
  Sources/
    DiffCore/              pure Swift, no AppKit, fully unit-tested
      TextBuffer.swift       file loading, encoding, line index
      Myers.swift            line diff
      InlineDiff.swift       word and character diff inside modified blocks
      DiffModel.swift        hunks, block kinds, stats
      FolderScanner.swift    directory walk and pairing
      FolderCompare.swift    per-file status
    Twofold/               the app executable
      main.swift  AppDelegate.swift  CommandLine.swift
      Theme.swift
      Windows/               window controller, toolbar, menus
      TextDiff/              pane view, ribbon view, scroll coordinator, line cache
      FolderDiff/            sidebar outline, status badges, filter
      Welcome/               drop-zone window
      Snapshot.swift         offscreen render to PNG, for verification
  Tests/
    DiffCoreTests/
  Resources/
    Info.plist  AppIcon.icns
  scripts/
    bundle.sh              swift build, assemble .app, ad-hoc sign
    twofold                command-line launcher
```

`DiffCore` knows nothing about the UI. The app target depends on it and never the reverse.

### 4.1 Loading text

- Files are memory-mapped. A file with a NUL byte in its first 8 KB is treated as binary and gets a placard instead of a diff.
- Encoding: BOM if present, otherwise UTF-8, otherwise Latin-1 as a lossless fallback.
- A line index (byte offset per line) is built in one pass. Lines are hashed and interned to integers so the diff compares integers, not strings.
- LF, CRLF and CR are all line terminators. A difference in terminators alone is reported in the footer and does not mark every line as changed.

### 4.2 Diff engine

- Line level: Myers O(ND) with the linear-space refinement, after trimming the common prefix and suffix. Own implementation; the standard library's `difference(from:)` degrades badly on large dissimilar inputs.
- A cost cap switches to a coarser heuristic on pathological inputs so the UI never hangs.
- Adjacent delete and insert runs are paired into **modified** blocks. Inside each modified block a second diff runs on word tokens, refined to characters for short lines, to produce the inline highlight ranges.
- Output is an array of blocks: `equal`, `added`, `removed`, `modified`, each with a left line range and a right line range. Everything the UI draws derives from this array.
- Runs off the main thread in a cancellable task. Opening a new comparison cancels the previous one.

### 4.3 Text diff view

- Each pane is one layer-backed `NSView` inside an `NSScrollView`. It draws only the lines intersecting the dirty rectangle.
- Lines are typeset with Core Text. `CTLine` objects are kept in an LRU cache keyed by line number, sized to a few screens.
- Lines soft-wrap by default, with a toggle to turn wrapping off and scroll horizontally instead. Row height is fixed, and the number of rows a line occupies is computed from its column count and the pane width without typesetting it, which is exact for a monospaced font. A prefix-sum array of row counts gives the position of any line by lookup and is rebuilt on resize in a few milliseconds even for 100,000 lines.
- The display list is built from the block array: change blocks, context lines, and fold placeholders for collapsed unchanged runs. Expanding a fold replaces its placeholder with its lines.
- The ribbon is a separate view between the panes. On every scroll it redraws the connectors for the blocks currently visible on either side.
- A scroll coordinator owns one logical scroll position. In Fluid mode it maps that position to each pane through a piecewise-linear function built from the block array; in Blocks mode both panes get the same offset.
- Text selection and copy work within one pane.

### 4.4 Folder comparison

- Both trees are walked concurrently. Entries are paired by relative path.
- Status per file: only on left, only on right, identical, different. Size mismatch settles it at once; otherwise the bytes are compared through the memory maps. Comparisons run in a task group and results stream into the UI as they arrive.
- A folder's status is the roll-up of its children.
- `.git`, `.DS_Store` and similar are skipped by default. Symbolic links are compared by target path and not followed.
- UI: a sidebar `NSTableView` with group rows for directories, as described in section 3. Identical files are hidden unless a toggle shows them. The name filter and status toggles apply as you type. Up and down arrows move through files. Selecting a file shows its text diff in the detail area using exactly the same view as file comparison. Files that exist on one side only show against an empty pane.

### 4.5 Application shell

- One window per comparison; native window tabs work for free.
- With no arguments the app shows a welcome window with two drop wells and a Compare button.
- Dropping two files or two folders on the Dock icon or on a window starts a comparison.
- Menus and shortcuts: open (Command-O), next and previous change (Command-Down and Command-Up), layout switch, appearance (System, Light, Dark), font size, reload (Command-R).
- The compared files are watched; when one changes on disk the diff recomputes and keeps the scroll position.

### 4.6 Command line

`scripts/twofold` is installed to a directory on the path by `make install`. It resolves its arguments to absolute paths and launches the app with them. With `--wait` it blocks until the window closes, which is what `git difftool` needs. The README carries the git configuration snippet.

## 5. Performance targets

Measured on this machine with release builds; each has a benchmark or a signpost.

| Measure | Target |
|---|---|
| Cold launch to first diff drawn, two 1,000-line files | under 150 ms |
| Diff of two 100,000-line files with 1% changed | under 150 ms |
| Scrolling a 100,000-line diff | no dropped frames at 120 Hz |
| Folder comparison, 10,000 files per side, mostly identical | first results under 100 ms, complete under 2 s |
| Memory for a 100 MB file pair | well under twice the file size beyond the maps |

## 6. Verification

No part of this needs a person to look at the screen until the end.

- **Unit tests** (`swift test`) for the diff engine: hand-written cases, edge cases (empty files, no trailing newline, all changed, identical), and a property test that applies the computed diff to the left side and must reproduce the right side over thousands of random inputs.
- **Cross-check** against `/usr/bin/diff` on a corpus of real files: same number of changed lines.
- **Folder tests** against fixture trees built in a temporary directory.
- **Benchmarks** as a separate test target that prints timings against the table in section 5.
- **Visual check**: the app accepts `--snapshot out.png` with a pair of paths, renders the window offscreen in a given appearance, writes a PNG and exits. I inspect those images for both themes and both layouts after every UI milestone. This needs no screen-recording permission.

## 7. Milestones

Each milestone ends with passing tests and a commit. More commits land inside milestones where natural.

| # | Milestone | Done when |
|---|---|---|
| 0 | Repository skeleton | `git init`, package, Makefile, licence, README stub; `make app` produces an empty window that launches |
| 1 | Diff core | Loading, line diff, inline diff, block model; unit, property and cross-check tests pass; diff benchmark meets target |
| 2 | Text diff view, Blocks layout | Two panes, gutters with change markers, tinted blocks, inline highlights, soft wrapping, folded unchanged runs, invisibles, both themes; snapshot images look right |
| 3 | Ribbon and Fluid layout | Connectors including the line-to-block form for additions and removals, fluid scroll mapping, layout switch; scrolling benchmark meets target |
| 4 | Shell | Toolbar, title and subtitle, breadcrumb path bars with swap button, bottom bar with change counter, change markers beside the scroller, change navigation with animation, menus, welcome window, drag and drop, appearance override, font size |
| 5 | Folder comparison | Scanner, streaming status, sidebar, filter, detail view; folder benchmark meets target |
| 6 | Command line and polish | `twofold` launcher with `--wait`, git difftool instructions, file watching, app icon, binary and error placards, README with screenshots |

## 8. Risks

| Risk | Mitigation |
|---|---|
| Fluid scroll mapping feels wrong at block boundaries or at the ends of the file | Build Blocks first so there is always a correct layout; tune Fluid against snapshot sequences |
| Row counts from column arithmetic are wrong for wide or combining characters | Count display columns, not code units; fall back to typesetting the line when it contains non-ASCII |
| Custom text view lacks things `NSTextView` gives free (selection, accessibility, find) | v1 implements selection and copy only; find is a stretch item; accessibility exposes each pane as static text by line |
| SwiftPM executables are not app bundles | `bundle.sh` assembles the bundle and signs it; resources that must be found at run time live in the bundle, not in the package resource bundle |
| Pathological diffs (two large unrelated files) | Cost cap in the Myers loop with a coarse fallback |

## 9. Stretch items, in order, only if v1 is finished

1. Syntax highlighting. It is visible in the reference and accounts for much of its look, so it comes first.
2. Ignore-whitespace toggle.
3. Find in pane (Command-F).
4. Unified layout.

## 10. Open point

Three reference screenshots have been received and section 3 is matched against them: code in Fluid layout, a multi-file comparison with the sidebar in Blocks layout, and prose in Fluid layout. All three are light theme. The dark theme is designed by carrying the same tokens over to dark backgrounds.

The prose screenshot uses a proportional font. v1 uses a monospaced font for every file, because the wrapping arithmetic in section 4.3 depends on it. Proportional text for prose files is a later addition.
