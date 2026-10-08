//
//  SecureDestination.swift
//  ArchiveCore
//
//  A destination-root-confined writer.
//
//  Every path is walked one component at a time with `openat(…, O_NOFOLLOW)` or
//  `mkdirat`, starting from a descriptor for the destination root. That makes
//  the classic two-stage attack impossible:
//
//      1. entry `x` is a symlink to `/tmp`
//      2. entry `x/evil` is a regular file
//
//  With descriptor-relative, no-follow traversal, step 2 cannot walk through
//  `x`, whatever `x` is. Symlinks are also created only *after* every regular
//  file has been written, so they can never be used as a traversal vector even
//  if the kernel semantics above were bypassed.
//
//  Plus: no archive path is ever concatenated into an absolute string and
//  handed to `FileManager`, so a `..` cannot escape even if validation is
//  bypassed.
//

import Darwin
import Foundation

/// A POSIX-level failure with enough context to be reported helpfully.
struct POSIXFailure: Error {
    let operation: String
    let errorNumber: Int32
    let relativePath: String

    var message: String {
        let description = String(cString: strerror(errorNumber))
        return "\(operation) on “\(relativePath)” failed: \(description)"
    }

    var diagnostic: String {
        "\(operation)(\(relativePath)) -> errno \(errorNumber) (\(String(cString: strerror(errorNumber))))"
    }
}

/// Writes files, directories, symlinks and hard links inside one root directory.
final class SecureDestination {
    let root: URL
    private let rootDescriptor: Int32

    init(root: URL) throws {
        self.root = root

        let descriptor = root.path(percentEncoded: false).withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let errorNumber = errno
            throw ArchiveError.destinationUnusable(
                url: root,
                reason: String(cString: strerror(errorNumber))
            )
        }
        self.rootDescriptor = descriptor
    }

    deinit {
        close(rootDescriptor)
    }

    // MARK: - Directories

    /// Creates one component of a directory chain, tolerating an existing entry.
    ///
    /// - Returns: `true` when this call created it.
    @discardableResult
    func createDirectory(relativePath: String, mode: mode_t = 0o755) throws -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }

        var descriptor = try duplicateRootDescriptor()
        defer { close(descriptor) }

        var created = false
        for (index, component) in components.enumerated() {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw POSIXFailure(operation: "validate directory", errorNumber: EINVAL, relativePath: relativePath)
            }

            let result = mkdirat(descriptor, component, mode)
            if result == 0 {
                // Only the last component counts as "the directory we promised
                // to create"; intermediate ones are incidental.
                if index == components.count - 1 { created = true }
            } else if errno != EEXIST {
                throw POSIXFailure(operation: "mkdir", errorNumber: errno, relativePath: components[0...index].joined(separator: "/"))
            }

            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                let errorNumber = errno
                throw POSIXFailure(
                    operation: "open directory",
                    errorNumber: errorNumber,
                    relativePath: components[0...index].joined(separator: "/")
                )
            }
            close(descriptor)
            descriptor = next
        }

        return created
    }

    // MARK: - Files

    /// Outcome of creating a file.
    struct CreatedFile {
        let descriptor: Int32
        /// Relative path actually used; differs from the requested one only for
        /// the "Keep Both" policy.
        let relativePath: String
    }

    /// Creates (or truncates) a file inside the root.
    ///
    /// - Parameters:
    ///   - relativePath: destination-relative path; must already be validated.
    ///   - mode: permission bits to create with.
    ///   - action: what to do about something already living at that path. The
    ///     decision is made by the caller (see `ExtractionConflictResolver`);
    ///     this function only executes it.
    /// - Returns: `nil` when the action was `.skip` and the file already existed.
    func createFile(
        relativePath: String,
        mode: mode_t = 0o644,
        action: ConflictAction
    ) throws -> CreatedFile? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last, !name.isEmpty else {
            throw POSIXFailure(operation: "create file", errorNumber: EINVAL, relativePath: relativePath)
        }

        return try withParentDescriptor(ofComponents: components.dropLast()) { parent, parentRelativePath -> CreatedFile? in
            var targetName = name
            var targetRelativePath = relativePath

            let exists = Self.exists(parent: parent, name: targetName)

            switch action {
            case .skip:
                if exists { return nil }
            case .keepBoth:
                if exists {
                    let unique = try Self.uniqueName(parent: parent, name: name)
                    targetName = unique
                    targetRelativePath = parentRelativePath.isEmpty ? unique : parentRelativePath + "/" + unique
                }
            case .replace:
                if exists {
                    // "Replace" means precisely this: replace the *file*. A
                    // folder is never deleted to make way for one, and a
                    // pre-existing symlink is never written through or removed
                    // — the O_NOFOLLOW open below would fail anyway, and this
                    // turns that into a message instead of a bare ELOOP.
                    var status = stat()
                    if fstatat(parent, targetName, &status, AT_SYMLINK_NOFOLLOW) == 0 {
                        let typeBits = POSIXFileType.of(stat: status)
                        if typeBits == POSIXFileType.directory {
                            throw POSIXFailure(operation: "replace directory with file", errorNumber: EISDIR, relativePath: targetRelativePath)
                        }
                        if typeBits == POSIXFileType.symbolicLink {
                            // Removing a pre-existing symlink the user placed is
                            // surprising; refuse and let the report explain.
                            throw POSIXFailure(operation: "replace symbolic link", errorNumber: ELOOP, relativePath: targetRelativePath)
                        }
                    }
                }
            }

            let descriptor = openat(
                parent,
                targetName,
                O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC,
                mode
            )
            guard descriptor >= 0 else {
                let errorNumber = errno
                throw POSIXFailure(operation: "open for writing", errorNumber: errorNumber, relativePath: targetRelativePath)
            }

            return CreatedFile(descriptor: descriptor, relativePath: targetRelativePath)
        }
    }

    /// Applies final permission bits to an open file.
    @discardableResult
    func applyPermissions(descriptor: Int32, mode: mode_t) -> Bool {
        fchmod(descriptor, mode & 0o7777) == 0
    }

    /// Applies permission bits to an already-created directory.
    func applyDirectoryPermissions(relativePath: String, mode: mode_t) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { return }

        try withParentDescriptor(ofComponents: components.dropLast()) { parent, _ in
            let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw POSIXFailure(operation: "open directory for chmod", errorNumber: errno, relativePath: relativePath)
            }
            defer { close(descriptor) }
            guard fchmod(descriptor, mode & 0o7777) == 0 else {
                throw POSIXFailure(operation: "fchmod", errorNumber: errno, relativePath: relativePath)
            }
        }
    }

    /// Creates a FIFO. Device nodes and sockets are deliberately not supported:
    /// creating them needs privileges and is never what a user wants from an
    /// untrusted archive.
    func createFIFO(relativePath: String, mode: mode_t) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else {
            throw POSIXFailure(operation: "create FIFO", errorNumber: EINVAL, relativePath: relativePath)
        }
        try withParentDescriptor(ofComponents: components.dropLast()) { parent, _ in
            guard mkfifoat(parent, name, mode & 0o7777) == 0 else {
                throw POSIXFailure(operation: "mkfifoat", errorNumber: errno, relativePath: relativePath)
            }
        }
    }

    // MARK: - Links

    /// Creates a symbolic link. `target` is stored verbatim; callers must have
    /// validated that it resolves inside the root.
    func createSymbolicLink(relativePath: String, target: String) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else {
            throw POSIXFailure(operation: "create symlink", errorNumber: EINVAL, relativePath: relativePath)
        }
        try withParentDescriptor(ofComponents: components.dropLast()) { parent, _ in
            guard symlinkat(target, parent, name) == 0 else {
                throw POSIXFailure(operation: "symlink", errorNumber: errno, relativePath: relativePath)
            }
        }
    }

    /// Creates a hard link to a file that was already extracted.
    func createHardLink(relativePath: String, toRelativePath targetRelativePath: String) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else {
            throw POSIXFailure(operation: "create hard link", errorNumber: EINVAL, relativePath: relativePath)
        }
        let targetComponents = targetRelativePath.split(separator: "/").map(String.init)
        guard let targetName = targetComponents.last else {
            throw POSIXFailure(operation: "create hard link", errorNumber: EINVAL, relativePath: targetRelativePath)
        }

        try withParentDescriptor(ofComponents: components.dropLast()) { parent, _ in
            try withParentDescriptor(ofComponents: targetComponents.dropLast()) { targetParent, _ in
                guard linkat(targetParent, targetName, parent, name, 0) == 0 else {
                    throw POSIXFailure(operation: "link", errorNumber: errno, relativePath: relativePath)
                }
            }
        }
    }

    // MARK: - Metadata

    /// Sets the modification date relative to the root, with no symlink
    /// traversal at any component.
    func setModificationDate(relativePath: String, date: Date) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { return }

        // `utimensat` uses `timespec`, and both atime and mtime are set to the
        // archived timestamp so the result matches `tar -x`.
        let seconds = Int(date.timeIntervalSince1970)
        var times = [
            timespec(tv_sec: seconds, tv_nsec: 0),
            timespec(tv_sec: seconds, tv_nsec: 0),
        ]

        try withParentDescriptor(ofComponents: components.dropLast()) { parent, _ in
            guard utimensat(parent, name, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw POSIXFailure(operation: "utimensat", errorNumber: errno, relativePath: relativePath)
            }
        }
    }

    // MARK: - Introspection

    /// Whether the destination already holds something at this path.
    func exists(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { return false }
        return (try? withParentDescriptor(ofComponents: components.dropLast()) { parent, _ in
            Self.exists(parent: parent, name: name)
        }) ?? false
    }

    /// Whether the destination holds a directory at this path.
    func isDirectory(relativePath: String) throws -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { return false }
        return try withParentDescriptor(ofComponents: components.dropLast()) { parent, _ in
            var status = stat()
            guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            return POSIXFileType.of(stat: status) == POSIXFileType.directory
        }
    }

    /// Removes a file, symlink or FIFO. Directories are refused: extraction
    /// never deletes a directory that the user may have created.
    func removeFile(relativePath: String) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { return }
        try withParentDescriptor(ofComponents: components.dropLast()) { parent, _ in
            if unlinkat(parent, name, 0) != 0 {
                throw POSIXFailure(operation: "unlink", errorNumber: errno, relativePath: relativePath)
            }
        }
    }

    /// A relative path that does not exist yet, by inserting " 2", " 3", …
    func uniqueRelativePath(for relativePath: String) throws -> String {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { return relativePath }
        let parentRelativePath = components.dropLast().joined(separator: "/")
        return try withParentDescriptor(ofComponents: components.dropLast()) { parent, _ in
            let unique = try Self.uniqueName(parent: parent, name: name)
            return parentRelativePath.isEmpty ? unique : parentRelativePath + "/" + unique
        }
    }

    // MARK: - Helpers

    private func duplicateRootDescriptor() throws -> Int32 {
        let descriptor = openat(rootDescriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ArchiveError.destinationUnusable(
                url: root,
                reason: "The destination folder is no longer accessible."
            )
        }
        return descriptor
    }

    /// Walks `components` with `O_NOFOLLOW` and hands `body` a descriptor for
    /// the resulting directory.
    private func withParentDescriptor<T>(
        ofComponents components: ArraySlice<String>,
        _ body: (Int32, String) throws -> T
    ) throws -> T {
        var descriptor = try duplicateRootDescriptor()
        var parentRelativePath = ""

        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                close(descriptor)
                throw POSIXFailure(operation: "validate path", errorNumber: EINVAL, relativePath: component)
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                let errorNumber = errno
                close(descriptor)
                throw POSIXFailure(
                    operation: "open parent directory",
                    errorNumber: errorNumber,
                    relativePath: parentRelativePath.isEmpty ? component : parentRelativePath + "/" + component
                )
            }
            close(descriptor)
            descriptor = next
            parentRelativePath = parentRelativePath.isEmpty ? component : parentRelativePath + "/" + component
        }

        defer { close(descriptor) }
        return try body(descriptor, parentRelativePath)
    }

    private static func exists(parent: Int32, name: String) -> Bool {
        var status = stat()
        return fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0
    }

    /// "report.pdf" → "report 2.pdf" → "report 3.pdf", matching Finder's
    /// "Keep Both" naming.
    private static func uniqueName(parent: Int32, name: String) throws -> String {
        let nsName = name as NSString
        let base = nsName.deletingPathExtension
        let extensionPart = nsName.pathExtension
        let hasExtension = !extensionPart.isEmpty && base != name

        for index in 2...9999 {
            let candidate: String
            if hasExtension {
                candidate = "\(base) \(index).\(extensionPart)"
            } else {
                candidate = "\(name) \(index)"
            }
            if !exists(parent: parent, name: candidate) {
                return candidate
            }
        }
        throw POSIXFailure(operation: "find unused name", errorNumber: EEXIST, relativePath: name)
    }
}
