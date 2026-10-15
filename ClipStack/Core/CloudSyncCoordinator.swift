//
//  CloudSyncCoordinator.swift
//  ClipStack
//
//  iCloud sync for saved texts, over NSUbiquitousKeyValueStore.
//
//  ── Why key-value storage and not CloudKit/SwiftData ────────────────────────
//  A snippet library is small text. KVS gives sync with no schema, no container
//  setup and no server round-trips, and — importantly here — it works
//  identically on macOS 13 (where the local store is a JSON file) and macOS 14+
//  (SwiftData). One sync path covers both backends.
//
//  Its limits are real and handled explicitly below: 1 MB total, 1 MB per key,
//  1024 keys. ClipStack stores the whole library under a single key and refuses
//  to push once the payload approaches the ceiling, rather than letting iCloud
//  silently drop the write.
//
//  ── Requires the iCloud capability ──────────────────────────────────────────
//  KVS needs the `com.apple.developer.ubiquity-kvstore-identifier` entitlement,
//  which in turn needs an iCloud-enabled App ID and provisioning profile. The
//  entitlements file is in the project but is NOT wired up by default, because
//  doing so requires registering the App ID with an Apple Developer account —
//  see the README. Without it, `NSUbiquitousKeyValueStore` silently does
//  nothing; `status` detects that and says so instead of pretending to sync.
//

import Foundation
import Combine

@MainActor
final class CloudSyncCoordinator: ObservableObject {

    enum Status: Equatable {
        case disabled
        case notSignedIn
        case unavailable(String)
        case syncing
        case synced(Date)
        case payloadTooLarge(bytes: Int)
        case failed(String)

        var isHealthy: Bool {
            switch self {
            case .synced, .syncing: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .disabled

    /// Called with a payload that arrived from another Mac. The store merges it.
    var onRemotePayload: ((SnippetSyncPayload) -> Void)?

    /// Single key holding the whole library.
    private let storageKey = "com.prathamesh.ClipStack.snippets.v1"

    /// KVS caps a single value at 1 MB. We stop well short so a near-limit
    /// library still has room for one more edit before it breaks.
    private let maximumPayloadBytes = 900_000

    private let store: NSUbiquitousKeyValueStore
    private var observer: NSObjectProtocol?
    private var isEnabled = false

    /// The last payload we wrote or received, so an echo of our own write is not
    /// mistaken for a change from another Mac.
    private var lastKnownPayload: SnippetSyncPayload?

    /// Set once iCloud holds a library this build refused to read (unreadable, or
    /// from a newer ClipStack). Pushing after that would replace the other Mac's
    /// library with this one, so writes stay off until sync is restarted.
    private var remoteWritesBlocked = false

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    /// Turns syncing on and pulls whatever iCloud already has.
    func start() {
        guard !isEnabled else { return }
        isEnabled = true

        // No iCloud account means nothing to sync to. This is a user-facing
        // state, not an error.
        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = .notSignedIn
            return
        }

        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            // Delivered on the main queue as requested, but the closure is
            // nonisolated as far as the compiler is concerned. Pull out the two
            // plain values we need here, so no non-Sendable userInfo dictionary
            // has to cross into the Task.
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            guard let self else { return }
            Task { @MainActor in
                self.handleExternalChange(reason: reason, changedKeys: changedKeys)
            }
        }

        status = .syncing

        // Kick iCloud to fetch; the change notification follows if there is
        // anything new. `synchronize()` returning false means the entitlement is
        // missing — the single most likely misconfiguration.
        if store.synchronize() {
            deliverRemotePayloadIfPresent()
        } else {
            status = .unavailable("iCloud key-value storage is not available. Enable the iCloud capability for this target — see the README.")
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        isEnabled = false
        lastKnownPayload = nil
        remoteWritesBlocked = false
        status = .disabled
    }

    // MARK: - Push

    /// Writes the library to iCloud. Silently does nothing when sync is off.
    func push(_ payload: SnippetSyncPayload) {
        guard isEnabled, !remoteWritesBlocked else { return }
        // Already known to be unavailable (missing entitlement, no account):
        // do not retry on every single edit.
        if case .unavailable = status { return }
        if case .notSignedIn = status { return }
        performPush(payload)
    }

    private func performPush(_ payload: SnippetSyncPayload) {
        // Nothing changed since the last write or read — skip, so two Macs do not
        // keep answering each other.
        if let lastKnownPayload, lastKnownPayload.hasSameContent(as: payload) { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(payload) else {
            status = .failed("Could not encode saved texts for iCloud.")
            return
        }

        guard data.count <= maximumPayloadBytes else {
            // Better to stop and say so than to let iCloud reject the write and
            // leave the user believing their Macs are in sync.
            status = .payloadTooLarge(bytes: data.count)
            return
        }

        store.set(data, forKey: storageKey)
        store.synchronize()
        lastKnownPayload = payload
        status = .synced(Date())
    }

    // MARK: - Pull

    /// Hands iCloud's current library to the store again, even if it was already
    /// delivered — for when the store had to set the first delivery aside.
    func redeliverRemotePayload() {
        guard isEnabled, status.isHealthy else { return }
        lastKnownPayload = nil
        deliverRemotePayloadIfPresent()
    }

    private func handleExternalChange(reason: Int?, changedKeys: [String]?) {
        // Quota exceeded: iCloud has stopped accepting writes for this app.
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            status = .failed("iCloud storage quota for ClipStack is full.")
            return
        }

        // For server changes and initial sync, only react if our key moved.
        if let changedKeys, !changedKeys.contains(storageKey) { return }

        deliverRemotePayloadIfPresent()
    }

    private func deliverRemotePayloadIfPresent() {
        guard let data = store.data(forKey: storageKey) else {
            // Nothing in iCloud yet: the first push will seed it.
            status = .synced(Date())
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let payload = try? decoder.decode(SnippetSyncPayload.self, from: data) else {
            remoteWritesBlocked = true
            status = .failed("iCloud holds saved texts in an unreadable format. Not writing to iCloud, so they are not overwritten.")
            return
        }

        // Written by a newer ClipStack than this one: refuse rather than risk
        // dropping fields we do not understand on the next write-back.
        guard payload.formatVersion <= SnippetSyncPayload.currentFormatVersion else {
            remoteWritesBlocked = true
            status = .failed("iCloud data was written by a newer version of ClipStack. Update ClipStack to keep syncing.")
            return
        }

        // Readable again (another Mac rewrote it, or ClipStack was updated).
        remoteWritesBlocked = false

        // Our own write echoing back.
        if let lastKnownPayload, lastKnownPayload.hasSameContent(as: payload) {
            status = .synced(Date())
            return
        }

        lastKnownPayload = payload
        status = .synced(Date())
        onRemotePayload?(payload)
    }

    // MARK: - Description

    var statusDescription: String {
        switch status {
        case .disabled:
            return "Off"
        case .notSignedIn:
            return "Not signed in to iCloud on this Mac"
        case .unavailable(let reason):
            return reason
        case .syncing:
            return "Syncing…"
        case .synced(let date):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "Last synced at \(formatter.string(from: date))"
        case .payloadTooLarge(let bytes):
            let megabytes = Double(bytes) / 1_000_000
            return String(format: "Too large for iCloud key-value storage (%.2f MB of 1 MB). Newer changes are staying on this Mac.", megabytes)
        case .failed(let message):
            return message
        }
    }
}
