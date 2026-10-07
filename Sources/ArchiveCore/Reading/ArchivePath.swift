//
//  ArchivePath.swift
//  ArchiveCore
//
//  Archive paths are attacker-controlled strings. This file is the single
//  authority on turning one into something safe to index, display and write.
//
//  Two different policies are needed and they are deliberately kept apart:
//
//   * `normalize(rawPath:)` is used for *entry* paths. Any `..` at all is
//     rejected, because no legitimate archiver emits one and archives that do
//     are trying to escape. This is the Zip Slip defence.
//
//   * `resolveSymlinkTarget(_:linkPath:)` is used for *symlink payloads*.
//     Relative targets containing `..` are legal and common (`../lib/libz.dylib`),
//     so they are resolved lexically and only rejected when they climb above
//     the archive root. This is the "symlink then escape" defence.
//

import Foundation

// MARK: - Normalization result

/// The outcome of normalizing one raw archive path.
public struct NormalizedArchivePath: Sendable, Equatable {
    /// Exactly as stored in the archive.
    public let raw: String
    /// Safe, separator-normalized path with no leading slash. Empty means the
    /// archive root.
    public let normalized: String
    /// Safe components; empty for the root.
    public let components: [String]
    /// Whether the raw path was usable.
    public let safety: PathSafety
    /// Whether the raw string ended in a separator (a directory hint).
    public let hadTrailingSeparator: Bool

    public var isSafe: Bool { safety.isSafe }
    public var violation: PathSafetyViolation? { safety.violation }

    /// Last component, or `""` for the root.
    public var name: String { components.last ?? "" }

    /// Parent path, `nil` for entries directly under the root and for the root.
    public var parentPath: String? {
        guard components.count > 1 else { return components.isEmpty ? nil : "" }
        return components.dropLast().joined(separator: "/")
    }
}

// MARK: - ArchivePath

public enum ArchivePath {
    /// macOS limits: `NAME_MAX` is 255 bytes, `PATH_MAX` is 1024 bytes.
    public static let maximumComponentBytes = 255
    public static let maximumPathBytes = 1024

    /// How backslashes in a raw path should be interpreted.
    public enum SeparatorPolicy: Sendable {
        /// Treat `\` as an ordinary character (correct for POSIX archives).
        case posixOnly
        /// Treat `\` as a path separator (correct for many Windows-created ZIPs).
        case convertBackslashes
        /// Convert only when the path contains `\` and no `/`. This is the
        /// heuristic used for real archives: a Windows ZIP entry is
        /// `dir\file.txt`, while a POSIX file that merely has a backslash in
        /// its name almost always also contains a `/` somewhere above it.
        case automatic

        func shouldConvert(_ raw: String) -> Bool {
            switch self {
            case .posixOnly:
                return false
            case .convertBackslashes:
                return raw.contains("\\")
            case .automatic:
                return raw.contains("\\") && !raw.contains("/")
            }
        }
    }

    /// Normalizes an archive path and classifies its safety.
    ///
    /// Never throws: callers get a `NormalizedArchivePath` whose `safety`
    /// explains any rejection, which lets the UI list hostile entries in the
    /// summary instead of silently dropping them.
    public static func normalize(
        rawPath: String,
        separatorPolicy: SeparatorPolicy = .automatic
    ) -> NormalizedArchivePath {
        let raw = rawPath
        let hadTrailingSeparator = raw.hasSuffix("/") || raw.hasSuffix("\\")

        // A NUL byte can never appear in a macOS path; it is also the classic
        // way to smuggle a second name past a naive validator.
        if raw.contains("\0") {
            return rejected(raw, .invalidCharacters, hadTrailingSeparator: hadTrailingSeparator)
        }

        var working = raw
        if separatorPolicy.shouldConvert(raw) {
            working = working.replacingOccurrences(of: "\\", with: "/")
        }

        // Absolute POSIX path.
        if working.hasPrefix("/") {
            return rejected(raw, .absolutePath, hadTrailingSeparator: hadTrailingSeparator)
        }
        // Windows drive-relative or UNC path, e.g. `C:\Windows` or `\\host\share`.
        if isWindowsAbsolutePath(working) {
            return rejected(raw, .absolutePath, hadTrailingSeparator: hadTrailingSeparator)
        }

        var components: [String] = []
        let parts = working.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for (index, component) in parts.enumerated() {
            if component.isEmpty {
                // A trailing empty component is just the trailing slash; an
                // interior one (`a//b`) is ambiguous and gets rejected.
                if index == parts.count - 1 { break }
                if index == 0 { continue }
                return rejected(raw, .ambiguousComponent, hadTrailingSeparator: hadTrailingSeparator)
            }
            if component == "." {
                continue // harmless self reference: `./usr/bin`
            }
            if component == ".." {
                return rejected(raw, .parentTraversal, hadTrailingSeparator: hadTrailingSeparator)
            }
            if component.utf8.count > maximumComponentBytes {
                return rejected(raw, .componentTooLong, hadTrailingSeparator: hadTrailingSeparator)
            }
            components.append(component)
        }

        if components.isEmpty {
            // `.`, `./`, or an empty string all denote the archive root, which
            // is legitimate for tarballs created with `tar cf x.tar .`.
            let denotesRoot = working.isEmpty
                || working.allSatisfy { $0 == "/" || $0 == "." }
            if denotesRoot {
                return NormalizedArchivePath(
                    raw: raw,
                    normalized: "",
                    components: [],
                    safety: .safe,
                    hadTrailingSeparator: hadTrailingSeparator
                )
            }
            return rejected(raw, .emptyResult, hadTrailingSeparator: hadTrailingSeparator)
        }

        let normalized = components.joined(separator: "/")
        if normalized.utf8.count > maximumPathBytes {
            return rejected(raw, .componentTooLong, hadTrailingSeparator: hadTrailingSeparator)
        }

        return NormalizedArchivePath(
            raw: raw,
            normalized: normalized,
            components: components,
            safety: .safe,
            hadTrailingSeparator: hadTrailingSeparator
        )
    }

    /// Convenience wrapper used by the reader.
    public static func safety(ofRawPath rawPath: String) -> PathSafety {
        normalize(rawPath: rawPath).safety
    }

    // MARK: Path algebra

    /// `usr/bin/bash` → `usr/bin`; `usr` → `""`; `""` → `nil`.
    public static func parent(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard let index = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<index])
    }

    /// `usr/bin/bash` → `bash`.
    public static func name(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: index)...])
    }

    /// Joins a parent path and a component, tolerating an empty parent.
    public static func joining(_ parent: String, _ component: String) -> String {
        parent.isEmpty ? component : parent + "/" + component
    }

    /// Number of components; 0 for the root.
    public static func depth(of path: String) -> Int {
        path.isEmpty ? 0 : path.split(separator: "/").count
    }

    /// `["", "usr", "usr/bin"]` for `usr/bin/bash` — every ancestor directory,
    /// including the root, in root-to-leaf order.
    public static func ancestors(of path: String) -> [String] {
        var result: [String] = [""]
        let components = path.split(separator: "/")
        guard components.count > 1 else { return result }
        var current = ""
        for component in components.dropLast() {
            current = current.isEmpty ? String(component) : current + "/" + component
            result.append(current)
        }
        return result
    }

    // MARK: Symlink targets

    /// Result of validating a symlink payload.
    public enum SymlinkResolution: Sendable, Equatable {
        /// The target stays inside the extraction root.
        /// `normalizedTarget` is relative to the root (may contain `..`).
        case insideRoot(normalizedTarget: String)
        /// The target points outside the extraction root and must be refused.
        case escapesRoot(violation: PathSafetyViolation)

        public var isSafe: Bool {
            if case .insideRoot = self { return true }
            return false
        }
    }

    /// Validates a symlink payload against the archive root.
    ///
    /// - Parameters:
    ///   - target: the symlink's stored target, as read from the archive.
    ///   - linkPath: normalized path of the symlink itself.
    ///
    /// A target is accepted when, resolved lexically against the link's parent
    /// directory, it never climbs above the root. Absolute targets are always
    /// refused: extracting them would let an archive point a "harmless" link at
    /// `/etc` and, more importantly, a later entry could be written *through*
    /// it (the second half of the Zip Slip attack).
    public static func resolveSymlinkTarget(_ target: String, linkPath: String) -> SymlinkResolution {
        if target.isEmpty {
            return .escapesRoot(violation: .emptyResult)
        }
        if target.contains("\0") {
            return .escapesRoot(violation: .invalidCharacters)
        }
        if target.hasPrefix("/") || isWindowsAbsolutePath(target) {
            return .escapesRoot(violation: .absolutePath)
        }

        // Start at the link's containing directory within the root.
        var stack = Array(linkPath.split(separator: "/").dropLast()).map(String.init)

        for component in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if stack.isEmpty {
                    // Climbing above the root.
                    return .escapesRoot(violation: .parentTraversal)
                }
                stack.removeLast()
            default:
                stack.append(String(component))
            }
        }

        return .insideRoot(normalizedTarget: stack.joined(separator: "/"))
    }

    // MARK: Helpers

    /// `C:\Windows`, `C:/Windows`, `\\server\share`.
    private static func isWindowsAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("\\\\") { return true }
        let characters = Array(path.prefix(3))
        guard characters.count >= 2 else { return false }
        guard characters[0].isLetter, characters[1] == ":" else { return false }
        if characters.count == 2 { return true }
        return characters[2] == "/" || characters[2] == "\\"
    }

    private static func rejected(
        _ raw: String,
        _ violation: PathSafetyViolation,
        hadTrailingSeparator: Bool
    ) -> NormalizedArchivePath {
        NormalizedArchivePath(
            raw: raw,
            normalized: "",
            components: [],
            safety: .unsafe(violation),
            hadTrailingSeparator: hadTrailingSeparator
        )
    }
}
