//
//  shim.h
//  ArchiveCat
//
//  The single place where libarchive's C headers enter the project.
//  Everything above `Sources/ArchiveCore/LibArchiveBridge` speaks Swift.
//
//  No declarations are added here on purpose: the vendored header version and
//  the linked dylib version must always agree, and writing our own prototypes
//  for libarchive is a good way to get an ABI mismatch at runtime.
//

#ifndef ARCHIVECAT_C_ARCHIVE_SHIM_H
#define ARCHIVECAT_C_ARCHIVE_SHIM_H

#include <archive.h>
#include <archive_entry.h>

/// libarchive's build-time version as a single integer, e.g. 3008009 for 3.8.9.
#define ARCHIVECAT_LIBARCHIVE_VERSION_NUMBER ARCHIVE_VERSION_NUMBER

/// libarchive's build-time version as a human readable string.
#define ARCHIVECAT_LIBARCHIVE_VERSION_STRING ARCHIVE_VERSION_STRING

/// The same two values as real symbols, from `archivecat_shim.c`. Having them
/// as functions (rather than only as macros) means the header version is
/// available at link time, so a header/library mismatch can be detected instead
/// of silently producing an ABI mess.
int archivecat_libarchive_header_version(void);
const char *archivecat_libarchive_header_version_string(void);

#endif /* ARCHIVECAT_C_ARCHIVE_SHIM_H */
