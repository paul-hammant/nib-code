# Releasing

1. Bump `.version` in `build.zig.zon`.
2. Write the release notes in `docs/releases/<version>.md`: English first, then `---` and the same notes in Chinese.
3. Commit and push the changes, then push tag `v<version>` on that commit.

The release workflow checks the tag against the package version, builds stripped Linux (static musl, x86_64 and arm64) and macOS (Apple silicon) binaries, and tests the installer on each platform before publishing the release as latest. Assets contain just `nib`; `SHA256SUMS` covers all three archives. Re-running the workflow replaces assets on an existing release.

The installer verifies SHA-256 by default. `NIB_SKIP_VERIFY=1` disables verification. For local testing, set `NIB_DOWNLOAD_BASE=file:///absolute/path/to/assets` and `NIB_INSTALL_DIR` to a temporary directory.

`nib update [version]` uses the same release assets and checksum verification as the installer, replacing the executable in place. It honors `NIB_DOWNLOAD_BASE` and `NIB_SKIP_VERIFY=1`. HTTP and HTTPS proxies use the standard HTTP client environment settings. Updates run only on request.
