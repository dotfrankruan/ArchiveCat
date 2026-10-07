//
//  ArchivePathTests.swift
//  ArchiveCoreTests
//
//  Path handling is the security boundary of the whole product, so it gets the
//  most paranoid tests in the suite.
//

import Foundation
import Testing

@testable import ArchiveCore

@Suite("archive path normalization")
struct ArchivePathTests {

    @Test("plain paths normalize to themselves")
    func plainPaths() {
        let samples = [
            "usr/bin/bash",
            "etc/hosts",
            "a",
            "a/b/c/d/e",
            "file with spaces.txt",
            "weird:name?.txt",
        ]
        for sample in samples {
            let result = ArchivePath.normalize(rawPath: sample)
            #expect(result.isSafe, "\(sample) should be safe")
            #expect(result.normalized == sample)
        }
    }

    @Test("harmless self references are dropped", arguments: zip(
        ["./usr/bin", "usr/./bin", "./", ".", "a/./b"],
        ["usr/bin", "usr/bin", "", "", "a/b"]
    ))
    func dotComponents(raw: String, expected: String) {
        let result = ArchivePath.normalize(rawPath: raw)
        #expect(result.isSafe, "\(raw) should be safe")
        #expect(result.normalized == expected)
    }

    @Test("traversal is rejected", arguments: [
        "../../escape",
        "foo/../../../escape",
        "foo/../../bar",
        "..",
        "../a",
        "a/..",
        "a/b/../../..",
        ".../../a",
    ])
    func traversalRejected(raw: String) {
        let result = ArchivePath.normalize(rawPath: raw)
        #expect(!result.isSafe, "\(raw) must be rejected")
        #expect(result.violation == .parentTraversal)
        #expect(result.normalized.isEmpty)
    }

    @Test("absolute paths are rejected", arguments: [
        "/absolute/path",
        "/",
        "//etc/hosts",
        "/etc",
        "C:\\Windows\\System32",
        "C:/Windows",
        "C:",
        "\\\\server\\share\\file",
    ])
    func absoluteRejected(raw: String) {
        let result = ArchivePath.normalize(rawPath: raw)
        #expect(!result.isSafe, "\(raw) must be rejected")
        #expect(result.violation == .absolutePath)
    }

    @Test("an interior empty component is ambiguous and rejected")
    func ambiguousComponent() {
        let result = ArchivePath.normalize(rawPath: "a//b")
        #expect(result.violation == .ambiguousComponent)
    }

    @Test("trailing slashes are tolerated and recorded")
    func trailingSlash() {
        let result = ArchivePath.normalize(rawPath: "usr/bin/")
        #expect(result.isSafe)
        #expect(result.normalized == "usr/bin")
        #expect(result.hadTrailingSeparator)
    }

    @Test("backslashes are converted only when the path has no slash")
    func windowsSeparators() {
        let converted = ArchivePath.normalize(rawPath: "dir\\nested\\file.txt")
        #expect(converted.normalized == "dir/nested/file.txt")

        // A POSIX name that merely contains a backslash is left alone.
        let literal = ArchivePath.normalize(rawPath: "dir/file\\name.txt")
        #expect(literal.normalized == "dir/file\\name.txt")
    }

    @Test("the separator policy can be forced")
    func separatorPolicy() {
        let posix = ArchivePath.normalize(rawPath: "dir\\file", separatorPolicy: .posixOnly)
        #expect(posix.normalized == "dir\\file")

        let forced = ArchivePath.normalize(rawPath: "dir\\file", separatorPolicy: .convertBackslashes)
        #expect(forced.normalized == "dir/file")
    }

    @Test("unicode file names survive round trips", arguments: [
        "日本語/ファイル.txt",
        "русский/файл",
        "emoji/🐱📦.txt",
        "nfd/e\u{301}clair.txt",
        "combining/e\u{0301}",
    ])
    func unicodeNames(path: String) {
        let result = ArchivePath.normalize(rawPath: path)
        #expect(result.isSafe, "\(path) should be safe")
        #expect(result.normalized == path)
        #expect(result.name == ArchivePath.name(of: path))
        #expect(result.parentPath == ArchivePath.parent(of: path))
    }

    @Test("NUL bytes are rejected")
    func nulRejected() {
        let result = ArchivePath.normalize(rawPath: "dir/fi\0le")
        #expect(result.violation == .invalidCharacters)
    }

    @Test("over-long components and paths are rejected")
    func lengthLimits() {
        let longComponent = String(repeating: "a", count: ArchivePath.maximumComponentBytes + 1)
        #expect(ArchivePath.normalize(rawPath: longComponent).violation == .componentTooLong)

        let deepPath = (0..<200).map { "component\($0)" }.joined(separator: "/")
        #expect(ArchivePath.normalize(rawPath: deepPath).violation == .componentTooLong)
    }

    @Test("path algebra")
    func algebra() {
        #expect(ArchivePath.parent(of: "usr/bin/bash") == "usr/bin")
        #expect(ArchivePath.parent(of: "usr") == "")
        #expect(ArchivePath.parent(of: "") == nil)
        #expect(ArchivePath.name(of: "usr/bin/bash") == "bash")
        #expect(ArchivePath.name(of: "usr") == "usr")
        #expect(ArchivePath.joining("usr/bin", "bash") == "usr/bin/bash")
        #expect(ArchivePath.joining("", "bash") == "bash")
        #expect(ArchivePath.depth(of: "") == 0)
        #expect(ArchivePath.depth(of: "a/b/c") == 3)
        #expect(ArchivePath.ancestors(of: "usr/bin/bash") == ["", "usr", "usr/bin"])
        #expect(ArchivePath.ancestors(of: "usr") == [""])
    }
}

@Suite("symlink target validation")
struct SymlinkTargetTests {

    @Test("relative targets inside the root are allowed")
    func allowedTargets() {
        let cases: [(target: String, linkPath: String, expected: String)] = [
            ("lib/libz.dylib", "usr/bin/tool", "usr/bin/lib/libz.dylib"),
            ("../lib/libz.dylib", "usr/bin/tool", "usr/lib/libz.dylib"),
            ("./sibling", "dir/link", "dir/sibling"),
            ("../sibling", "dir/link", "sibling"),
            ("a/b/c", "link", "a/b/c"),
        ]
        for item in cases {
            let resolution = ArchivePath.resolveSymlinkTarget(item.target, linkPath: item.linkPath)
            switch resolution {
            case let .insideRoot(normalized):
                #expect(normalized == item.expected, "\(item.target) from \(item.linkPath)")
            case let .escapesRoot(violation):
                Issue.record("expected \(item.target) to resolve inside the root, got \(violation)")
            }
        }
    }

    @Test("targets that climb above the root are refused")
    func escapingTargets() {
        let cases: [(target: String, linkPath: String)] = [
            ("../../etc/passwd", "dir/link"),
            ("../..", "dir/link"),
            ("..", "link"),
            ("../../../outside", "a/b/link"),
            ("/etc/passwd", "link"),
            ("//etc/passwd", "link"),
            ("C:\\Windows", "link"),
            ("", "link"),
        ]
        for item in cases {
            let resolution = ArchivePath.resolveSymlinkTarget(item.target, linkPath: item.linkPath)
            #expect(!resolution.isSafe, "\(item.target) must be refused")
        }
    }

    @Test("a target that returns to the root is still inside")
    func returnsToRoot() {
        // `a/b/../c` from the root stays inside.
        let resolution = ArchivePath.resolveSymlinkTarget("a/../c", linkPath: "link")
        #expect(resolution == .insideRoot(normalizedTarget: "c"))
    }
}
