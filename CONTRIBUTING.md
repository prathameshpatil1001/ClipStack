# Contributing to ClipStack

## Getting set up

```bash
git clone <your-fork>
cd ClipStack
open ClipStack.xcodeproj
```

No package resolution, no `pod install`, no code generation. Select the
**ClipStack** scheme and press ⌘R.

Grant Accessibility to the copy you just built — see the README. macOS ties that
approval to the binary's signature *and path*, so switching between Debug and
Release, or moving the app, means re-approving.

## Running the tests

```bash
./Scripts/test.sh
```

ClipStack's testable logic — fuzzy ranking (`FuzzySearchEngine`) and iCloud
reconciliation (`SnippetSyncMerge`) — is pure Swift with no AppKit dependency, so
the suite compiles those files directly and runs in about a second. There is no
XCTest host app to configure.

Add checks to `Tests/FuzzySearchChecks.swift` or `Tests/SyncMergeChecks.swift`.
If you introduce testable logic, keep it free of AppKit and add it to the file
list in `Scripts/test.sh`.

## Architecture

The rule that keeps this codebase navigable: **`Core/` never imports SwiftUI, and
`UI/` never talks to the system directly.**

- `Models/` — value types and settings. No behaviour beyond formatting.
- `Core/` — system integration and logic. AppKit where unavoidable, never SwiftUI.
- `UI/` — SwiftUI views and the AppKit controllers that host them.
- `AppDelegate.swift` — the only place that wires the pieces together.

`Core/StackModeController.swift` implements collection edits by hand rather than
using SwiftUI's `move(fromOffsets:toOffset:)` for exactly this reason.

## Things worth knowing before you change them

**The ⌘C event tap must stay `.listenOnly`.** That flag is the reason ClipStack
cannot swallow, alter or delay a user's copy. Changing it to `.defaultTap` would
put this app's code in the critical path of every keystroke in the system.

**Hotkeys use Carbon deliberately.** `RegisterEventHotKey` needs no Accessibility
permission, so shortcuts keep working when the user declines the prompt. Moving
them onto the event tap would silently couple them to that permission.

**The app cannot be sandboxed.** A global event tap and synthetic keystrokes are
incompatible with the App Sandbox. Don't re-enable `ENABLE_APP_SANDBOX`.

**Sync merging must stay commutative and idempotent.** Both Macs run the same
merge with no designated leader, so any rule that depends on which side is
"local" will make them disagree. `Tests/SyncMergeChecks.swift` guards this,
including the encoded-equality check that prevents an endless write loop.

## Style

Match the surrounding code. Comments explain *why* — particularly around the
permission-sensitive and AppKit-adjacent parts, where the reason for a line is
rarely obvious from the line itself.

Keep the build warning-free: it currently is, in both Debug and Release.
