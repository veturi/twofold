# Twofold — implementation plan

A native, open-source visual diff tool for macOS. Version 1 does two things and does them beautifully: compare two text files, and compare two folders.

Status: version 1 implemented. See README.md for usage. One addition beyond this plan: modified blocks with unequal line counts are split into similar line pairs and plain additions or removals, matching how the reference screenshots group changes. Image diff (side by side, overlay and pixel difference) and syntax highlighting have been added since; see README.md. Section 11 is the roadmap from here.

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
- Syntax highlighting (the renderer is designed to take coloured runs).
- Git integration beyond being a difftool (no changeset browsing, no history). Since then, section 11.5 added a view of the working copy's uncommitted changes; history is still out.
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
      Welcome/               start window: Compare, Recents, Git, What's New
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

Superseded by section 11. All four have shipped; the last three are described in section 11.4.

1. Syntax highlighting. It is visible in the reference and accounts for much of its look, so it comes first.
2. Ignore-whitespace toggle.
3. Find in pane (Command-F).
4. Unified layout.

## 10. Open point

Three reference screenshots have been received and section 3 is matched against them: code in Fluid layout, a multi-file comparison with the sidebar in Blocks layout, and prose in Fluid layout. All three are light theme. The dark theme is designed by carrying the same tokens over to dark backgrounds.

The prose screenshot uses a proportional font. v1 uses a monospaced font for every file, because the wrapping arithmetic in section 4.3 depends on it. Proportional text for prose files is a later addition.

## 11. Roadmap after v1

Sections 1 to 10 describe version 1 as it was planned and built. This section is the plan from here on and replaces the ordering in section 9. The public version of it is the Roadmap section of `docs/index.html`; keep it in step with this table. The Mac App Store item alone is deliberately left off the website, which presents Twofold as completely free and open source, until 11.6 has been decided.

| # | Item | Status |
|---|---|---|
| – | Image diff: side by side, overlay, pixel difference | Shipped |
| – | Syntax highlighting, 29 languages and formats | Shipped |
| – | Merge stage 1: copy changes between sides, save, undo | Shipped |
| – | Merge stage 2: edit in place | Shipped |
| – | Three-way merge, usable as `git mergetool` | Shipped |
| – | Unified layout, ignore whitespace, find | Shipped |
| – | Live working copy changes | Shipped |
| – | Start window: Compare, Recents, Git and What's New | Shipped |
| 1 | Optional automatic updates from GitHub (11.8) | Planned |
| 2 | Mac App Store build | To be planned; not decided (11.6) |

Proportional fonts for prose (section 10) stay unscheduled.

### 11.1 Merge stage 1: copy changes, save, undo

Shipped. What follows is the plan as written; it was built that way except where noted here:

- The copy buttons sit on the current change in the ribbon in Fluid layout. Blocks layout has no ribbon, so there the same actions are in the bottom bar, the Merge menu (⌥⌘→ and ⌥⌘←) and a right-click menu on the change, all of which work in both layouts. There are no gutter buttons.
- One Save (⌘S) writes every edited side; there is no separate Save All.
- Quitting with unsaved changes shows one prompt for all windows rather than one per window.
- When a file changes on disk while the other side has edits, the unedited side is refreshed in place and the undo history is cleared; the question is only asked when the changed file is itself edited.
- A file whose text cannot be written back unchanged (invalid UTF-16) cannot be merged into. A Latin-1 file that receives characters outside Latin-1 is offered a save as UTF-8.

Merge and edit is split in two because the halves differ so much in size. Copying a whole change from one side to the other fits the existing model: every change is already a block with a line range on each side, and a full re-diff (about 43 ms for 100,000 lines, tokenizing about 80 ms in parallel) is fast enough to run after each copy. Typing into a pane is a different job (11.2).

In order:

1. **Lossless load and save.** `TextDocument` currently discards what is needed to write a file back: whether the last line ends with a terminator, the terminator of each line when a file mixes them, and the encoding as something to encode with (it keeps only a display name, and whether there was a BOM is folded into that name). Record these, add `TextDocument.encoded() -> Data`, and test that load followed by save reproduces the original bytes for every supported encoding and line-ending style. Nothing else starts until this round-trips, because without it a save would change lines the user never touched.
2. **Editable document model.** A per-side line buffer that the diff is recomputed from, a dirty flag per side, and an undo stack of line-range replacements (`NSUndoManager`, so ⌘Z and ⇧⌘Z come with the menu items). Scroll position and the current change are kept across the re-diff, as reload does today.
3. **Copy actions.** For the current change: copy to the right, copy to the left. An added or removed block copies as an insertion or deletion. Buttons sit in the ribbon next to each change in Fluid layout and in the gutter in Blocks layout, with menu items and shortcuts under Navigate or a new Merge menu. Copying a selection of several changes is not in this stage.
4. **Saving.** Explicit ⌘S (and Save All for both sides), not autosave: the files are usually under version control and a diff tool should not write without being asked. The window shows the edited dot, and closing a window, switching file in a folder comparison, swapping sides, reloading and quitting all ask about unsaved changes first.
5. **File watching.** `FileWatcher` must ignore the app's own writes, and when a file with unsaved edits changes on disk it must ask rather than reload over them.
6. **Folder comparison.** Saving updates the file's status in the sidebar. Copying a whole file that exists on one side only (and deleting one) is left for later.

Out of this stage: typing, three-way merge, binary and image files.

### 11.2 Merge stage 2: edit in place

Shipped. As built:

- Typing, deletion, cut, paste, Return with the current line's indentation, and Tab, in either pane of an editable comparison. Caret movement by character, word, line and visual row, with Shift to select. Input methods work through `NSTextInputClient`.
- The whole file is diffed and tokenized again after every keystroke, off the main thread. Keystrokes that arrive meanwhile wait in a queue and are applied in order, so nothing is lost and nothing runs against stale text. There is no incremental path: on very large files typing lags by the time of one diff and tokenizing pass. Measured: about 0.1 s for 100,000 lines with 1% changed (from the benchmarks), and about 1 s per keystroke on a 91,500-line file with 13,500 changes.
- Consecutive keystrokes on one side are one undo step. After undo or redo the caret goes to the end of the lines that changed, not to its exact earlier position.
- The keyboard edits only after a click has placed a caret; before that the arrow keys and Space scroll, as in v1.
- Not built: typing into an empty file or a file that exists on one side only, drag and drop of text, multiple carets, and find and replace.

The plan as written:

A caret, typing, deletion, paste and cut in either pane, on top of the document model, undo and save from stage 1. The canvas has selection and copy today but no caret and no text input, so this needs `NSTextInputClient` (including marked text for input methods), caret movement by character, word and line across wrapped rows, and auto-scroll to the caret. Re-diffing on every keystroke is fine for ordinary files and needs debouncing, or an incremental path, for very large ones; the syntax map has to be refreshed the same way.

### 11.3 Three-way merge

Shipped. `twofold --wait --base "$BASE" --output "$MERGED" "$LOCAL" "$REMOTE"` opens a merge window; that command is the `mergetool.twofold.cmd` for git. As built:

- **Layout.** The top half is the ordinary diff canvas comparing A (local) with B (remote), read-only. The bottom half is the result, an editable text view. The base has no pane of its own; it only decides what is merged automatically.
- **Algorithm.** A diff3-style merge in `DiffCore/ThreeWayMerge.swift`: lines of the base that survive on both sides split the files into chunks. A chunk only one side changed takes that side, an identical change on both sides is taken once, and a chunk both sides changed differently is a conflict (after setting aside the lines the two sides share at either end of it). Edits to neighbouring lines conflict, as in git. Resolving every conflict as ours, theirs or both gives the same bytes as `git merge-file --ours`, `--theirs` and `--union` on the test fixture, and conflict-free merges are checked against `git merge-file` in the tests.
- **No base.** When git has no common ancestor (the base file is missing or empty), every difference between the two sides is a conflict.
- **Conflicts are text.** An unresolved conflict sits in the result between git's conflict markers. Nothing else records whether a conflict is resolved: it is resolved when its markers are gone, however that happened (a side was taken, or the text was edited by hand). Undo therefore needs no bookkeeping of its own.
- **Choosing.** Every change has two rings in the ribbon, ticked for the side or sides the result holds. Clicking one takes that side; ⌥⌘1, ⌥⌘2 and ⌥⌘3 take A, B or both for the current change. Unresolved conflicts are amber in both halves, and ⌃⌘↓ / ⌃⌘↑ step through them.
- **Saving.** ⌘S writes the result to the output file in that file's encoding and line-ending style (A's, if the file does not exist yet). Saving with conflicts left asks first; closing with an unsaved result asks too. Git is told nothing through the exit code (`trustExitCode false`): it sees that the file was written.
- **Setup.** The Git page of the start window (also Twofold › Git Integration…) has a switch each for diff tool and merge tool. It runs `git config --global` itself and points git at the launcher inside the app bundle by full path, so nothing needs to be on the `PATH`. The switches show what the configuration says, including another tool being set or a hand-written command.
- **Not built:** a pane for the base, syntax colours, line numbers and visible line endings in the result pane, per-line terminators in the result (a file with mixed line endings is saved with its most common one), reloading when an input changes on disk, merging images or binary files, and starting a merge from the start window (it is command-line only).

### 11.4 Unified layout, ignore whitespace, find

Shipped. As built:

- **Unified layout.** A third layout mode beside Blocks and Fluid, drawn by the same canvas with both sides in one pane. An unchanged line is shown once, as B's, with A's and B's line numbers; a change shows A's lines and then B's. Here old lines are red and new lines green whatever the kind of change, because in one column that is what tells them apart; the overview strip keeps the colours of the change kinds. Editing, copying changes and find all work in it. It has no ribbon, so the copy arrows are only in the bottom bar and the menu. A merge window ignores it and stays side by side.
- **Ignore whitespace.** One switch, off by default. Lines are compared without their leading and trailing whitespace and with every run of whitespace as one space, so re-indenting and re-aligning stop being changes, while a space added where there was none is still one. Inside changed lines, whitespace is not highlighted. The status bar says when it is on, and says "Only whitespace differs" when that is all there is. It does not apply to folder statuses or to merges.
- **Find.** ⌘F opens a bar above the panes that searches both files as you type: not case sensitive, plain text, no replace. Every match is highlighted and ticked in the overview strip; ⌘G and ⇧⌘G step through them in reading order and wrap around, a match inside folded lines opens the fold, and the current match becomes the selection. The search stops counting at 20,000 matches. In a merge window find searches the result, with the text view's own find bar.
- **Not built:** regular expressions, case-sensitive and whole-word search, replace, a separate search of the two top panes of a merge, and finer whitespace options (ignore all whitespace, or only line ends).

### 11.5 Live working copy changes

Shipped. One folder inside a Git repository (`twofold .`, File › Open Repository…, or a drop) opens a window on everything not yet committed. As built:

- **What is compared.** The last commit (HEAD) on the left, the working copy on the right. The index is not a third side: a staged change and an unstaged one both show as differences from HEAD, and the sidebar marks the file as staged or partly staged. Untracked files are listed as added.
- **Same window as a folder comparison.** The sidebar, filter, layouts, find and editing are the ones folder comparisons have. The committed version of the selected file is written to a temporary folder for the left side, which is read-only; the right side is the real file and can be edited and saved.
- **Live.** The repository folder is watched with FSEvents, `.git` included, so edits, staging, commits, checkouts and reverts all lead to a new `git status` shortly after. The selected file stays selected while it is still changed; when it is not, the first file is selected, and when nothing is left the window says so. A file with unsaved edits here is never switched away from. Git is run with `GIT_OPTIONAL_LOCKS=0` so that reading the status does not rewrite the index and wake the watcher again.
- **Pause.** A toolbar button freezes both the list and the open file; resuming catches up.
- **Stepping.** Next Change past the last change of a file opens the next file, and Previous Change before the first opens the previous file at its last change. Folder comparisons got this too.
- **Not built:** notifications while the app is in the background, file history, staging, committing or discarding from the window, comparing against the index or another commit, detecting a working copy behind `git difftool --dir-diff`, and changes inside submodules. Opened repositories are remembered in the start window (11.7).

### 11.6 Open point: Mac App Store build

Twofold is free and open source, and that does not change. A Mac App Store build is being considered as a way to cover the project's small running costs (Apple's developer fee, the domain), but it is not a commitment: it needs its own plan first, and the outcome of that plan may be not to do it. Nothing public (website, README) should promise it, name a price or a date until then.

The reason it needs a separate plan is the sandbox, which costs the app real functionality. Section 2 turns the sandbox off, which is right for the GitHub build. A Mac App Store build must be sandboxed, and a sandboxed app cannot write to (or, strictly, read) arbitrary paths passed on the command line without the user granting access. The sandboxed build also cannot run `git` or write `~/.gitconfig`, so its Git page will have to show the commands to copy instead of switches, and the working copy window (11.5), which depends on running `git status`, needs another way to read a repository or has to be left out of that build. Saving already goes through one place (`DiffViewController.save()`), so that security-scoped access could be added there.

The plan has to answer, before any build work starts:

- **Git.** Whether a build without `git` (no working copy window, no Git tool switches, possibly a weaker `git difftool`/`git mergetool` launcher) is still worth publishing, or whether there is an acceptable way to keep those features inside the sandbox.
- **File access.** How paths from the command line, drops and folder comparisons get security-scoped access without a permission prompt for every comparison.
- **Two builds.** What it costs to keep a sandboxed variant building and tested next to the GitHub build, and how users are told which features each has.
- **Price and licence.** Whether to charge and how much. The contribution terms in `CONTRIBUTING.md` and the trademark policy already leave room for the maintainer to publish there.
- **Worth it at all.** Whether the income would cover the costs it is meant to cover, against the extra work and a lesser app carrying the same name.

### 11.7 Start window

Shipped. The window that opens without files, rebuilt after a design in `design/welcome.fig` (OpenPencil; PNG exports in `design/out/`). As built:

- **Layout.** A 960 by 620 window: a translucent sidebar (Compare, Recents, Git, What's New) over artwork drawn in code (`RibbonBackgroundView`), a fan of curves like the comparison ribbon with four bands in the change colours. All of it is in `Theme` as light and dark pairs.
- **Compare** is where it always opens: the app icon, wells A and B joined by a small ribbon, Choose Files… (⌘O, one panel for both sides) and Open Repository… (⇧⌘O), and the three newest recents. There is no Compare button: the comparison opens as soon as both wells hold two files or two folders, whether dropped, chosen or both. Dropping two items anywhere in the window opens them; one fills the next empty well. A file and a folder show an error in the well filled last.
- **Recents** lists up to 30 comparisons and repositories, grouped into Today, Yesterday and Earlier, with a filter, Clear…, and on hover Show in Finder and Remove. Entries whose files are gone are hidden. Repositories opened for their working copy changes are recorded too.
- **Git** shows recent repositories as cards with their branch and number of changes (read with `git status` when the page opens), and the diff and merge tool switches that used to be the Git Integration window. Twofold › Git Integration… opens this page.
- **What's New** has the highlights of the latest major release, from `WhatsNew` in `WhatsNewPage.swift`. The sidebar badges it with the version until it has been opened once; it never opens by itself. Change `WhatsNew.version` and the features with each major release.
- **Snapshots.** `--page compare|recents|git|whats-new` picks the page. Test data comes in as user defaults for that run only, e.g. `-recentComparisons '<array>…</array>'` and `-whatsNewSeen 1.1`.

### 11.8 Optional automatic updates from GitHub

Planned. The app learns about new versions from the project's GitHub releases and, in the end, installs them itself. It is optional: the automatic check is something the user turns on (asked once, or off by default), and Check for Updates… in the app menu always works by hand. The only thing a check sends is a request to GitHub for the latest release; that has to be said plainly wherever the app is described as having no telemetry.

Two stages:

1. **Check and notify.** Ask the GitHub releases API for the latest release, compare it with the running version, and offer a link to the release page. Needs no signing.
2. **Download and install in place.** Download the zip, verify it, replace the bundle and relaunch. This waits for Developer ID signing and notarization: the app can then check that an update is signed by the same team, and permissions granted by the user survive updates. On ad-hoc builds it would need a signing key of our own for a worse result, so it is not built for them.

Constraints: no third-party dependencies, so no Sparkle; an app that macOS runs from a read-only copy (still in Downloads) cannot replace itself and should say so; a Homebrew cask must be marked as updating itself; a Mac App Store build (11.6) must leave the updater out.
