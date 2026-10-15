#!/bin/bash
#
# Runs ClipStack's logic tests.
#
# The testable parts of ClipStack — fuzzy ranking and iCloud merge — are pure
# Swift with no AppKit dependency, so they compile and run directly. No XCTest
# host app, no simulator, nothing to configure: useful in CI and fast enough to
# run on every save.
#
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Building ClipStack checks…"
xcrun swiftc -O \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -target "arm64-apple-macos13.0" \
    -swift-version 5 \
    -o "$BUILD_DIR/clipstack-checks" \
    ClipStack/Models/Snippet.swift \
    ClipStack/Core/FuzzySearchEngine.swift \
    ClipStack/Core/SnippetSyncMerge.swift \
    ClipStack/Core/ClipboardManager.swift \
    ClipStack/Core/SnippetPersistence.swift \
    ClipStack/Core/LegacyDefaultStoreReader.swift \
    ClipStack/Core/CloudSyncCoordinator.swift \
    ClipStack/Core/SnippetStore.swift \
    Tests/CheckRunner.swift \
    Tests/FuzzySearchChecks.swift \
    Tests/SyncMergeChecks.swift \
    Tests/ClipboardChecks.swift \
    Tests/SnippetStoreChecks.swift \
    Tests/main.swift

"$BUILD_DIR/clipstack-checks"
