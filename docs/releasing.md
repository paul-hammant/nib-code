# Releasing

1. Bump `.version` in `build.zig.zon`.
2. Write the English release notes in `docs/releases/<version>.md`.
3. Commit and push the changes, then push tag `v<version>` on that commit.

The release workflow checks the tag against the package version, builds stripped Linux (static musl) and macOS binaries for x86_64 and arm64, and tests the installer on each platform before publishing the release as latest. Assets contain just `nib`; `SHA256SUMS` covers all four archives. Re-running the workflow replaces assets on an existing release.

The installer verifies SHA-256 by default. `NIB_SKIP_VERIFY=1` disables verification. For local testing, set `NIB_DOWNLOAD_BASE=file:///absolute/path/to/assets` and `NIB_INSTALL_DIR` to a temporary directory.
