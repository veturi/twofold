# VisDiff

A native, fast, good-looking visual diff tool for macOS. Free and open source, no subscription.

It compares two text files side by side, or two folders with a sidebar of changed files.

- **Fluid layout.** Change blocks on each side are joined by curves through a centre ribbon, and the two sides scroll so the change at the centre of the window stays aligned. No filler lines.
- **Blocks layout.** Both sides are padded so matching lines sit on the same row.
- Word-level highlights inside modified lines, refined to characters where only part of a word changed.
- Unchanged runs fold into "N Unchanged Lines"; click to expand.
- Soft wrapping, line-end marks in changed lines, an overview strip of every change, and animated next/previous change navigation.
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

This copies `VisDiff.app` to `~/Applications` and the `visdiff` command to `~/.local/bin`. Make sure that directory is on your `PATH`. Then:

```sh
visdiff a.swift b.swift
visdiff --wait a.swift b.swift   # block until the window closes
```

### As git difftool

```sh
git config --global diff.tool visdiff
git config --global difftool.visdiff.cmd 'visdiff --wait "$LOCAL" "$REMOTE"'
git config --global difftool.prompt false
```

Then `git difftool` compares files one by one, and `git difftool -d` compares whole trees in a folder window.

## Keyboard

| Keys | Action |
|---|---|
| ⌘↓ / ⌘↑ | Next / previous change |
| ⌥⌘↓ / ⌥⌘↑ | Next / previous file (folders) |
| ⌘1 / ⌘2 | Blocks / Fluid layout |
| ⌥⌘L | Wrap lines |
| ⌥⌘I | Show invisibles |
| ⌥⌘E | Expand all unchanged lines |
| ⌘+ / ⌘- / ⌘0 | Text size |
| ⇧⌘S | Swap sides |
| ⌘R | Reload |
| ⌘O | New comparison |

You can also drop two files or two folders on the Dock icon or on any window.

## Development

```sh
make test      # unit tests: diff engine, property tests, cross-check against diff(1), folders
make bench     # diff benchmark (100,000 lines, 1% changed)
make release   # universal arm64 + x86_64 bundle
make icon      # regenerate Resources/AppIcon.icns
```

`DiffCore` holds the diff engine and folder comparison with no AppKit dependency. `VisDiff` is the AppKit app. The diff view draws with Core Text into a single custom view and caches typeset rows.

The app can render a window offscreen to a PNG, which is how the UI is checked without a screen:

```sh
build/VisDiff.app/Contents/MacOS/VisDiff --snapshot out.png [--appearance dark] [--layout blocks] [--size 1360x860] [--change 3] [--scale 2] [--bench] A B
```

`--bench` also prints frame render times while scrolling.

See `PLAN.md` for the design and scope.

## License

This project is free software under the GNU General Public License v3.0; see `LICENSE`.
Copyright © 2026 the project authors.

The project name and app icon are not covered by that license; see `TRADEMARKS.md`.

## Website

The marketing site lives in `docs/`: one HTML file, Tailwind from its CDN, no build step. To publish it, open the repository's Settings → Pages, choose "Deploy from a branch", and pick the `main` branch and the `/docs` folder. For a custom domain, set it in the same screen (GitHub adds a `docs/CNAME` file).

Set the repository URL once, in the `REPO` constant at the bottom of `docs/index.html`. Screenshots are real app renders made with `--snapshot ... --scale 2`.
