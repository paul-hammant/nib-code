#!/bin/sh
set -eu

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
    Linux/x86_64|Linux/amd64) platform=x86_64-linux ;;
    Linux/aarch64|Linux/arm64) platform=aarch64-linux ;;
    Darwin/x86_64) platform=x86_64-macos ;;
    Darwin/arm64) platform=aarch64-macos ;;
    *) fail "Unsupported platform: $os/$arch" ;;
esac

base=https://github.com/yyydddkkk/nib-code/releases/latest/download
if [ -n "${NIB_VERSION:-}" ]; then
    base="https://github.com/yyydddkkk/nib-code/releases/download/v${NIB_VERSION#v}"
fi
base=${NIB_DOWNLOAD_BASE:-$base}
asset=nib-$platform.tar.gz
work=$(mktemp -d)
stage=
trap 'rm -rf "$work"; [ -z "$stage" ] || rm -f "$stage"' 0
trap 'exit 1' HUP INT TERM

download() {
    case "$base" in
        file://*) cp "${base#file://}/$1" "$work/$1" ;;
        *)
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL "$base/$1" -o "$work/$1"
            elif command -v wget >/dev/null 2>&1; then
                wget -q "$base/$1" -O "$work/$1"
            else
                fail "Install curl or wget."
            fi
            ;;
    esac
}

download "$asset"
if [ "${NIB_SKIP_VERIFY:-}" != 1 ]; then
    download SHA256SUMS
    expected=$(awk -v name="$asset" '$2 == name { print $1 }' "$work/SHA256SUMS")
    [ "${#expected}" -eq 64 ] || fail "Missing or invalid checksum: $asset"
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$work/$asset")
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$work/$asset")
    else
        fail "Install sha256sum or shasum, or set NIB_SKIP_VERIFY=1."
    fi
    [ "${actual%% *}" = "$expected" ] || fail "Checksum mismatch: $asset"
fi

tar -xzf "$work/$asset" -C "$work" nib
install_dir=${NIB_INSTALL_DIR:-$HOME/.local/bin}
mkdir -p "$install_dir"
stage=$(mktemp "$install_dir/.nib.XXXXXX")
cp "$work/nib" "$stage"
chmod 755 "$stage"
mv -f "$stage" "$install_dir/nib"
stage=
"$install_dir/nib" --version
case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) printf 'Add to PATH: export PATH="%s:$PATH"\n' "$install_dir" ;;
esac
