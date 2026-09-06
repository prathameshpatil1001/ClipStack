# Changelog

All notable changes to ClipStack are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Auto-paste from the recall panel.** ↩ on a highlighted snippet now pastes it
  straight into the app you were working in, rather than only loading the
  clipboard. On by default; turn it off in Settings ▸ Saved Texts. Falls back to
  copying when Accessibility is unavailable.
- **iCloud sync for saved texts.** Snippets follow you between Macs signed in to
  the same Apple Account, over `NSUbiquitousKeyValueStore`. Edits merge per
  snippet (most recent change to a given snippet wins) and deletions carry
  across via tombstones. Off by default; enable in Settings ▸ Saved Texts.
  Requires the iCloud capability — see the README.
- **⌥⌘S toggles Stack Mode** from anywhere. Remappable, and clearable without it
  reappearing on the next launch.
- App icon, drawn from source by `Scripts/generate-app-icon.swift`.
- Logic test suite (`Scripts/test.sh`, 33 checks) covering fuzzy ranking, iCloud
  merge and clipboard capture.
- Shared Xcode scheme, so a fresh clone builds from the command line.
- GitHub Actions CI: runs the tests and builds Debug and Release.
- `LICENSE` (MIT), `CONTRIBUTING.md` and `.gitignore`.
- `Snippet.updatedAt`, to resolve sync conflicts. Snippet files written before
  this field existed still load.

nano ~/.ssh/config
- **⌘C was silently dropped whenever the global monitor was the capture route.**
  Regression introduced with the dual-route capture. The change-count baseline
  was sampled when the keystroke was seen, which is only correct for the event
  tap — that fires *before* the frontmost app copies. A global `NSEvent` monitor
  is delivered *after* the event was dispatched, so the copy has usually already
  landed and the baseline equalled the post-copy value; waiting for a further
  change then timed out and discarded the copy. Capture is now expressed against
  a consumption watermark ("newer than what I have already taken") instead of a
  keystroke-time baseline, which is correct in both orderings and de-duplicates
  the two routes without a separate mechanism. `Tests/ClipboardChecks.swift`
  covers both orderings explicitly.
- **The permission prompt could never appear for Input Monitoring.** Nothing in
  the UI called the request APIs — only the "Open System Settings" deep links —
  so `requestInputMonitoring()` was dead code and the system prompt was never
  triggered. Settings ▸ Permissions now has a **Request…** button per permission,
  which registers ClipStack under the identity of the binary actually running
  rather than relying on the user finding the right row by hand. The first-launch
  explainer requests both.
- **Guidance for a stale privacy record.** Every build of ClipStack shares one
  bundle identifier, so macOS can hold an approval for a copy that no longer
  exists — the switch reads as on while the running app has nothing, and toggling
  it does nothing. Settings ▸ Permissions has a **Permission stuck?** button that
  explains this and hands over the `tccutil reset` command, and
  `Scripts/install.sh` installs to a stable location so it stops recurring.
- **⌘C is captured again — the app was asking for the wrong permission.** A
  listen-only `CGEventTap` requires **Input Monitoring**, not Accessibility, and
  ClipStack only ever requested Accessibility. The failure mode was the worst
  kind: the tap was created successfully and then silently received no key
  events, so Stack Mode looked switched on while nothing was ever stacked.
  ClipStack now tracks both permissions, and captures ⌘C through the event tap
  *and* a global `NSEvent` monitor (which runs off Accessibility), de-duplicated
  by pasteboard change-count. Granting Accessibility alone is now enough for the
  whole app to work.
- **A copy could be dropped through a race.** The pasteboard change-count was
  sampled after hopping to the main actor, by which point the frontmost app may
  already have written the clipboard — the counter had moved, the copy looked
  like "nothing changed", and the item was silently discarded. The baseline is
  now sampled synchronously with the keystroke.
- **The menu bar list no longer goes stale.** Items added with ⌘C appeared in the
  icon's badge but not in the dropdown until Stack Mode was switched off and on
  again. `AppEnvironment` only re-published changes from `Preferences`, so
  changes inside the stack controller never invalidated the views that read
  through it. All nested observables are now forwarded, which also fixes the
  Accessibility banner and the saved-text count not updating live.

## [1.0.0]

### Added
- Stack Mode: every ⌘C appends to an ordered stack; ⌥⌘V joins and pastes it,
  ⌥⌘X clears it. Items are individually removable and drag-reorderable, with a
  live count badge on the menu bar icon.
- Saved Texts: a local snippet library with a Spotlight-style ⌥Space recall
  panel and live fuzzy search ranked by match quality, usage and recency.
- Configurable separator, auto-paste, and an optional auto-clear timeout.
- Remappable global shortcuts, stored in `UserDefaults`.
- Accessibility permission flow with an explanatory first-launch alert, live
  re-arming when the permission is granted, and graceful degradation without it.
