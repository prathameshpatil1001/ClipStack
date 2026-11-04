# ClipStack

A macOS menu bar utility with three features:

1. **Stack Mode** — while it is on, everything you copy appends to an ordered stack instead of
   overwriting the clipboard: <kbd>⌘C</kbd>, and also copies that never press it (Shottr and other
   screenshot-to-text tools, Edit ▸ Copy, right-click ▸ Copy). Paste the whole stack back in one
   go, joined with a separator you choose.
2. **Saved Texts** — a local snippet library with a Spotlight-style recall panel on
   <kbd>⌥Space</kbd>, live fuzzy search, and optional iCloud sync across your Macs.
3. **Websites** — sites you open all the time, one click from the menu bar or a few keystrokes in
   <kbd>⌥Space</kbd>, each in the browser you pick for it (or the system default) and, for Safari,
   Chrome, Brave, Edge, Vivaldi and Firefox, in a specific **profile**.

No Dock icon, no app switcher entry — it lives in the menu bar (`LSUIElement`). The one exception:
while a ClipStack window (Saved Texts, Websites, Settings) is open, it shows a Dock icon and a
normal menu bar, and goes back to menu-bar-only when you close it.

---

## Requirements

| | |
|---|---|
| macOS | 13.0 Ventura or later |
| Xcode | 16 or later (built and tested with Xcode 26.6) |
| Dependencies | **None** — no Swift packages to resolve |

Global shortcuts use Carbon's `RegisterEventHotKey` rather than a third-party package, so the
project builds straight from a clone with no network access and no SPM step.

## Build and run

```bash
open ClipStack.xcodeproj
```

Select the **ClipStack** scheme and press <kbd>⌘R</kbd>. The app has no window: look for the
stacked-cards icon in the menu bar on the right.

From the command line:

```bash
xcodebuild -project ClipStack.xcodeproj -scheme ClipStack -configuration Release build
```

For everyday use, copy the built `ClipStack.app` to `/Applications` and add it to
**System Settings ▸ General ▸ Login Items** — then grant Accessibility to *that* copy (see below).

## Tests

```bash
./Scripts/test.sh
```

ClipStack's testable logic — fuzzy ranking and iCloud reconciliation — is pure Swift with no AppKit
dependency, so the suite compiles those files directly and runs in about a second. No XCTest host
app, no simulator. CI runs it on every push (`.github/workflows/ci.yml`).

---

## Granting permission

**ClipStack asks on first launch**, with an explanation before macOS shows its
own prompt. You can grant it at any time from the banner in the menu bar
dropdown, or **Settings ▸ Permissions**.

### Grant Accessibility. That's the one.

macOS splits what looks like a single capability across two privacy settings,
and this is the single most common reason a clipboard utility appears to do
nothing at all:

| Permission | What it allows | Needed for |
|---|---|---|
| **Accessibility** | Post keystrokes into other apps, and observe keys via `NSEvent` | ⌘C capture **and** auto-paste |
| **Input Monitoring** | Observe keys via a listen-only `CGEventTap` | ⌘C capture only |

**Either one enables ⌘C capture** — ClipStack runs both mechanisms and uses
whichever the system actually delivers. But only Accessibility also lets it
paste for you, so **Accessibility is the one to turn on**.

1. Open **System Settings ▸ Privacy & Security ▸ Accessibility**
2. Turn on the switch next to **ClipStack**, or press **+** and pick the app

Settings ▸ Permissions shows both switches and which capture route is live.

> **A note for anyone reading the source:** a `CGEventTap` created with
> `.listenOnly` requires Input Monitoring, *not* Accessibility. Requesting only
> Accessibility — the obvious thing to do, and what most tutorials show —
> produces the nastiest possible failure: the tap is created successfully and
> then silently receives nothing. ClipStack handles both, deliberately.

### What still works without any permission

| Feature | Needs permission? |
|---|---|
| ⌥Space recall panel, saved texts, fuzzy search, iCloud sync | No |
| ⌥⌘V / ⌥⌘X / ⌥⌘S and any global shortcut | No — Carbon hotkeys are exempt |
| Paste Stack loading the clipboard | No |
| Capturing ⌘C into the stack | **Yes** — Accessibility or Input Monitoring |
| Auto-pasting (Paste Stack, and ↩ in the recall panel) | **Yes** — Accessibility |
| Websites in the default browser, or in a Chrome/Brave/Edge/Firefox profile | No |
| Websites in a **Safari** profile | **Yes** — Accessibility, plus Automation for Safari (macOS asks once) |

If permission is missing, Stack Mode refuses to switch on and says why;
everything else carries on. Grant it later and ClipStack arms itself within
about two seconds — no restart needed.

### The switch is ON but ClipStack still says "Not granted"

This is the most confusing failure macOS offers, and it is not something the app
can fix from the inside.

Privacy approval is recorded per *app identity*, and every copy of ClipStack you
have ever built shares the bundle identifier `com.prathamesh.ClipStack`. If you
have run the app from more than one place — a Debug build, a Release build, a
copy in `/Applications` — macOS may be holding a record for a copy that no
longer exists. The list shows a ClipStack with its switch on, while the app you
are actually running has no approval at all. Toggling that row does nothing,
because it does not refer to the running binary.

Clear the old records and start clean:

```bash
tccutil reset All com.prathamesh.ClipStack
```

Then quit and reopen ClipStack, open **Settings ▸ Permissions**, and press
**Request…** next to Accessibility. Approve the prompt macOS shows.

Press **Request…** rather than hunting for the row by hand: it makes macOS
register ClipStack under the identity of the binary that is actually running,
which is the whole problem this failure is about. (Settings ▸ Permissions also
has a **Permission stuck?** button that hands you the command.)

Then install to one stable location so it never happens again:

```bash
./Scripts/install.sh
```

### If it stops working after a rebuild

This is the second most common problem, and it is not a bug in the app.

macOS ties privacy approval to an app's code signature **and its path**.
Rebuilding into a fresh DerivedData folder, or moving the app to
`/Applications`, makes macOS treat it as a *different app* — the old entry stays
in the list with its switch on, while the copy you are actually running has
nothing.

1. **System Settings ▸ Privacy & Security ▸ Accessibility**
2. Select **ClipStack**, press **–** to remove it
3. Press **+**, add the copy you are running, and switch it on

Pick one location and stay there. Copying the built app to `/Applications` and
granting permission to *that* copy is much less painful than re-approving a
DerivedData build after every rebuild.

## Shortcuts

Every shortcut is remappable in **Settings ▸ Shortcuts** and stored in `UserDefaults`.

| Default | Action |
|---|---|
| <kbd>⌘C</kbd> | Append the copied text to the stack (only while Stack Mode is on; **not** remappable) |
| <kbd>⌥⌘V</kbd> | **Paste Stack** — join every item, put it on the clipboard, optionally auto-paste |
| <kbd>⌥⌘X</kbd> | **Reset Stack** — empty the stack |
| <kbd>⌥⌘S</kbd> | **Toggle Stack Mode** — turn stacking on or off from anywhere |
| <kbd>⌥Space</kbd> | **Recall** — open the saved-text search panel |

The panel opens as a bare search field — it never puts your saved texts on screen until you type —
and grows downwards into results from a fixed top edge, the way Spotlight does.

In the recall panel: <kbd>↑</kbd>/<kbd>↓</kbd> (or <kbd>⌃P</kbd>/<kbd>⌃N</kbd>) move the highlight
and wrap around, <kbd>↩</kbd> pastes the snippet into the app you came from (or just copies it, if
you turn auto-paste off), <kbd>esc</kbd> closes with no action.

`⌘C` is deliberately not remappable: ClipStack observes the system-wide copy keystroke without
changing what it does, rather than binding a hotkey of its own.

Clearing the Toggle Stack Mode shortcut sticks — it will not reappear on the next launch.

## Settings

**Stack**

- **Join items with** — new line (default), blank line, space, comma, or a custom string
- **Paste automatically** — press <kbd>⌘V</kbd> for you, or just load the clipboard (on by default)
- **Empty the stack after pasting** — off by default
- **Also add copies made without ⌘C** — Shottr, Edit ▸ Copy, right-click ▸ Copy (**on** by default).
  ClipStack watches the clipboard while Stack Mode is on; items a password manager marks as
  private (`org.nspasteboard.ConcealedType`) are skipped
- **Auto-clear** — drop the stack after 1/5/15/60 minutes of inactivity (**off** by default)
- **Paste straight into the app on ↩** — recall-panel auto-paste (**on** by default)
- **Sync saved texts across my Macs** — iCloud (**off** by default, see below)

**Saved Texts**

- Local storage backend and snippet count
- iCloud sync toggle and live status

**Shortcuts** — rebind anything; conflicts with macOS or another app are reported inline.

## Websites

Menu bar ▸ **Add Websites…** (later **Manage Websites…**). Each website has a name, an address
(`github.com` is fine — `https://` is added) and where it opens. Open one from the menu bar, or
type in the <kbd>⌥Space</kbd> panel: websites are ranked alongside saved texts (by name, host,
address, or the profile they open in — typing `work` finds every site that opens in Work), and
<kbd>↩</kbd> opens the highlighted one.

| Open in | How ClipStack opens it |
|---|---|
| Default browser | Whatever the system default is *at the time*, so changing it later is followed |
| A browser, no profile | That browser, in its usual window |
| Chrome, Brave, Edge, Vivaldi, Chromium profile | `--profile-directory=…` — profiles are read from the browser's `Local State` |
| Firefox profile | `-P <name>` — profiles are read from `profiles.ini` |
| Safari profile | File ▸ **New *Profile* Window**, then the new window is pointed at the address |

Safari (17+) has no command-line flag or URL scheme for profiles, so ClipStack does what you would
do by hand: it presses Safari's own **New *Work* Window** menu item through Accessibility, then
loads the address into that window with AppleScript. That needs Accessibility (which ClipStack
already asks for) and, the first time, macOS asks whether ClipStack may control Safari. To pick
the profile, type its name as Safari's File menu shows it, or open Safari and choose it from
**Detected**.

**Permissions** — Accessibility status, with a direct link to System Settings.

---

## Repository layout

```
.
├── ClipStack.xcodeproj
├── ClipStack/                   the app
├── Tests/                       logic checks (see Scripts/test.sh)
├── Scripts/
│   ├── test.sh                  build and run the checks
│   └── generate-app-icon.swift  redraws the app icon into Assets.xcassets
├── .github/workflows/ci.yml     build + test on every push
├── CHANGELOG.md
├── CONTRIBUTING.md
└── LICENSE                      MIT
```

## Project structure

```
ClipStack/
├── ClipStackApp.swift            @main — declares the (window-less) scene
├── AppDelegate.swift             composition root: wires hotkeys, owns the windows
├── AppEnvironment.swift          the object graph handed to every view
├── Info.plist                    LSUIElement + permission usage descriptions
├── ClipStack.entitlements        iCloud KVS — see "Enabling the capability"
├── Models/
│   ├── Snippet.swift             the value type the whole app works with
│   ├── Website.swift             a saved website and the browser/profile it opens in
│   ├── BrowserProfiles.swift     which browsers have profiles, and parsing their lists
│   ├── KeyCombo.swift            codable key + modifiers, Carbon translation
│   └── Preferences.swift         every setting, backed by UserDefaults
├── Core/
│   ├── SystemPermissions.swift          both privacy permissions, explainer, re-arming
│   ├── ClipboardManager.swift           the only place that touches NSPasteboard
│   ├── StackModeController.swift        ⌘C capture (both routes) and the stack itself
│   ├── PasteSimulator.swift             synthetic ⌘V
│   ├── HotKeyManager.swift              global shortcuts via RegisterEventHotKey
│   ├── FuzzySearchEngine.swift          ranking for the recall panel
│   ├── SnippetStore.swift               observable source of truth for snippets
│   ├── SnippetPersistence.swift         storage protocol + JSON backend
│   ├── SwiftDataSnippetPersistence.swift  SwiftData backend (macOS 14+)
│   ├── LegacyDefaultStoreReader.swift   read-only import from the old shared store
│   ├── CloudSyncCoordinator.swift       iCloud key-value sync
│   ├── SnippetSyncMerge.swift           pure reconciliation rules
│   ├── WebsiteStore.swift               saved websites, in UserDefaults
│   └── BrowserLauncher.swift            browser discovery, and opening in a profile
└── UI/
    ├── StatusItemController.swift  menu bar icon, runtime-drawn numeric badge
    ├── MenuBarView.swift           the dropdown
    ├── StackModeView.swift         stack list: remove, drag to reorder
    ├── SpotlightSearchPanel.swift  the ⌥Space panel and its view model
    ├── GlassSurface.swift          Liquid Glass surface, with a pre-26 fallback
    ├── SavedTextsWindow.swift      management window + shared window controller
    ├── SnippetEditorView.swift     add/edit form
    ├── WebsitesWindow.swift        website list and editor (browser + profile pickers)
    ├── SettingsView.swift          settings panes
    ├── ShortcutRecorderView.swift  click-to-record shortcut control
    └── HUDController.swift         the transient confirmation under the icon
```

The rule that keeps this navigable: **`Core/` never imports SwiftUI, and `UI/` never talks to the
system directly.**

## Design notes

**The ⌘C tap cannot break copying.** The event tap is created with
`CGEventTapOptions.listenOnly`, which hands the callback a *copy* of each event and ignores its
return value. ClipStack physically cannot swallow, alter or delay a <kbd>⌘C</kbd> — copying keeps
working normally even if this code hangs or crashes. Detection is event-driven; the only waiting is a
short, bounded settle-loop *after* a real <kbd>⌘C</kbd>, because apps write the pasteboard a few
milliseconds after handling the keystroke.

**⌘C is captured two ways on purpose.** A listen-only tap needs Input Monitoring; a global `NSEvent`
monitor needs Accessibility. Which one a given macOS version and privacy configuration actually
delivers is not something an app can reliably predict, and the failure is silent — the tap is created
and simply receives nothing. ClipStack runs both when permitted and discards the duplicate by
pasteboard change-count, so granting either permission works and granting Accessibility alone covers
the whole app. The global monitor is passive too, so the "cannot break copying" property above holds
on both routes.

**The pasteboard counter is sampled synchronously with the keystroke.** A copy is not instantaneous:
the frontmost app writes the pasteboard some milliseconds after handling ⌘C. Sampling the baseline
*after* hopping to the main actor is a race — the app may already have written, so the counter has
moved, the copy looks like "nothing changed", and the item is silently dropped. Both capture routes
read `changeCount` before handing off.

**Hotkeys do not use the event tap.** `RegisterEventHotKey` is the OS's own hotkey registry: it needs
no Accessibility permission and it reports a conflict when a shortcut is already taken, which is what
Settings shows you when a binding is refused.

**iCloud sync merges, it does not overwrite.** Saved texts sync as one JSON payload in
`NSUbiquitousKeyValueStore`. Reconciliation (`SnippetSyncMerge`) is deliberately commutative and
idempotent, so both Macs reach the same answer with no designated leader; per-snippet `updatedAt`
resolves conflicting edits and tombstones carry deletions across. Content comparison is done on the
*encoded* bytes, because a `Date` holds more precision in memory than ISO-8601 preserves — comparing
values directly would make a payload differ from its own round-trip through iCloud, and the two Macs
would rewrite each other forever. `Tests/SyncMergeChecks.swift` guards all of this.

**Storage: SwiftData above macOS 13.** SwiftData is macOS 14+, so it cannot be the only storage path
for a macOS 13 target. Snippets live behind a `SnippetPersistence` protocol — SwiftData on macOS 14
and later, an atomically-written JSON file on macOS 13. Both hand back plain `Snippet` values, so the
store and every view are identical on both systems, and `SwiftData.framework` is weak-linked
(`OTHER_LDFLAGS = -weak_framework SwiftData`) so the app still launches on 13. iCloud sync sits above
both, so it works the same either way.

Both backends write to `~/Library/Application Support/ClipStack/` (`Snippets.store` or
`snippets.json`), and the SwiftData store is always given that explicit URL. Because the app is not
sandboxed, a bare `ModelContainer(for:)` would resolve to `Application Support/default.store` — a path
shared with every other unsandboxed process that does the same, including system agents such as
`icloudmailagent`. Each side migrating that file to its own schema is what used to erase saved texts.
On first launch ClipStack imports anything left there, reading it with SQLite strictly read-only and
never modifying or deleting it. If the library cannot be loaded, the store goes read-only rather than
saving an empty list over what is on disk.

**The App Sandbox is off** (`ENABLE_APP_SANDBOX = NO`). A global event tap, Accessibility trust and
synthesizing keystrokes into other apps are all incompatible with the sandbox. This is normal for a
clipboard utility, and it means the app cannot be distributed on the Mac App Store — Developer ID
signing and notarization are the distribution route.

**Dark and Light Mode** are handled by the system. Panels are built from semantic colors and one
shared surface (`GlassSurface.swift`): Liquid Glass (`.glassEffect`) on macOS 26 and later, and
`.regularMaterial` on everything older, since the deployment target is still macOS 13. The menu bar
icon is a *template* image: the item count is knocked out of the badge rather than painted white, so
macOS tints the whole icon correctly in either appearance.

**The app icon is drawn from source** (`Scripts/generate-app-icon.swift`) rather than checked in as
opaque binaries. The glyph is hand-drawn because SF Symbols are licensed for use in an app's
interface, not in its icon.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Stack Mode won't switch on | Neither permission granted, or a stale entry after a rebuild — see above |
| Stack Mode is on but nothing is stacked | Almost always permission: open Settings ▸ Permissions and check "Currently using". If it says "Not capturing", grant Accessibility |
| Switch is on, app still says "Not granted" | A stale record from an older copy — run `tccutil reset All com.prathamesh.ClipStack`, then press Request… (see above) |
| <kbd>⌘C</kbd> adds nothing | You copied something that isn't text (an image or a file), or the selection was empty |
| Nothing captured in one specific app | That app has Secure Input enabled (password fields do this); macOS blocks all keystroke observation while it is active |
| Auto-paste puts nothing in the app | The target app ignores synthetic events; the text is still on the clipboard, so press <kbd>⌘V</kbd> |
| A shortcut won't record | Something else owns it — Settings shows the conflict under the row |
| iCloud sync says "not available" | The iCloud capability isn't enabled for the target — see above |
| iCloud sync says "not signed in" | This Mac has no iCloud account in System Settings |
| No icon in the menu bar | The menu bar is full; quit another menu bar app or use a menu bar manager |

## License

MIT — see [LICENSE](LICENSE).
