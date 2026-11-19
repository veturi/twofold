# Twofold

A native, fast, good-looking visual diff tool for macOS. Free and open source, no subscription: a Kaleidoscope alternative you don't have to rent.

**[twofoldapp.org](https://twofoldapp.org)** · [Download](https://github.com/veturi/twofold/releases/latest)

It compares two text files or two images side by side, or two folders with a sidebar of changed files.

- **Fluid layout.** Change blocks on each side are joined by curves through a centre ribbon, and the two sides scroll so the change at the centre of the window stays aligned. No filler lines.
- **Blocks layout.** Both sides are padded so matching lines sit on the same row.
- **Unified layout.** Both files in one column: unchanged lines once, with both line numbers; a change shows its old lines in red, then its new lines in green.
- **Find.** ⌘F searches both files at once, highlights every match and marks them in the overview strip. ⌘G and ⇧⌘G step through them, opening folded lines on the way. In a merge window, find searches the result.
- **Ignore whitespace.** With ⌥⌘B, indentation, trailing whitespace and the amount of whitespace between words stop counting as differences. Whitespace added where there was none still counts.
- Word-level highlights inside modified lines, refined to characters where only part of a word changed.
- Unchanged runs fold into "N Unchanged Lines"; click to expand.
- Soft wrapping, line-end marks in changed lines, an overview strip of every change, and animated next/previous change navigation.
- **Edit in place.** Click in either pane and type, paste, cut or delete. The diff updates as you go.
- **Copy changes across.** Copy any change to the other side with the arrows on it or ⌥⌘→ / ⌥⌘←, undo with ⌘Z, save with ⌘S. Saving rewrites only the lines you changed: the encoding, each line's line ending and whether the file ends with a newline stay as they were.
- **Three-way merge.** As `git mergetool`, Twofold shows your version and theirs side by side with the result below. Changes only one side made are merged already; each conflict is marked until you take a side, take both, or edit the result yourself.
- **Working copy changes.** Open a folder in a Git repository and Twofold lists every file that differs from the last commit and compares the committed version with your working copy. The window follows edits, staging, commits and reverts as they happen.
- **Syntax highlighting** on top of the change colours, for Swift, C, C++, Objective-C, Java, Kotlin, C#, Scala, Dart, JavaScript, TypeScript, Python, Ruby, Go, Rust, PHP, shell, SQL, Lua, HTML, XML, CSS, JSON, YAML, TOML, INI, Markdown, Makefile and Dockerfile. The language comes from the file name or a `#!` line.
- **Image diff.** Two images open side by side, as an overlay you can fade from one to the other, or as a difference view that highlights every changed pixel, more strongly the more it changed, and outlines the changed regions. Zoom and pan apply to both sides at once.
- Light and dark themes, following the system or set manually.
- Folder comparison runs in parallel and streams results while it works.
- Files reload automatically when they change on disk.

## Requirements

- macOS 26 or later
- A Swift 6.2 or later toolchain: Xcode 26 or later, or the Command Line Tools (`xcode-select --install`)

The Xcode IDE is never opened; everything builds from the command line.

## Run

```sh
make start                         # build and open the start window
make start ARGS="old.txt new.txt"  # build and compare two files
make start ARGS="dirA dirB"        # build and compare two folders
```

## Install

```sh
make install
```

This copies `Twofold.app` to `~/Applications` and the `twofold` command to `~/.local/bin`. Make sure that directory is on your `PATH`. Then:

```sh
twofold a.swift b.swift
twofold --wait a.swift b.swift   # block until the window closes
```

### Working copy changes

```sh
twofold .
```

With one folder that is inside a Git repository, Twofold opens that repository's working copy changes: every file that differs from the last commit (HEAD), untracked files included. **File › Open Repository…** (⇧⌘O) and dropping the folder on the app do the same.

- A is the committed version and is read-only. B is the file in your working copy; you can edit and save it, or copy a change from A to take it back.
- The window is live. Edits, new files, `git add`, commits, checkouts and reverts show up within a moment, whoever makes them: you, your editor, a terminal or a coding agent. Open it before you start and it fills in as you go.
- Marks in the sidebar: ✓ staged, half circle partly staged, ? untracked, ⚠ unmerged.
- **Pause Updates** (⌥⌘P, or the pause button in the toolbar) freezes the window on one state. Resuming catches up.
- ⌘↓ and ⌘↑ step through the changes of one file and then move on to the next file.

Twofold only reads the repository: it does not stage, commit or discard, and it shows no history. Changes inside submodules are left out.

### With git

Open Twofold, choose **Twofold › Git Integration…** (or the **Git** page of the start window) and turn on **Diff tool**, **Merge tool** or both. Twofold writes the settings to your global Git configuration, pointing Git at the launcher inside the app, so this works without `make install` and without anything on your `PATH`. Turning a switch off removes the settings again. If you move the app, open the page once more and click **Use This Copy of Twofold**.

The two sections below set up the same thing by hand, using the `twofold` command on your `PATH`.

### As git difftool

```sh
git config --global diff.tool twofold
git config --global difftool.twofold.cmd 'twofold --wait "$LOCAL" "$REMOTE"'
git config --global difftool.prompt false
```

Then `git difftool` compares files one by one, and `git difftool -d` compares whole trees in a folder window.

### As git mergetool

```sh
git config --global merge.tool twofold
git config --global mergetool.twofold.cmd 'twofold --wait --base "$BASE" --output "$MERGED" "$LOCAL" "$REMOTE"'
git config --global mergetool.twofold.trustExitCode false
```

After a conflict, `git mergetool` opens each conflicted file in a merge window. The top half compares A (your version, `$LOCAL`) with B (theirs, `$REMOTE`); the bottom half is the result that will be saved to the file.

- Changes that only one side made are in the result already. A tick in the ribbon shows which side each change was taken from.
- Where both sides changed the same lines differently, the change is amber and the result holds both versions between conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`), as git writes them.
- Click a ring in the ribbon to take that side, or use ⌥⌘1 (A), ⌥⌘2 (B) and ⌥⌘3 (both, A first). This works for any change, not only conflicts.
- The result is ordinary editable text: type the resolution yourself whenever neither side is right. A conflict counts as resolved once its markers are gone.
- Save with ⌘S and close the window. Git takes the saved file as the resolution. Saving with conflicts left asks first.

The same command works outside git: `twofold --base base.txt --output merged.txt mine.txt theirs.txt`. Without `--base`, every difference between the two files is a conflict.

## Keyboard

| Keys | Action |
|---|---|
| ⌘↓ / ⌘↑ | Next / previous change, moving on to the next / previous file in a folder or repository window |
| ⌥⌘↓ / ⌥⌘↑ | Next / previous file (folders) |
| ⌥⌘→ / ⌥⌘← | Copy the current change to the right / left |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Merge: use A / B / both for the current change |
| ⌃⌘↓ / ⌃⌘↑ | Merge: next / previous unresolved conflict |
| ⌘X / ⌘C / ⌘V | Cut / copy / paste |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘S | Save edited files |
| ⌘F / ⌘G / ⇧⌘G | Find / next match / previous match |
| ⌘E | Find the selected text |
| ⌘1 / ⌘2 / ⌘3 | Blocks / Fluid / Unified layout |
| ⌥⌘B | Ignore whitespace |
| ⌥⌘L | Wrap lines |
| ⌥⌘I | Show invisibles |
| ⌥⌘Y | Syntax highlighting |
| ⌥⌘E | Expand all unchanged lines |
| ⌘4 / ⌘5 / ⌘6 | Images: side by side / overlay / difference |
| ⌘+ / ⌘- / ⌘0 | Text size, or image zoom (⌘0 is actual size) |
| ⌘9 | Zoom image to fit |
| ⇧⌘S | Swap sides |
| ⌘R | Reload |
| ⌘O | New comparison |
| ⇧⌘O | Open a Git repository's working copy changes |
| ⌥⌘P | Pause / resume updates (repository window) |

You can also drop two files or two folders on the Dock icon or on any window.

Typing and copying changes edit the comparison in memory; nothing touches the disk until you save, and an edited side is marked "Edited" in its path bar. Twofold asks before closing, reloading, swapping sides or switching files with unsaved changes. If a file you have edited changes on disk, it asks whether to keep your changes or reload.

Once you have clicked in a pane, the keyboard edits there: arrow keys move the caret (with ⇧ to select, ⌥ by word, ⌘←/⌘→ to the ends of the line), Return keeps the line's indentation, and Space types a space. Before you click, the arrow keys and Space scroll as they always did. Files that exist on one side only, binary files and images are not editable.

Images are whatever macOS can decode (PNG, JPEG, HEIC, TIFF, GIF, WebP and more); the first frame is used for animated and multi-page files. They are compared pixel by pixel from their top-left corners, so two images of different sizes differ wherever only one of them has visible pixels. Scroll or drag to pan, pinch to zoom, and double-click to switch between fit and actual size.

## Development

```sh
make test      # unit tests: diff engine, property tests, cross-check against diff(1), save round trips, folders, image diff, syntax
make bench     # diff and syntax benchmarks (100,000 lines)
make release   # universal arm64 + x86_64 bundle
make icon      # regenerate Resources/AppIcon.icns
```

`DiffCore` holds the text and image diff engines, the syntax tokenizer and folder comparison with no AppKit dependency. `Twofold` is the AppKit app. The diff view draws with Core Text into a single custom view and caches typeset rows.

The app can render a window offscreen to a PNG, which is how the UI is checked without a screen:

```sh
build/Twofold.app/Contents/MacOS/Twofold --snapshot out.png [--appearance dark] [--layout blocks|fluid|unified] [--ignore-whitespace] [--find text] [--size 1360x860] [--change 3] [--scale 2] [--bench] \
  [--image-mode side-by-side|overlay|difference] [--zoom 2] [--syntax|--no-syntax] \
  [--copy left|right] [--caret left:12:4] [--type "text"] [--undo] [--save] A B
```

`--bench` also prints frame render times while scrolling.

See `PLAN.md` for the design and scope.

## License

This project is free software under the GNU General Public License v3.0; see `LICENSE`.
Copyright © 2026 the project authors.

The project name and app icon are not covered by that license; see `TRADEMARKS.md`.

Twofold is completely free and open source: there is no paid version, and there will never be a subscription. A Mac App Store build is being considered as a way to cover the project's small running costs, but nothing is decided. The App Store's sandbox would cost the app features, the git integration above all, so it needs its own plan first (`PLAN.md`, section 11.6). Contributions are welcome under the terms in `CONTRIBUTING.md`.

## Website

The website, https://twofoldapp.org, lives in `docs/`: plain HTML, Tailwind from its CDN, no build step. GitHub Pages serves it from the `main` branch's `/docs` folder; the domain is in `docs/CNAME`.

Besides the main page there are comparison pages (`docs/kaleidoscope-alternative/` and friends), `robots.txt`, `sitemap.xml`, and `llms.txt`, a plain-text summary for AI assistants. Screenshots are real app renders made with `--snapshot ... --scale 2`; `make social-card` regenerates the link preview image. Visitor statistics use Cloudflare Web Analytics (cookieless) once a token is set in `docs/assets/analytics.js`.

## Releasing

Push a version tag and GitHub Actions does the rest (`.github/workflows/release.yml`):

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow runs the tests, builds a universal app stamped with the version, and publishes `Twofold-1.0.0.zip` with its SHA-256 as a GitHub release. You can also start it by hand from the Actions tab.

Builds are ad-hoc signed by default, so macOS asks users to allow the app on first launch; the release notes explain how. To ship a signed and notarized app instead, add the Developer ID secrets listed at the top of the workflow file.
