//
//  CheckRunner.swift
//  ClipStack tests
//
//  A deliberately tiny assertion helper. ClipStack's testable logic — fuzzy
//  ranking and iCloud merge — is pure and has no AppKit dependency, so the suite
//  compiles those two files directly rather than requiring an XCTest host app.
//  Run it with Scripts/test.sh.
//

import Foundation

final class CheckRunner {
    private(set) var failures = 0
    private let suite: String

    init(suite: String) {
        self.suite = suite
        print("\n── \(suite) ──")
    }

    func check(_ label: String, _ passed: Bool, _ detail: String = "") {
        if !passed { failures += 1 }
        let suffix = detail.isEmpty ? "" : "  — \(detail)"
        print("\(passed ? "  PASS" : "  FAIL") \(label)\(suffix)")
    }

    func check<T: Equatable>(_ label: String, _ actual: T, equals expected: T) {
        let passed = actual == expected
        if !passed { failures += 1 }
        print("\(passed ? "  PASS" : "  FAIL") \(label)")
        if !passed {
            print("       got:  \(actual)")
            print("       want: \(expected)")
        }
    }
}
