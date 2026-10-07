/*
 *  archivecat_shim.c
 *  ArchiveCat
 *
 *  A real translation unit for the `CArchive` target.
 *
 *  The target is otherwise header-only, and SwiftPM will not emit an object
 *  file for a target with no sources, which breaks linking for anything that
 *  depends on it. These functions also give the Swift layer a link-time check
 *  that the header version and the linked library version agree.
 */

#include "shim.h"

int archivecat_libarchive_header_version(void) {
    return ARCHIVE_VERSION_NUMBER;
}

const char *archivecat_libarchive_header_version_string(void) {
    return ARCHIVE_VERSION_STRING;
}
