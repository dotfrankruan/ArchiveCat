//
//  FileInspector.swift
//  ArchiveCore
//
//  Lightweight content identification for the inspector.
//
//  This deliberately does not try to be `file(1)`. It reads a small header and
//  recognises the handful of things technical users actually look for in an
//  archive: Mach-O executables and their architectures, ELF objects, static and
//  dynamic libraries, plists, JSON, scripts and plain text.
//
//  Everything here is a pure function over bytes, so it is fast, testable, and
//  safe to call on untrusted input.
//

import Foundation

/// What a file appears to be.
public enum FileKind: String, Sendable, Codable {
    case machOExecutable
    case machODynamicLibrary
    case machOObject
    case machOUniversalBinary
    case elfExecutable
    case elfSharedObject
    case elfRelocatable
    case staticLibrary
    case zipArchive
    case tarArchive
    case sevenZipArchive
    case gzipArchive
    case bzip2Archive
    case xzArchive
    case zstdArchive
    case sqliteDatabase
    case diskImage
    case pdfDocument
    case image
    case propertyList
    case json
    case xml
    case script
    case text
    case binary
    case empty
    case unknown

    public var localizedName: String {
        switch self {
        case .machOExecutable: return "Mach-O executable"
        case .machODynamicLibrary: return "Mach-O dynamic library"
        case .machOObject: return "Mach-O object file"
        case .machOUniversalBinary: return "Universal Mach-O binary"
        case .elfExecutable: return "ELF executable"
        case .elfSharedObject: return "ELF shared object"
        case .elfRelocatable: return "ELF object file"
        case .staticLibrary: return "Static library"
        case .zipArchive: return "ZIP archive"
        case .tarArchive: return "Tar archive"
        case .sevenZipArchive: return "7-Zip archive"
        case .gzipArchive: return "Gzip archive"
        case .bzip2Archive: return "Bzip2 archive"
        case .xzArchive: return "XZ archive"
        case .zstdArchive: return "Zstandard archive"
        case .sqliteDatabase: return "SQLite database"
        case .diskImage: return "Disk image"
        case .pdfDocument: return "PDF document"
        case .image: return "Image"
        case .propertyList: return "Property list"
        case .json: return "JSON"
        case .xml: return "XML"
        case .script: return "Executable script"
        case .text: return "Plain text"
        case .binary: return "Binary data"
        case .empty: return "Empty file"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbol for the inspector badge.
    public var symbolName: String {
        switch self {
        case .machOExecutable, .elfExecutable: return "gearshape.2"
        case .machODynamicLibrary, .elfSharedObject: return "shippingbox"
        case .machOObject, .elfRelocatable, .staticLibrary: return "square.stack.3d.up"
        case .machOUniversalBinary: return "square.stack.3d.up.fill"
        case .zipArchive, .tarArchive, .sevenZipArchive, .gzipArchive, .bzip2Archive, .xzArchive, .zstdArchive:
            return "archivebox"
        case .sqliteDatabase: return "cylinder"
        case .diskImage: return "externaldrive"
        case .pdfDocument: return "doc.richtext"
        case .image: return "photo"
        case .propertyList, .xml: return "chevron.left.forwardslash.chevron.right"
        case .json: return "curlybraces"
        case .script: return "terminal"
        case .text: return "doc.text"
        case .binary: return "doc.zipper"
        case .empty: return "doc"
        case .unknown: return "questionmark.square.dashed"
        }
    }
}

/// A CPU architecture found inside a Mach-O file.
public struct MachOArchitecture: Sendable, Hashable, Codable {
    /// `arm64`, `arm64e`, `x86_64`, …
    public let name: String
    public let cpuType: UInt32
    public let cpuSubtype: UInt32

    public init(name: String, cpuType: UInt32, cpuSubtype: UInt32) {
        self.name = name
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
    }
}

/// The result of inspecting a file header.
public struct FileInspection: Sendable, Hashable {
    public let kind: FileKind
    /// Architectures, for Mach-O binaries.
    public let architectures: [MachOArchitecture]
    /// One-line detail, e.g. "Mach-O 64-bit, 2 architectures".
    public let detail: String?
    /// How many bytes were examined.
    public let bytesExamined: Int

    public init(kind: FileKind, architectures: [MachOArchitecture] = [], detail: String? = nil, bytesExamined: Int) {
        self.kind = kind
        self.architectures = architectures
        self.detail = detail
        self.bytesExamined = bytesExamined
    }
}

public enum FileInspector {

    /// Inspects a header. `fileName` is only used as a tie-breaker for text
    /// formats whose magic bytes are ambiguous.
    public static func inspect(head: Data, fileName: String? = nil) -> FileInspection {
        let bytes = [UInt8](head.prefix(4096))
        let examined = bytes.count

        guard examined > 0 else {
            return FileInspection(kind: .empty, bytesExamined: 0)
        }

        if let magics = inspectArchiveMagic(bytes) {
            return FileInspection(kind: magics, bytesExamined: examined)
        }

        if let machO = inspectMachO(bytes) {
            return FileInspection(
                kind: machO.kind,
                architectures: machO.architectures,
                detail: machODetail(machO),
                bytesExamined: examined
            )
        }

        if let elf = inspectELF(bytes) {
            return FileInspection(kind: elf, bytesExamined: examined)
        }

        if bytes.starts(with: Array("!<arch>\n".utf8)) {
            return FileInspection(kind: .staticLibrary, bytesExamined: examined)
        }

        if bytes.starts(with: Array("SQLite format 3\0".utf8)) {
            return FileInspection(kind: .sqliteDatabase, bytesExamined: examined)
        }

        if bytes.starts(with: Array("%PDF".utf8)) {
            return FileInspection(kind: .pdfDocument, bytesExamined: examined)
        }

        if let image = inspectImage(bytes) {
            return FileInspection(kind: image, bytesExamined: examined)
        }

        let kind = inspectTextual(bytes)
        return FileInspection(kind: kind, bytesExamined: examined)
    }

    // MARK: - Archives

    private static func inspectArchiveMagic(_ bytes: [UInt8]) -> FileKind? {
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            return .zipArchive
        }
        if bytes.starts(with: [0x1F, 0x8B]) { return .gzipArchive }
        if bytes.starts(with: [0x42, 0x5A, 0x68]) { return .bzip2Archive }
        if bytes.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xzArchive }
        if bytes.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { return .zstdArchive }
        if bytes.count >= 262, bytes[257...261].elementsEqual(Array("ustar".utf8)) { return .tarArchive }
        if bytes.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZipArchive }
        // Apple disk images and ISO 9660 both start with a recognisable marker.
        if bytes.count > 32774, bytes[32769...32773].elementsEqual(Array("CD001".utf8)) { return .diskImage }
        if bytes.starts(with: Array("koly".utf8)) { return .diskImage }
        return nil
    }

    // MARK: - Mach-O

    struct MachOResult {
        let kind: FileKind
        let architectures: [MachOArchitecture]
        let is64Bit: Bool
    }

    static func inspectMachO(_ bytes: [UInt8]) -> MachOResult? {
        guard bytes.count >= 4 else { return nil }

        // A Mach-O magic is written in the file's own byte order, so reading it
        // both ways tells us both what the file is and how to read the rest of
        // the header. A universal ("fat") binary always uses a big-endian header.
        let asLittleEndian = readUInt32(bytes, 0, littleEndian: true)
        let asBigEndian = readUInt32(bytes, 0, littleEndian: false)

        switch (asLittleEndian, asBigEndian) {
        case (0xFEED_FACF, _), (0xFEED_FACE, _):
            return thinMachO(bytes, littleEndian: true)
        case (_, 0xFEED_FACF), (_, 0xFEED_FACE):
            return thinMachO(bytes, littleEndian: false)
        case (_, 0xCAFE_BABE), (_, 0xCAFE_BABF):
            return fatMachO(bytes, is64Bit: asBigEndian == 0xCAFE_BABF)
        default:
            return nil
        }
    }

    private static func thinMachO(_ bytes: [UInt8], littleEndian: Bool) -> MachOResult {
        let is64Bit = readUInt32(bytes, 0, littleEndian: littleEndian) == 0xFEED_FACF
        let cpuType = readUInt32(bytes, 4, littleEndian: littleEndian)
        let cpuSubtype = readUInt32(bytes, 8, littleEndian: littleEndian)
        let fileType = bytes.count >= 16 ? readUInt32(bytes, 12, littleEndian: littleEndian) : 0

        return MachOResult(
            kind: machOKind(fileType: fileType),
            architectures: [MachOArchitecture(
                name: cpuName(cpuType, cpuSubtype),
                cpuType: cpuType,
                cpuSubtype: cpuSubtype
            )],
            is64Bit: is64Bit
        )
    }

    private static func fatMachO(_ bytes: [UInt8], is64Bit: Bool) -> MachOResult? {
        let count = Int(readUInt32(bytes, 4, littleEndian: false))
        guard count > 0, count <= 64 else { return nil }

        // fat_header is 8 bytes; fat_arch is 20, fat_arch_64 is 32.
        let archSize = is64Bit ? 32 : 20
        var architectures: [MachOArchitecture] = []
        architectures.reserveCapacity(count)

        for index in 0..<count {
            let offset = 8 + index * archSize
            guard offset + 8 <= bytes.count else { break }
            let cpuType = readUInt32(bytes, offset, littleEndian: false)
            let cpuSubtype = readUInt32(bytes, offset + 4, littleEndian: false)
            architectures.append(MachOArchitecture(
                name: cpuName(cpuType, cpuSubtype),
                cpuType: cpuType,
                cpuSubtype: cpuSubtype
            ))
        }

        return MachOResult(kind: .machOUniversalBinary, architectures: architectures, is64Bit: is64Bit)
    }

    private static func machOKind(fileType: UInt32) -> FileKind {
        switch fileType {
        case 0x1: return .machOObject      // MH_OBJECT
        case 0x2: return .machOExecutable  // MH_EXECUTE
        case 0x6: return .machODynamicLibrary // MH_DYLIB
        case 0x8: return .machODynamicLibrary // MH_BUNDLE
        default: return .machOExecutable
        }
    }

    private static func machODetail(_ result: MachOResult) -> String {
        // A universal binary's "is64Bit" refers to the fat_arch layout, not to
        // the slices, so it is only mentioned for thin files.
        let bits = result.is64Bit ? "64-bit" : "32-bit"
        let architectureCount = result.architectures.count
        if result.architectures.isEmpty {
            return "Mach-O \(bits)"
        }
        let names = result.architectures.map(\.name).joined(separator: ", ")
        if architectureCount == 1 {
            return "Mach-O \(bits) • \(names)"
        }
        return "Mach-O universal • \(architectureCount) architectures • \(names)"
    }

    /// `arm64`, `arm64e`, `x86_64`, `i386`, `ppc`, …
    static func cpuName(_ cpuType: UInt32, _ cpuSubtype: UInt32) -> String {
        // CPU_TYPE_* constants, from <mach/machine.h>.
        switch cpuType {
        case 0x0100000C:
            // arm64e is a subtype of arm64, not a separate CPU type.
            return (cpuSubtype & 0x00FF_FFFF) == 2 ? "arm64e" : "arm64"
        case 0x0200000C:
            return "arm64_32"
        case 0x01000007:
            return "x86_64"
        case 0x00000007:
            return "i386"
        case 0x0000000C:
            return "arm"
        case 0x00000012:
            return "ppc"
        case 0x01000012:
            return "ppc64"
        default:
            return String(format: "cpu 0x%08x", cpuType)
        }
    }

    // MARK: - ELF

    static func inspectELF(_ bytes: [UInt8]) -> FileKind? {
        guard bytes.count >= 18,
              bytes[0] == 0x7F, bytes[1] == 0x45, bytes[2] == 0x4C, bytes[3] == 0x46
        else { return nil }

        // e_type at offset 16, endianness from byte 5.
        let littleEndian = bytes[5] == 1
        let type = readUInt16(bytes, 16, littleEndian: littleEndian)
        switch type {
        case 1: return .elfRelocatable
        case 2: return .elfExecutable
        case 3: return .elfSharedObject
        default: return .elfExecutable
        }
    }

    // MARK: - Images

    private static func inspectImage(_ bytes: [UInt8]) -> FileKind? {
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .image }
        if bytes.starts(with: Array("GIF8".utf8)) { return .image }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .image }
        if bytes.starts(with: Array("BM".utf8)) { return .image }
        if bytes.count >= 12, bytes[4...11].elementsEqual(Array("ftyp".utf8)) { return .image }
        return nil
    }

    // MARK: - Textual formats

    static func inspectTextual(_ bytes: [UInt8]) -> FileKind {
        // A shebang makes it an executable script, whatever the language.
        if bytes.starts(with: Array("#!".utf8)) { return .script }

        // A binary heuristic: a NUL byte in the first 4 KiB is the classic
        // signal, and it is right far more often than it is wrong.
        if bytes.contains(0) { return .binary }

        guard let text = String(bytes: bytes, encoding: .utf8) else { return .binary }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text }

        // Property lists come in XML and binary flavours. The binary one is
        // checked first because it does not look like text at all.
        if trimmed.hasPrefix("bplist00") { return .propertyList }

        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<!DOCTYPE") || trimmed.hasPrefix("<plist") {
            // A property list is XML with a recognisable root element.
            if trimmed.contains("<plist") { return .propertyList }
            return .xml
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if looksLikeJSON(trimmed) { return .json }
        }
        return .text
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        // Cheap shape check rather than a full parse: balance the delimiters
        // and require something that JSON must contain — a key separator, a
        // string, or an element separator (so `[1, 2, 3]` counts).
        guard text.count > 1 else { return false }
        let hasJSONPunctuation = text.contains(":") || text.contains("\"") || text.contains(",")
        guard hasJSONPunctuation else { return false }
        let opens = text.filter { $0 == "{" || $0 == "[" }.count
        let closes = text.filter { $0 == "}" || $0 == "]" }.count
        return opens > 0 && opens == closes
    }

    // MARK: - Byte helpers

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int, littleEndian: Bool) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        let value = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        if littleEndian { return value }
        return value.byteSwapped
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int, littleEndian: Bool) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        if littleEndian { return value }
        return value.byteSwapped
    }
}
