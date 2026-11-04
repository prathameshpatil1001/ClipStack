//
//  WebsiteStore.swift
//  ClipStack
//
//  The user's saved websites, persisted as JSON in UserDefaults. A short list
//  of bookmarks does not need the snippet library's database or iCloud merge.
//

import Foundation
import Combine

@MainActor
final class WebsiteStore: ObservableObject {

    @Published private(set) var websites: [Website] = []

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "savedWebsites.v1") {
        self.defaults = defaults
        self.key = key
        load()
    }

    // MARK: - Editing

    func add(_ website: Website) {
        websites.append(website)
        save()
    }

    func update(_ website: Website) {
        guard let index = websites.firstIndex(where: { $0.id == website.id }) else { return }
        websites[index] = website
        save()
    }

    func delete(_ website: Website) {
        delete(ids: [website.id])
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        websites.removeAll { ids.contains($0.id) }
        save()
    }

    /// Drag-to-reorder. Same semantics as SwiftUI's `onMove`: `destination` is
    /// an insertion point in the original array.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.compactMap { websites.indices.contains($0) ? websites[$0] : nil }
        guard !moving.isEmpty else { return }

        let removedBeforeDestination = source.filter { $0 < destination }.count
        var reordered = websites
        for index in source.sorted(by: >) where reordered.indices.contains(index) {
            reordered.remove(at: index)
        }
        let insertionIndex = max(0, min(reordered.count, destination - removedBeforeDestination))
        reordered.insert(contentsOf: moving, at: insertionIndex)
        websites = reordered
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: key) else { return }
        do {
            websites = try JSONDecoder().decode([Website].self, from: data)
        } catch {
            // Set the unreadable data aside, so the next save (which writes the
            // empty list) cannot be the end of it.
            print("ClipStack: could not read saved websites: \(error)")
            defaults.set(data, forKey: key + ".unreadable")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(websites) else { return }
        defaults.set(data, forKey: key)
    }
}
