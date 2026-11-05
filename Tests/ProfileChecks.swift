//
//  ProfileChecks.swift
//  ClipStack tests
//
//  The profile store: secrets stay out of the file, details update rather
//  than duplicate, and JSON round-trips without losing a secret.
//

import Foundation

@MainActor
enum ProfileChecks {

    static func run() -> Int {
        let runner = CheckRunner(suite: "Profile")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipStackProfileChecks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Profile.json")
        let secrets = InMemorySecretStore()

        func fileText() -> String {
            (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }

        let store = ProfileStore(fileURL: fileURL, secrets: secrets)
        store.upsert(group: "Me", label: "Name", value: "Prathamesh", isSecret: false)
        let prn = store.upsert(group: "Me", label: "PRN", value: "2021001", isSecret: true)
        store.upsert(group: "GCloud server", label: "Host", value: "34.131.129.112", isSecret: false)

        runner.check("plain details are saved to the file", fileText().contains("Prathamesh"))
        runner.check("a secret's value never reaches the file", !fileText().contains("2021001"))
        runner.check("…it is in the secret store", store.value(of: prn), equals: "2021001")
        runner.check("groups, Me first", store.groups, equals: ["Me", "GCloud server"])

        store.upsert(group: "me", label: " name ", value: "Prathamesh Patil", isSecret: false)
        runner.check("same group and name updates instead of duplicating", store.facts.count, equals: 3)
        runner.check("…with the new value",
                     store.facts.first { $0.label == "Name" }?.value ?? "", equals: "Prathamesh Patil")

        // Moving a detail out of, and back into, the Keychain keeps its value.
        let plainPRN = store.update(prn, group: "Me", label: "PRN", value: nil, isSecret: false)
        runner.check("un-secreting moves the value into the file", plainPRN.value, equals: "2021001")
        runner.check("…and out of the secret store", secrets.count, equals: 0)
        let secretAgain = store.update(plainPRN, group: "Me", label: "PRN", value: nil, isSecret: true)
        runner.check("re-secreting moves it back", store.value(of: secretAgain), equals: "2021001")
        runner.check("…and out of the file", !fileText().contains("2021001"))

        // JSON: secrets left out unless asked for.
        let json = store.exportJSON(includingSecrets: false)
        runner.check("exported JSON leaves the secret out", !json.contains("2021001"))
        runner.check("exported JSON keeps paths readable", json.contains("34.131.129.112"))
        runner.check("exporting with secrets includes them", store.exportJSON(includingSecrets: true).contains("2021001"))

        // The JSON editor: drop Host, keep the PRN without its value.
        let edited = """
        { "facts": [
            { "group": "Me", "label": "Name", "value": "Prathamesh Patil" },
            { "group": "Me", "label": "PRN", "secret": true },
            { "group": "Me", "label": "Email", "value": "p@example.com" }
        ] }
        """
        do {
            try store.importJSON(edited, replacingAll: true)
            runner.check("JSON editor applies additions and removals",
                         store.facts.map(\.label).sorted(), equals: ["Email", "Name", "PRN"])
            let keptPRN = store.facts.first { $0.label == "PRN" }
            runner.check("a secret without a value keeps its value",
                         keptPRN.map { store.value(of: $0) } ?? "", equals: "2021001")
        } catch {
            runner.check("JSON editor accepts valid JSON", false, "\(error)")
        }

        // A file that lists the PRN without saying it's secret must not move
        // it out of the Keychain.
        do {
            try store.importJSON(#"{ "facts": [ { "group": "Me", "label": "PRN", "value": "2021001" } ] }"#, replacingAll: false)
            runner.check("importing without \"secret\" keeps a secret secret",
                         store.facts.first { $0.label == "PRN" }?.isSecret == true && !fileText().contains("2021001"))
        } catch {
            runner.check("import accepts valid JSON", false, "\(error)")
        }

        var threw = false
        do { try store.importJSON("not json", replacingAll: true) } catch { threw = true }
        runner.check("invalid JSON is refused", threw)
        runner.check("…and changes nothing", store.facts.count, equals: 3)

        // A fresh store reads the same file back.
        let reopened = ProfileStore(fileURL: fileURL, secrets: secrets)
        runner.check("details survive a relaunch", reopened.facts.map(\.label).sorted(), equals: ["Email", "Name", "PRN"])

        if let secret = reopened.facts.first(where: { $0.isSecret }) {
            reopened.delete(ids: [secret.id])
            runner.check("deleting a secret removes it from the secret store", secrets.count, equals: 0)
        } else {
            runner.check("the secret survives a relaunch", false)
        }

        return runner.failures
    }
}
