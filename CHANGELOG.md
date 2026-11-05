# Changelog

All notable changes to ClipStack are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **macOS 26 document recognition for screen capture.** On macOS 26, captures
  are read with Vision's `RecognizeDocumentsRequest`: tables come back cell by
  cell (spanning cells once, never repeated) and go into the layout where they
  sit; list items' markers are applied to their first lines, nested lists
  included; titles become headings. Columns, nesting and paragraphs still go
  through the layout rules. Falls back to line recognition elsewhere or when
  nothing is found; Settings ▸ Capture ▸ "Use document recognition".
- **Format Stack (⌃⌥⌘V).** Paste the whole stack as one structured document:
  captures keep their layout, copied text is read by its own structure
  (markers, indentation, Markdown headings and tables, tab-separated rows;
  code kept verbatim), bullets copied one by one become one list and matching
  rows one table. Pasted (or copied) with HTML and RTF alongside the text. In
  Smart mode, copied text that lost its structure is labelled by the on-device
  model, accepted only if it covers every line once, in order, and then
  previewed first.
- **Captured stack items keep both versions**: right-click to switch between
  the formatted text and the text as read.
- **Screen text capture (⌥⌘T).** Drag over anything on screen and its text
  goes into the stack (or onto the clipboard, with real bullets and tables for
  Notes, Pages and Docs), with its layout rebuilt: bullets, including ones
  recognition misses (found in the pixels), nested lists, numbered questions
  with their options, joined paragraphs, headings, tables, and columns in the
  right order. Text side by side (an MCQ answer column) is read across;
  newspaper columns are read down. Smart mode lets Apple's on-device model
  settle the reading order of such captures, by line numbers only, accepted
  only if every line is used exactly once. Complex captures are previewed
  first, with the text as read one click away; ⌥ on release gives raw text.
  Needs macOS 14 and Screen Recording.
- **AI edit mode in ⌥Space (⌘↩).** Edit text pasted or typed into the field,
  a saved text found by a short search, or (with the field empty) the
  clipboard, one instruction at a time: "fill in my details", "add my PRN at the
  end". Each step is applied as exact edits, never a rewrite. Anything that
  doesn't match the text exactly is refused, everything else is copied through
  unchanged, and the card highlights what changed. Every result goes straight
  onto the clipboard; ⌘Z steps back, ⌘↩ pastes into the previous app. Uses
  Apple's on-device model (macOS 26, Apple Intelligence), so nothing leaves
  the Mac.
- **Quick fill (⌥↩)** fills placeholders such as `[Your Name]`, `<USER>`,
  `<YOUR_IP>` or `path/to/destination` that plainly name one profile detail,
  with no AI.
- **Profile.** Details about you, in groups, used by edit mode and Quick fill.
  Add them by hand, as JSON (editor, import, export), or by describing them in
  your own words. The on-device model sorts what you wrote into details, keeps
  only values copied from it, and you approve each one. Secrets (PRN, tokens)
  are kept in the Keychain. The model is shown only the details' names, never
  their values, and ClipStack substitutes the values itself. A detail the
  profile lacks becomes a ⟦gap⟧ to fill, never a guess.
- **Websites.** Save the sites you open all the time and open them from the menu
  bar, each in the browser you choose (or whatever the system default is) and,
  optionally, in a specific browser **profile**: Safari 17+ profiles, Chrome,
  Brave, Edge, Vivaldi and Chromium profiles, and Firefox profiles. Profiles are
  detected from each browser; Safari's are read from its File menu and opened
  through it (needs Accessibility, and macOS asks once to let ClipStack control
  Safari). Manage them in the new Websites window: add, edit, reorder, delete.
  They also show up in the ⌥Space panel, ranked alongside saved texts, where ↩
  opens the highlighted one.
- **⌘1…⌘9 in the ⌥Space panel** open the row with that number.
- **Stack Mode captures copies that never press ⌘C** — Shottr and other
  screenshot-to-text tools, Edit ▸ Copy, right-click ▸ Copy, "Copy" buttons. A
  clipboard watcher runs while Stack Mode is on. On by default; Settings ▸ Stack
  ▸ "Also add copies made without ⌘C". Items a password manager marks as
  concealed or transient are skipped by the watcher.
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

### Changed
- **The ⌥Space panel looks like macOS Spotlight:** a glass search capsule, and
  the results in a separate rounded card beneath it, with a soft selection
  highlight and ⌘-number hints on each row.
- **The ⌥Space recall panel opens as a bare search field.** It used to list the
  whole library the moment it appeared — every saved text on screen over
  whatever the user was doing, unasked. Results now appear only once something
  is typed, and the panel grows downwards from a fixed top edge as they arrive,
  the way Spotlight does.
- **Liquid Glass.** The recall panel and the HUD are built from
  `.glassEffect` on macOS 26 and later, falling back to `.regularMaterial`
  below it, with Spotlight-like open, resize and selection animations.

### Fixed
- **Exam-style captures came out scrambled.** With question numbers ("10")
  and option letters ("A"–"D") printed in columns of their own, the letters
  were read as separate lines or dropped, and some options ran together.
  Recognition reads such a marker as a separate piece of its row; the layout
  now joins it to the text beside it (exactly as written) and treats it as
  that line's marker, so each question is followed by its options, one per
  line, indented under it. Options written "A text" with no "." or ")" are
  recognised when they come in sequence (A, B, C…), and the small gap between
  a question and its options no longer becomes a blank line. On macOS 26 the
  lines now always come from line recognition — document recognition's
  "lines" can merge several options into one — with document recognition
  adding tables, list markers and titles on top.
- **The ⌥Space panel jumped up and down as results changed,** and flashed a
  rectangular outline. The window was resized for every result count, and its
  hosting view resized it too, from the bottom edge, a frame before the
  top-anchored resize corrected it; the window shadow, recomputed mid-resize,
  drew the outline. The window is now a fixed transparent canvas with no
  shadow of its own, and only the results card animates inside it.
- **A Safari profile website opened as a second tab beside an empty one,**
  always in a new window. The Apple Events entitlement was in an entitlements
  file the target never referenced, so the hardened runtime refused the script
  silently and the fallback added a tab. The app is now signed with
  `HardenedRuntime.entitlements`, and an already-open window of the profile is
  reused: the address opens in a new tab there.
- **Text copied with Shottr didn't reach the stack until the next ⌘C,** and then
  only the latest of several. Capture was keystroke-driven, so a copy without
  ⌘C was never seen; it sat newer than the capture watermark until a later ⌘C
  swept it up alongside its own copy. The new clipboard watcher takes each one
  as it happens. ClipStack's own clipboard writes (pasting the stack, recalling a
  saved text) are recognised and never fed back into the stack.
- **The menu bar disappeared when the Saved Texts window (or its New / Edit
  sheet) was open,** as if a full-screen app were in front, until the pointer was
  pushed to the top of the screen. An accessory (menu-bar-only) app has no menu
  bar for macOS to show while it is frontmost. ClipStack now becomes a regular
  app while one of its windows is open, and goes back to menu-bar-only when the
  last one closes, handing focus back to the app you came from.
- **↑/↓ sometimes stopped moving the selection in the ⌥Space panel** until the
  mouse was moved. Rows select on hover, and SwiftUI reports a hover whenever a
  row slides under a resting pointer — the panel growing, the list scrolling, a
  re-render — which snapped the highlight back to the row under the mouse after
  every key press. Hover now only selects once the pointer has actually moved.
- **Saved texts could vanish, typically after a restart.** The SwiftData store
  was opened without a location, which for an unsandboxed app is the shared
  `~/Library/Application Support/default.store`. Other processes use that file
  too (`icloudmailagent` among them), and each one migrated it to its own
  schema, dropping ClipStack's table. Saves then failed with a file error until
  the next launch, which found the library empty. The store now lives at
  `Application Support/ClipStack/Snippets.store`; snippets still in the old file
  are imported once, read-only, leaving that file untouched.
- **A library that failed to load could be wiped by the next edit.** Load
  failure left an empty list in memory, and saving writes that list over the
  store. The store now goes read-only with a Retry button until a load succeeds,
  and ignores iCloud deliveries meanwhile.
- **A SwiftData store that failed to open silently switched to a JSON file,**
  showing an empty library and saving to a file later launches did not read. It
  now reports the error instead.
- **iCloud sync kept writing after refusing remote data** it could not read or
  that came from a newer ClipStack, overwriting the other Mac's library. Writes
  now pause until the data is readable again.
- **Editing a saved text could undo changes made while the editor was open** —
  a recall count, a pin, or an iCloud update. Only the edited fields are applied.
- **The Delete key removed rows hidden by the filter** if they had been selected
  before filtering. Only visible rows are deleted.
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
