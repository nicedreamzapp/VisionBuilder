//
//  CLIPTokenizer.swift
//  Vision Builder
//
//  BPE (Byte Pair Encoding) tokenizer for CLIP text input.
//  Adapted from Apple's open-source ml-stable-diffusion implementation (MIT License).
//

import Foundation

/// A tokenizer based on byte pair encoding, compatible with OpenAI CLIP models.
struct CLIPTokenizer {

    /// Maps pairs of tokens to the rank/order of the merge.
    private let merges: [TokenPair: Int]

    /// Maps tokens to integer identifiers.
    private let vocabulary: [String: Int]

    private let startToken = "<|startoftext|>"
    private let endToken = "<|endoftext|>"
    private let unknownTokenID: Int

    /// Context length for CLIP models (always 77 tokens).
    static let contextLength = 77

    init(mergesURL: URL, vocabularyURL: URL) throws {
        self.merges = try Self.readMerges(url: mergesURL)
        self.vocabulary = try Self.readVocabulary(url: vocabularyURL)
        self.unknownTokenID = vocabulary["<|endoftext|>"] ?? 0
    }

    /// Tokenize input text and return fixed-length token ID array for CLIP.
    /// Always returns exactly `contextLength` (77) token IDs, padded or truncated.
    func tokenize(_ text: String) -> [Int32] {
        var tokens: [String] = [startToken]
        tokens.append(contentsOf: encode(input: text))
        tokens.append(endToken)

        // Map to IDs
        var ids = tokens.map { Int32(vocabulary[$0] ?? unknownTokenID) }

        // Truncate if too long
        if ids.count > Self.contextLength {
            ids = Array(ids.prefix(Self.contextLength - 1))
            ids.append(Int32(vocabulary[endToken] ?? unknownTokenID))
        }

        // Pad to context length
        while ids.count < Self.contextLength {
            ids.append(0)
        }

        return ids
    }

    // MARK: - BPE Encoding

    private func encode(input: String) -> [String] {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let words = normalized.split(separator: " ")
        return words.flatMap { encode(word: $0) }
    }

    private func encode(word: Substring) -> [String] {
        var tokens = word.map { String($0) }
        guard !tokens.isEmpty else { return [] }
        tokens[tokens.count - 1] = tokens[tokens.count - 1] + "</w>"

        while true {
            let pairs = adjacentPairs(for: tokens)
            let mergeable = pairs.filter { merges[$0] != nil }

            guard let bestMerge = mergeable.min(by: { merges[$0]! < merges[$1]! }) else {
                break
            }
            tokens = merge(tokens, pair: bestMerge)
        }
        return tokens
    }

    private func adjacentPairs(for tokens: [String]) -> Set<TokenPair> {
        guard tokens.count > 1 else { return [] }
        var pairs = Set<TokenPair>(minimumCapacity: tokens.count - 1)
        var prev = tokens[0]
        for token in tokens.dropFirst() {
            pairs.insert(TokenPair(prev, token))
            prev = token
        }
        return pairs
    }

    private func merge(_ tokens: [String], pair: TokenPair) -> [String] {
        guard tokens.count > 1 else { return tokens }
        var result = [String]()
        result.reserveCapacity(tokens.count - 1)

        var i = 0
        while i < tokens.count {
            if let matchIndex = tokens[i...].firstIndex(of: pair.first) {
                result.append(contentsOf: tokens[i..<matchIndex])
                if matchIndex + 1 < tokens.count && tokens[matchIndex + 1] == pair.second {
                    result.append(pair.first + pair.second)
                    i = matchIndex + 2
                } else {
                    result.append(pair.first)
                    i = matchIndex + 1
                }
            } else {
                result.append(contentsOf: tokens[i...])
                break
            }
        }
        return result
    }

    // MARK: - File Reading

    private static func readVocabulary(url: URL) throws -> [String: Int] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    private static func readMerges(url: URL) throws -> [TokenPair: Int] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")

        var merges = [TokenPair: Int](minimumCapacity: lines.count)
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            merges[TokenPair(String(parts[0]), String(parts[1]))] = index
        }
        return merges
    }

    // MARK: - Token Pair

    struct TokenPair: Hashable {
        let first: String
        let second: String

        init(_ first: String, _ second: String) {
            self.first = first
            self.second = second
        }
    }
}
