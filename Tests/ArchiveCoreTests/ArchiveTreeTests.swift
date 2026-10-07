//
//  ArchiveTreeTests.swift
//  ArchiveCoreTests
//
//  The virtual file system: implicit directories, duplicates, unicode paths,
//  deep nesting, and hostile entries that must never reach the tree.
//
//  These tests go through real archives rather than hand-built entry values, so
//  the whole pipeline (libarchive → normalization → tree) is exercised.
//

import Foundation
import Testing

@testable import ArchiveCore

@Suite("virtual archive tree")
struct ArchiveTreeTests {

    @Test("explicit directory entries become directories")
    func explicitDirectories() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .directory("usr/"),
            .directory("usr/bin/"),
            .file("usr/bin/bash", "#!/bin/sh\n"),
            .file("readme.txt", "hello"),
        ], format: .tar)

        let document = try await ArchiveSession().open(url: url)
        let tree = document.tree

        #expect(tree.containsDirectory(at: ""))
        #expect(tree.containsDirectory(at: "usr"))
        #expect(tree.containsDirectory(at: "usr/bin"))
        #expect(tree.root.childDirectoryPaths == ["usr"])
        #expect(tree.directory(at: "usr")?.entryIndex != nil, "explicit directory entry should be recorded")
        #expect(tree.synthesizedDirectoryCount == 0, "every directory was explicit")

        let rootEntries = document.entries(in: "")
        #expect(rootEntries.map(\.name) == ["readme.txt"])
    }

    @Test("missing directories are synthesized")
    func implicitDirectories() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("usr/bin/bash", "bash"),
            .file("usr/bin/zsh", "zsh"),
            .file("usr/lib/libfoo.dylib", "dylib"),
            .file("etc/hosts", "127.0.0.1"),
        ], format: .tar)

        let document = try await ArchiveSession().open(url: url)
        let tree = document.tree

        #expect(tree.containsDirectory(at: "usr"))
        #expect(tree.containsDirectory(at: "usr/bin"))
        #expect(tree.containsDirectory(at: "usr/lib"))
        #expect(tree.containsDirectory(at: "etc"))
        #expect(tree.directory(at: "usr")?.isSynthesized == true)
        #expect(tree.synthesizedDirectoryCount == 4)

        #expect(Set(tree.directory(at: "usr/bin")!.childEntryIndices.map { document.entries[$0].name }) == ["bash", "zsh"])
        #expect(tree.root.childDirectoryPaths.sorted() == ["etc", "usr"])
    }

    @Test("a bare file at the root is not a directory")
    func bareFile() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([.file("readme.txt", "hello")], format: .tar)
        let document = try await ArchiveSession().open(url: url)

        #expect(document.tree.root.childEntryIndices.count == 1)
        #expect(document.tree.root.childDirectoryPaths.isEmpty)
        #expect(document.tree.directories.count == 1, "only the root")
    }

    @Test("duplicate paths produce two entries, not one")
    func duplicatePaths() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("dup.txt", "first"),
            .file("dup.txt", "second"),
        ], format: .tar)

        let document = try await ArchiveSession().open(url: url)
        let rootEntries = document.entries(in: "")

        #expect(document.entries.count == 2)
        #expect(rootEntries.count == 2)
        #expect(Set(rootEntries.map(\.id)).count == 2, "identity must distinguish them")
        #expect(rootEntries.map(\.ordinal) == [0, 1])
    }

    @Test("deeply nested paths build a full chain")
    func deepNesting() async throws {
        let workspace = TempWorkspace()
        let depth = 120
        let path = (0..<depth).map { "d\($0)" }.joined(separator: "/") + "/leaf.txt"
        let url = try workspace.writeArchive([.file(path, "leaf")], format: .tar)

        let document = try await ArchiveSession().open(url: url)

        #expect(document.tree.directories.count == depth + 1, "root plus one per level")
        #expect(document.tree.containsDirectory(at: (0..<depth).map { "d\($0)" }.joined(separator: "/")))

        let breadcrumb = document.tree.breadcrumb(to: ArchivePath.parent(of: path)!)
        #expect(breadcrumb.count == depth + 1)
        #expect(breadcrumb.first?.isRoot == true)
        #expect(breadcrumb.last?.name == "d\(depth - 1)")
    }

    @Test("unicode names are preserved exactly")
    func unicodeNames() async throws {
        let workspace = TempWorkspace()
        let names = ["日本語.txt", "русский.txt", "emoji-🐱.txt", "café.txt"]
        let url = try workspace.writeArchive(names.map { .file($0, "x") }, format: .tar)

        let document = try await ArchiveSession().open(url: url)
        let found = Set(document.entries(in: "").map(\.name))

        #expect(found == Set(names))
    }

    @Test("hostile paths never reach the tree")
    func hostilePathsExcluded() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("good.txt", "good"),
            .file("../../escape.txt", "bad"),
            .file("/etc/passwd", "bad"),
            .file("foo/../../../escape.txt", "bad"),
        ], format: .tar)

        let document = try await ArchiveSession().open(url: url)

        // The entries are still listed in the document so the inspector can
        // show them, but they are quarantined out of the browsable tree.
        #expect(document.entries.count == 4)
        #expect(document.unsafeEntries.count == 3)
        #expect(document.tree.root.childEntryIndices.count == 1)
        #expect(document.entries(in: "").map(\.name) == ["good.txt"])
        #expect(document.summary.unsafeEntryCount == 3)
        #expect(document.warnings.contains { $0.kind == .unsafeEntries })
    }

    @Test("a path used by both a file and a directory is reported")
    func pathConflict() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("thing", "i am a file"),
            .file("thing/child.txt", "i am inside a directory"),
        ], format: .tar)

        let document = try await ArchiveSession().open(url: url)

        #expect(document.tree.containsDirectory(at: "thing"))
        #expect(document.summary.conflictingPathCount == 1)
        #expect(document.warnings.contains { $0.kind == .pathConflicts })
    }

    @Test("an archive with a single root entry works")
    func rootOnlyEntry() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .directory("./"),
            .file("./file.txt", "x"),
        ], format: .tar)

        let document = try await ArchiveSession().open(url: url)

        #expect(document.entries.count == 2)
        #expect(document.entries(in: "").map(\.name) == ["file.txt"])
    }

    @Test("symlinks appear as entries but not as directories")
    func symlinkEntries() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .directory("lib/"),
            .file("lib/libz.dylib", "binary"),
            .symlink("lib/libz.1.dylib", to: "libz.dylib"),
        ], format: .tar)

        let document = try await ArchiveSession().open(url: url)
        let libEntries = document.entries(in: "lib")

        #expect(libEntries.count == 2)
        let link = try #require(libEntries.first { $0.name == "libz.1.dylib" })
        #expect(link.type == .symbolicLink)
        #expect(link.symlinkTarget == "libz.dylib")
        #expect(!link.isDirectory)
    }

    @Test("breadcrumbs walk from the root to the current directory")
    func breadcrumbs() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([.file("usr/local/bin/tool", "x")], format: .tar)
        let document = try await ArchiveSession().open(url: url)

        let crumbs = document.tree.breadcrumb(to: "usr/local/bin")
        #expect(crumbs.map(\.path) == ["", "usr", "usr/local", "usr/local/bin"])
        #expect(crumbs.map(\.name) == ["", "usr", "local", "bin"])
    }

    @Test("expanding a selection includes every descendant in archive order")
    func selectionExpansion() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("top.txt", "top"),
            .file("dir/a.txt", "a"),
            .file("dir/sub/b.txt", "b"),
            .file("other.txt", "other"),
        ], format: .tar)
        let document = try await ArchiveSession().open(url: url)

        // `dir` is implied: no entry of its own, so the tree is the way to
        // reach it.
        let directory = try #require(document.tree.directory(at: "dir"))
        #expect(directory.isSynthesized)
        #expect(directory.childDirectoryPaths == ["dir/sub"])

        // Expanding the subtree mirrors what the browser does when the user
        // selects the folder row.
        let subtree = document.entries
            .filter { $0.path.hasPrefix("dir/") }
            .sorted { $0.ordinal < $1.ordinal }
        let expanded = document.expandingRecursively(subtree)

        #expect(expanded.map(\.path) == ["dir/a.txt", "dir/sub/b.txt"])
        #expect(expanded.map(\.ordinal) == expanded.map(\.ordinal).sorted())
    }
}
