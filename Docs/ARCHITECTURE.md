# ArchiveCat architecture

This document records the layering, the invariants that must not regress, and
the two independent responsibilities of the application.

It is the reference for the 2.0 work (virtual archive filesystem, nested
archives, on-demand content access, archive creation). It supersedes earlier
roadmap notes that mentioned archive modification: **ArchiveCat never edits an
existing archive.** That is a permanent product decision, not a deferred
feature.

---

## 1. Two responsibilities, one app

| | **ArchiveReader** | **ArchiveCreator** |
|---|---|---|
| Input | an existing archive file | files and directories on disk |
| Output | metadata, previews, extracted files | a *new* archive file |
| Can touch the input archive? | read only, never write | not applicable — the inputs are ordinary files |
| Engine | `ArchiveSession`, `ArchiveFileSystem`, `NestedArchiveStore` | `CompressionPlanner`, `CompressionService`, `LibArchiveWriter` |

The two sides share only low-level, direction-neutral utilities: path
validation (`ArchivePath`), typed errors (`ArchiveError`), logging, formatting
and the libarchive bridge. They never share a "session" object, and there is no
mode in which a reader becomes writable.

Consequences that are visible in the code:

* `ArchiveReading` and `ArchiveFileSystem` expose no write, delete, rename or
  mutate operation.
* There is no `canModify` capability, no copy-on-write overlay, no edit
  transaction and no "save" path. `ArchiveDocumentFile.data(ofType:)` throws.
* Including an existing archive as one *input file* when creating a new archive
  is ordinary file reading; it is unrelated to modifying that archive.

---

## 2. Layers

```
ArchiveCat (AppKit + SwiftUI)
  App/          NSDocument, NSDocumentController, menus, lifecycle
  Models/       BrowserViewModel — navigation, levels, selection, extraction
  UI/           SwiftUI views + one NSTableView
  Utilities/    coordinators: extraction conflicts, compression, drag
──────────────────────────────────────────────────────────────────
ArchiveCore (no AppKit, no SwiftUI)
  Capabilities/      what a format/session can and cannot do
  Reading/           libarchive read bridge, scanner, session, path safety
  VirtualFileSystem/ ArchiveFileSystem + ArchiveNode + single-entry access
  Nested/            nested archive materialisation, limits, cache
  Tree/ Models/      virtual directory tree, entries, summary
  Extraction/        secure streaming extraction (openat/O_NOFOLLOW)
  Preview/           single-entry preview cache
  Writing/           libarchive write bridge, planner, compression service
  Inspection/        content identification from a header
──────────────────────────────────────────────────────────────────
CArchive (thin C shim; the only importer of <archive.h>)
```

`ArchiveCore` has no dependency on AppKit. The app is the only place that knows
about panels, sheets, windows and Quick Look.

---

## 3. Virtual archive filesystem

`ArchiveFileSystem` is a **read-only, in-memory view** over one scanned
`ArchiveDocument`. It does not mount anything, does not create a kernel
filesystem, and owns no file handles of its own.

* **Identity is the entry, not the path.** Archives legitimately contain the
  same path twice; `ArchiveEntryID` is the ordinal, so `node.path` is for
  display and navigation while `entry.id` is the stable identity. Duplicate
  paths remain distinct rows.
* **Directories may be implicit.** A directory that the archive never stored
  gets a synthetic node (`ArchiveNode.isImplicitDirectory == true`) carrying no
  entry metadata, exactly like Finder showing a folder the tar format omitted.
* **Unsafe entries are not in the tree.** Entries rejected by `ArchivePath`
  (traversal, absolute paths, NUL bytes, over-long components) are reported in
  `ArchiveDocument.unsafeEntries` and never appear in `tree`. Extraction
  refuses them independently of the UI.
* **Paths never authorize anything.** A virtual path is a lookup key into
  already-validated metadata. Every write path re-validates with
  `ExtractionPreflight.relativePath(for:)` and writes descriptor-relative in
  `SecureDestination`; the filesystem is never trusted to enforce archive
  semantics.
* **Deterministic ordering.** Children are listed in archive order:
  subdirectories first (first-seen order), then file entries, with explicit
  directory entries represented once by their directory node.

### Content access

Reading one member is a separate, bounded operation from extraction:

| Operation | API | Cost |
|---|---|---|
| read a bounded prefix into memory | `ArchiveSession.readEntryData(_:maxBytes:)` | one streaming pass to the ordinal |
| materialise one member to a file | `ArchiveSession.extract(entries:to:options:)` with one entry | one streaming pass |
| preview | `ArchiveSession.materializeForPreview(entry:)` | as above, cached |
| enumerate children | `ArchiveFileSystem.children(ofDirectoryAt:)` | O(children), no I/O |

`ArchiveCapabilities.supportsRandomAccess` is true only for containers that are
genuinely seekable *and* not wrapped in a sequential filter (ZIP, 7z, RAR, TAR,
CPIO, ISO, XAR without an outer compressor). For gzip/bzip2/xz/zstd streams a
targeted read is still a **linear scan**, which the UI must not describe as
instant. The scan of the archive happens once, up front, and is not repeated for
browsing; per-member reads do repeat it, so they are bounded and cached where
the user will notice (previews).

---

## 4. Capability model

One type, `ArchiveCapabilities`, describes what the engine can actually do with
a format/session. It is derived from the libarchive format/filter codes for
reading and from the writer's own probe for creation.

Rules:

* Reading capability never implies creation capability. `ArchiveFormatCatalog`
  lists creatable formats explicitly and probes each filter at runtime.
* The UI enables actions from the capability values, not from
  `format == .zip`-style checks scattered through view controllers.
* There is deliberately no modification capability.
* `supportsCompressionLevel` and `compressionLevelRange` come from the format
  descriptor; the compression sheet disables the level control when the range is
  `nil`.

---

## 5. Nested archives

A nested archive is an **entry** that happens to be an archive. Opening it does
not extract the parent archive and does not modify it.

Flow:

1. The entry's content is validated (magic bytes via `FileInspector`, then a
   real `LibArchiveScanner` scan of the materialised file).
2. `NestedArchiveStore` streams exactly that member into a bounded temporary
   file under the app's cache directory. The parent archive is never written.
3. A new `ArchiveSession` is opened on the temporary file; the browser pushes a
   new **level** and keeps the parent level alive.
4. Back/Enclosing Folder pop the level; the parent level keeps its own
   remembered directory and selection.

Limits (all configurable, defaults in `NestedArchiveOptions`):

| Limit | Default | Enforced by |
|---|---|---|
| maximum nesting depth | 4 | store, before materialising |
| maximum nested member size | 2 GiB | declared-size pre-check + `ExtractionLimits.maximumSingleEntryBytes` during extraction |
| total temporary storage | 4 GiB | store, after each materialisation (LRU eviction of unreferenced files first) |
| maximum age | 24 h | `purgeExpired()` |
| materialisation must be streamed | — | `ExtractionService` streams; nothing is buffered in RAM |

A level **pins** its materialised file: pinned files are never evicted while the
level is open, which is what protects an active Quick Look preview. Released
files stay cached for reuse until budget pressure or age removes them.

Failure handling: encrypted, corrupt, unsupported and over-limit nested archives
surface their existing typed `ArchiveError`; the browser stays on the parent
level and reports the problem.

---

## 6. Archive creation

### Pipeline

```
sources ─► CompressionPlanner.plan()    one metadata pass, fail fast, no writes
        ─► LibArchiveWriter            temp file in the destination directory
        ─► commit                      fsync, rename(2)/renameatx_np(RENAME_EXCL)
```

`ArchiveFormatCatalog` lists the output formats explicitly — ZIP, TAR, TAR.GZ,
TAR.BZ2, TAR.XZ, TAR.ZST — and filters that list through
`LibArchiveWriter.probe` at runtime, so a libarchive built without a filter
simply does not offer that format.

The **planner** normalises the selection before any byte is written:

* overlapping selections collapse (a child of a selected directory is dropped);
* each top-level source contributes its own name as the top archive path;
  absolute paths and home-directory prefixes never reach the archive;
* duplicate top-level basenames are disambiguated Finder-style (`name`,
  `name 2`) and reported as a warning;
* directory trees are walked with `lstat` semantics: **symlinks are stored as
  symlinks and never followed**, so a link to `../../etc` cannot cause a read
  outside the selected tree and cannot create a traversal loop;
* empty directories are kept;
* metadata (mode, mtime, uid/gid) is captured, and is preserved where the
  container supports it (tar fully; ZIP stores Unix modes and DOS timestamps);
* every source is `stat`ed and opened only later, by the writer; a file that
  cannot be read, shrinks while being read, or disappears aborts the operation
  with the specific path in the error rather than producing a "successful"
  incomplete archive.

### Atomic output and collisions

* The writer never writes to the destination path. It writes
  `.<name>.<uuid>.partial` in the destination directory, refusing to start if
  that name already exists.
* On success: `fsync` the file, `rename(2)` it onto the destination. Rename
  within one directory is atomic, so a reader sees either the old complete file
  or the new complete file, never a partial one.
* On failure or cancellation: close, then unlink the temporary file. The
  destination is untouched.
* An existing destination is never replaced silently. `CompressionOptions`
  requires `overwriteExisting == true`, which the UI only sets after the user
  confirms replacement in the standard save panel. When it is `false` and the
  destination exists, the operation fails before writing.
* Durability note: the file is fsynced before the rename; the directory entry is
  not fsynced, so a machine crash immediately after the rename could still lose
  the name. The previous file cannot be destroyed by a failed replace.

### What is not implemented

* No editing or rewriting of existing archives (permanent design decision).
* No Finder extension; compression is driven from the app's own panels.
* No external binaries: `zip`, `tar` and friends are never executed.

---

## 7. Security invariants

These hold across both responsibilities and are covered by tests:

1. Archive-relative paths are normalised and validated before use; `..`,
   absolute paths, NUL bytes and over-long components are rejected.
2. No entry can escape its extraction or materialisation root: writes are
   descriptor-relative with `openat(O_NOFOLLOW)`, `mkdirat`, `symlinkat`.
3. Symlinks are created only when their target resolves inside the extraction
   root; special files are not created by default; setuid/setgid bits are
   stripped.
4. Compression never follows symlinks and never reads outside the selected
   source tree.
5. Untrusted metadata cannot cause unbounded allocation: decompression limits,
   bounded caches, bounded single-entry reads, bounded nested materialisation.
6. Cancellation releases descriptors and temporary files and leaves the engine
   reusable.
7. A failed compression never leaves a partial file at the destination.
8. Nothing is uploaded anywhere; no networking, telemetry, cloud or AI APIs.
9. Security checks live in the layer that performs the I/O, not only in the UI.

---

## 8. Performance characteristics

Measured on Apple Silicon, macOS 27.0.1, libarchive 3.8.9, **debug build**:

| Operation | Result |
| --- | --- |
| Scan 20 200-entry TAR (20.6 MB) | 0.12 s, repeatable |
| 1 000 root listings (200 subdirectories) | 0.07 s (≈70 µs each) |
| 1 000 directory lookups | 0.0004 s (≈0.4 µs each) |
| ZIP 32 MiB incompressible | 0.46 s, 33.6 MB |
| ZIP / TAR.GZ 35.2 MB text | 0.06 s, 103 kB |
| Nested open, first / cached | 0.9 ms / 0.06 ms |

Structural reasons, not just numbers:

* Browsing performs **no member decompression**: a scan reads headers only
  (`archive_read_data_skip`).
* Directory listing goes through the tree's dictionary plus its child arrays; it
  never walks the whole entry list. `ArchiveFileSystemTests` asserts a bounded
  time for 500 listings and lookups in a 2 100-entry archive as a regression
  guard.
* Single-member reads are a linear pass to the member (libarchive has no member
  index to seek with) and are capped while streaming; previews and nested
  archives are therefore cached rather than re-read.
* Preview and nested caches are bounded and LRU-evicted, with live levels
  pinned by reference count.
* Compression streams in 256 KiB blocks; peak memory does not scale with file
  size.

---

## 9. Non-goals

* Editing archives, in any form.
* Mounting archives as a volume (no FUSE, no File Provider extension).
* A web UI or a cross-platform shell.
* Network features of any kind.
