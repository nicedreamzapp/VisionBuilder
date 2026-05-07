//
//  FoundationModelsClusterNamer.swift
//  Vision Builder
//
//  iOS 26 Foundation Models (~3B on-device LLM) for smart cluster naming and
//  label normalization. Privacy-first: nothing leaves the device.
//
//  Usage:
//      let namer = FoundationModelsClusterNamer.shared
//      if await namer.isAvailable {
//          let suggestion = try await namer.suggestClusterName(
//              sampleLabels: ["mug", "cup", "ceramic vessel"],
//              count: 12
//          )
//      }
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class FoundationModelsClusterNamer {

    static let shared = FoundationModelsClusterNamer()

    private init() {}

    /// True only when the on-device model is available on this device + iOS version.
    /// Capable devices: iPhone 15 Pro / 16 Pro / 17 / etc. with Apple Intelligence enabled.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Suggest a concise human-readable name for a cluster of similar objects.
    /// `sampleLabels` are noisy guesses (from YOLO classes, OCR, prior labels);
    /// the model picks the best canonical short label.
    func suggestClusterName(sampleLabels: [String], count: Int) async throws -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable else { return nil }

        let session = LanguageModelSession(instructions: """
            You name clusters of similar objects from an on-device photo dataset.
            Reply with a single canonical noun phrase, Title Case, 1–4 words.
            No punctuation, no quotes, no explanation. Example: "Coffee Mug".
            """)

        let prompt = """
            Cluster size: \(count) similar objects.
            Detected labels (noisy): \(sampleLabels.prefix(8).joined(separator: ", "))
            Best name?
            """

        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return nil
        #endif
    }

    /// Decide whether `raw` is a synonym of an existing label and return the canonical one.
    /// Returns the original `raw` (Title Cased) when no good match exists.
    func canonicalLabel(_ raw: String, existing: [String]) async throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable, !existing.isEmpty else {
            return titleCase(trimmed)
        }

        let session = LanguageModelSession(instructions: """
            You normalize object labels for an on-device dataset. Given a new label
            and a list of existing labels, decide:
              - If the new label is a synonym/variant of an existing one (e.g. "mug" ↔ "Coffee Mug"),
                reply with EXACTLY the existing label.
              - Otherwise reply with a Title-Cased version of the new label, 1–4 words.
            Reply with the label only — no quotes, no explanation.
            """)

        let prompt = """
            Existing labels: \(existing.joined(separator: ", "))
            New label: \(trimmed)
            Canonical?
            """
        let response = try await session.respond(to: prompt)
        let suggestion = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return suggestion.isEmpty ? titleCase(trimmed) : suggestion
        #else
        return titleCase(trimmed)
        #endif
    }

    private func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}
