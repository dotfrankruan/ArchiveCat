# Test fixtures

Archive fixtures for the engine test suite.

Most fixtures are generated at test time by `FixtureFactory` (in
`Tests/ArchiveCoreTests/Support/`) using `/usr/bin/zip`, `/usr/bin/bsdtar`,
`/opt/homebrew/bin/7zz` and `zstd`, so the tests stay readable and no binary
blobs need reviewing.

This directory exists so that SwiftPM can copy it as a test resource for the
fixtures that are genuinely easier to check in than to generate (for example a
truncated archive or an archive with deliberately hostile paths).

Currently checked in: nothing. See `FixtureFactory.swift` for the generated set.
