# Attix

On a MacBook Air M2 with 8 GB, running coding agents, Chrome and a second browser at the
same time, the kernel starts killing processes to reclaim memory (Jetsam). The app that
disappears did not "crash": it was terminated, and nothing on screen says so.

Attix is a small AppKit window that shows where the RAM actually goes, and puts the
matching gesture on every line it shows.

## What it does

- **Lists memory consumers**, grouped by what you recognize on screen (`claude`,
  `claude.exe` and `node` are one line, not three). Each line carries `Show` (bring the app
  forward) and `Quit`.
- **Restarts the Dock** with ⌘R, from the window or from the app menu. If the Dock is not
  running it opens it instead, and it only reports success after checking the Dock came
  back (1.2 s later).
- **Finds stale dev servers**: `node`, `bun`, `deno` and `esbuild` processes whose working
  directory no longer exists on disk (a deleted worktree whose server survived). Each one
  gets a `Stop` button and its resident size.
- **Reads kernel memory pressure** from `kern.memorystatus_vm_pressure_level` (the same
  value Jetsam uses) and shows an alert panel when it reaches warning or critical. Repeats
  only if it gets worse, otherwise at most once every 15 minutes.
- **Reads the latest Jetsam report** in `/Library/Logs/DiagnosticReports`, so you can tell
  that an app was killed. It separates `per-process-limit` (one process hit its own limit,
  the machine was fine) from the machine-wide reasons (`vm-pageshortage`, `highwater`).
- **Installs a Spotlight shortcut** in one click. One entry named "Attix" in Spotlight,
  six gestures inside a menu: Restart Dock, Restart Finder, Restart Menu Bar, Quit Chrome,
  Stop Stale Dev Servers, Open Attix.
- **Optional launch at login** via `SMAppService` (visible in System Settings > General >
  Login Items), and an optional Dock-less mode.

## Install

```sh
./build.sh              # builds /Applications/Attix.app
./build.sh ~/Applications   # or anywhere else
```

Requirements: Command Line Tools (`swiftc`), Python 3, macOS 14 or later
(`LSMinimumSystemVersion` is 14.0). No Xcode, no dependencies, one Swift file.

`build.sh` compiles `attix-lab.swift`, builds the icon, copies `Attix.shortcut` into
the bundle, signs ad hoc and re-registers with LaunchServices. To regenerate the shortcut
file itself: `python3 shortcut.py Attix.shortcut`.

## Known limits

**The app is signed ad hoc, not notarized.** On your own machine the build is fine. Anyone
who receives the `.app` (AirDrop, zip, download) gets blocked by Gatekeeper. Two ways
around it:

```sh
xattr -d com.apple.quarantine /Applications/Attix.app
```

or right-click the app > Open, then confirm in the dialog.

**System notifications are impossible without an Apple Developer certificate.** Measured
on 14/09/2026 on a minimal bundle with a stable identifier, signed ad hoc, launched by
LaunchServices:

```
UNErrorDomain Code=1 "Notifications are not allowed for this application"
```

The refusal happens *before* the authorization prompt, so there is nothing to grant. The
`osascript` fallback does display a real banner, but under the Script Editor icon and with
no click action. That is why the memory alert is a panel the app draws itself: it carries
the app's own icon and responds to a click by construction. If the app is ever properly
signed, that class goes back to ten lines of `UNUserNotificationCenter`.

**App Intents (native Spotlight actions) are out of reach for the same reason.** The
hand-written metadata was structurally identical to that of Apple's own Notes app and was
never indexed; the only third-party apps exposing App Intents on this machine are signed
with a real certificate. This is why the project goes through a `.shortcut` file instead.
That code path was removed in commit `788fffb`.

**The Spotlight shortcut needs "Allow Running Scripts".** Shortcuts > Settings (⌘,) >
Advanced > Allow Running Scripts, unchecked by default. All six gestures are shell
commands. Without that box ticked, the shortcut installs, appears in Spotlight, and fails
at the moment you use it, with a message about "security settings" that names neither the
setting nor where it is. The app states this before installing rather than after.

Note on signing the shortcut file: `shortcuts sign --mode anyone` goes through an Apple
service, and that service is not always up. It returned 500 on 14/09/2026 and worked the
next day. `shortcut.py` tries `anyone` first and falls back to `people-who-know-me`, which
signs locally and is enough for your own use but not for handing the file to someone else.
Check which mode the build reports before distributing it.

## Guardrails

This code sends signals to processes, so the limits are explicit:

- **`INTOUCHABLES`**: `WindowServer`, `loginwindow`, `launchd`, `kernel_task`, `logind`,
  `UserEventAgent` are never listed at all. Stopping them costs the session, not unsaved
  work, and a line on which no gesture is safe does not belong in a list of gestures.
- **`PROTEGES`**: cmux, Claude Code, Node, terminals, VS Code, Xcode, Cursor, Finder keep
  their `Quit` button, but gain a named warning (for example "This ends all running Claude
  Code sessions, including this one.") and a confirmation dialog whose default button is
  Cancel. Chrome is not in the list: it restores its own tabs.
- **`terminate()`, not `kill`**: a running application gets `NSRunningApplication.terminate()`,
  the same thing as its Quit menu item, so it can save and clean up. `SIGTERM` is used only
  for bare pids, and `SIGKILL` never.
- **No automation**: the app never quits anything on its own. There is no action threshold,
  only what you click.
- **A stale server is proven, not guessed**: its working directory (read via
  `lsof -a -d cwd`) no longer exists on disk. No heuristic on process name or port.

## Chrome extension

`chrome-extension/` holds an unpublished MV3 extension that counts open tabs and puts the
idle ones to sleep with `chrome.tabs.discard()`: the tab keeps its title and position and
reloads on click, nothing is closed. Candidates are tabs not active, not audible, not
pinned, not already discarded, and idle for 20 minutes or more. It does not display
per-tab memory: Chrome exposes that to no Web Store extension (`chrome.processes` is
restricted to internal builds), so the number would have to be invented.

## Tests

```sh
./test.sh
```

Exits 0 when every case passes, 1 otherwise.

There is no Xcode and no SwiftPM on this machine, so XCTest is out of reach. `test.sh`
compiles a standalone executable with `swiftc` instead, from `Mesures.swift` plus
`Tests/`, and that executable prints one line per case and its own summary. The tests
live in `Tests/` and not at the root on purpose: `build.sh` compiles `*.swift` from the
root, so a test file left there would ship inside the app. `main.swift` is excluded from
the test binary because it carries the `NSApplication` bootstrap at top level, and a
binary has only one entry point.

What is covered: the splitting of `ps` output (`Sonde.analyse`, extracted from
`lignesPs()` for that purpose), bundle-name extraction (`Sonde.nomApp`), reverse-DNS
names (`Sonde.joli`), Jetsam `.ips` parsing (`Jetsam.victime`, against report files
written to a temporary folder), byte formatting (`go`), and `ALIAS` grouping.

The `ps` cases matter most: an earlier version lost 566 lines out of 575 and showed
Chrome at 205 MB instead of 1273. They pin down leading spaces, wide and narrow RSS
values together, paths containing spaces, blank lines and malformed lines.

## Conventions

Interface in English, code comments in French.

## License

MIT. See `LICENSE`.
