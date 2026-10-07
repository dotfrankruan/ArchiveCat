//
//  ArchiveSearchIndex.swift
//  ArchiveCore
//
//  Filename/path search over the in-memory metadata index.
//
//  This never reads file contents: v1 searches names, full paths and extensions
//  only, and it does so against pre-lowercased copies so a keystroke over a
//  100 000 entry archive is a few milliseconds of work rather than a few
//  hundred.
//

import Foundation

public struct ArchiveSearchIndex: Sendable {

    /// One search hit.
    public struct Match: Sendable, Identifiable, Hashable {
        /// Index into the original `entries` array.
        public let entryIndex: Int
        /// Higher is better.
        public let score: Int

        public var id: Int { entryIndex }
    }

    private let entries: [ArchiveEntry]
    private let safeEntryIndices: [Int]
    private let loweredNames: [String]
    private let loweredPaths: [String]
    /// For each safe entry, the index of its parent directory (for path search).
    private let loweredExtensions: [String]

    public init(entries: [ArchiveEntry]) {
        self.entries = entries

        var indices: [Int] = []
        var names: [String] = []
        var paths: [String] = []
        var extensions: [String] = []
        indices.reserveCapacity(entries.count)
        names.reserveCapacity(entries.count)
        paths.reserveCapacity(entries.count)
        extensions.reserveCapacity(entries.count)

        for (index, entry) in entries.enumerated() where entry.safety.isSafe {
            indices.append(index)
            names.append(entry.name.lowercased())
            paths.append(entry.path.lowercased())
            extensions.append(entry.fileExtension ?? "")
        }

        self.safeEntryIndices = indices
        self.loweredNames = names
        self.loweredPaths = paths
        self.loweredExtensions = extensions
    }

    public var searchableCount: Int { safeEntryIndices.count }

    /// Search entry names and paths, case-insensitively.
    ///
    /// Every whitespace-separated token must appear somewhere in the name, path
    /// or extension, which makes "lib ssl" find `sources/libssl/README.md`.
    public func search(_ query: String, limit: Int = 500) -> [Int] {
        searchMatches(query, limit: limit).map(\.entryIndex)
    }

    /// Ranked search results.
    public func searchMatches(_ query: String, limit: Int = 500) -> [Match] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        guard !tokens.isEmpty else { return [] }

        var matches: [Match] = []

        for position in loweredNames.indices {
            let name = loweredNames[position]
            let path = loweredPaths[position]
            let fileExtension = loweredExtensions[position]

            var score = 0
            var matchedAllTokens = true

            for token in tokens {
                let tokenScore = Self.score(token: token, name: name, path: path, fileExtension: fileExtension)
                if tokenScore == 0 {
                    matchedAllTokens = false
                    break
                }
                score += tokenScore
            }

            guard matchedAllTokens else { continue }

            // Shorter paths first among equal scores: a hit near the root is
            // usually the one the user meant.
            score -= min(path.count, 100) / 10
            matches.append(Match(entryIndex: safeEntryIndices[position], score: score))
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsPath = entries[lhs.entryIndex].path
            let rhsPath = entries[rhs.entryIndex].path
            if lhsPath.count != rhsPath.count { return lhsPath.count < rhsPath.count }
            return lhsPath < rhsPath
        }

        if matches.count > limit {
            matches.removeLast(matches.count - limit)
        }
        return matches
    }

    private static func score(token: String, name: String, path: String, fileExtension: String) -> Int {
        if name == token { return 1000 }
        if name.hasPrefix(token) { return 800 }
        if fileExtension == token { return 700 }
        if name.contains(token) { return 600 }
        if path.contains(token) { return 400 }
        return 0
    }
}
