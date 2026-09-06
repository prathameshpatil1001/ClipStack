#!/bin/bash
#
# Builds ClipStack and installs it to /Applications.
#
# Why bother: macOS ties privacy permissions (Accessibility, Input Monitoring) to
# an app's code signature AND its path. A build living in DerivedData moves
# whenever Xcode regenerates that folder, so every move looks like a brand new
# app and the permission you granted stops applying. Installing to one stable
# location and granting permission to *that* copy is the difference between
# granting once and granting forever.
#
set -euo pipefail

cd "$(dirname "$0")/.."

DESTINATION="/Applications/ClipStack.app"

echo "Building Release…"
xcodebuild \
    -project ClipStack.xcodeproj \
    -scheme ClipStack \
    -configuration Release \
    -destination 'platform=macOS' \
    build

BUILT=$(xcodebuild -project ClipStack.xcodeproj -scheme ClipStack -configuration Release \
    -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/ClipStack.app

if [ ! -d "$BUILT" ]; then
    echo "Could not find the built app at: $BUILT" >&2
    exit 1
fi

echo "Quitting any running copy…"
pkill -f "ClipStack.app/Contents/MacOS/ClipStack" 2>/dev/null || true

echo "Installing to $DESTINATION"
rm -rf "$DESTINATION"
cp -R "$BUILT" "$DESTINATION"

echo "Launching…"
open "$DESTINATION"

cat <<'NOTE'

Installed.

If ClipStack still reports that permission is missing — even with the switch
turned on in System Settings — macOS is holding a stale record for an older copy
of the app. Clear it and start clean:

    tccutil reset All com.prathamesh.ClipStack

Then quit and reopen ClipStack, open Settings > Permissions, and press
"Request..." next to Accessibility. Approve the prompt that appears.

NOTE
