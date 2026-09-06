//
//  main.swift
//  ClipStack tests
//

import Foundation

let totalFailures = FuzzySearchChecks.run()
    + SyncMergeChecks.run()
    + (await ClipboardChecks.run())

print("")
if totalFailures == 0 {
    print("All checks passed.")
    exit(0)
} else {
    print("\(totalFailures) check(s) FAILED.")
    exit(1)
}
