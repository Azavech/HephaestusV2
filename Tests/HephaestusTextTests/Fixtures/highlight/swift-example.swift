#!/usr/bin/swift
import Foundation

/// Greets someone.
@MainActor final class Greeter: Sendable {
    nonisolated(unsafe) var count = 0x1F
    func greet(for name: String) async throws -> String {
        let text = #"Hello \#(name) "\(raw)""#
        /* outer /* inner */ still comment */
        return "Count: \(count + 1)\n"
    }
}
