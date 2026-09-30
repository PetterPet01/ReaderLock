#!/usr/bin/env bash
# Statically check the rootless package. This does not validate private APIs on a device.
set -euo pipefail

cd "$(dirname "$0")/.."

shopt -s nullglob
debs=(packages/*.deb)
if [[ ${#debs[@]} -ne 1 ]]; then
  echo "expected exactly one packages/*.deb, found ${#debs[@]}" >&2
  printf '  %s\n' "${debs[@]}" >&2
  exit 1
fi
deb="${debs[0]}"

arch="$(dpkg-deb -f "$deb" Architecture)"
if [[ "$arch" != "iphoneos-arm64" ]]; then
  echo "Architecture is '$arch', expected iphoneos-arm64" >&2
  exit 1
fi

version="$(dpkg-deb -f "$deb" Version)"
if [[ "$version" != "0.1.5" ]]; then
  echo "Version is '$version', expected 0.1.5" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
dpkg-deb -x "$deb" "$work/root"
dpkg-deb -e "$deb" "$work/DEBIAN"

require() {
  if [[ ! -e "$1" ]]; then
    echo "missing $1" >&2
    exit 1
  fi
}

sb="$work/root/var/jb/Library/MobileSubstrate/DynamicLibraries/ReaderLockSB.dylib"
books="$work/root/var/jb/Library/MobileSubstrate/DynamicLibraries/ReaderLockBooks.dylib"
mono="$work/root/var/jb/Library/ControlCenter/Bundles/ReaderLockMonoCC.bundle/ReaderLockMonoCC"
color="$work/root/var/jb/Library/ControlCenter/Bundles/ReaderLockColorCC.bundle/ReaderLockColorCC"
app="$work/root/var/jb/Library/ControlCenter/Bundles/ReaderLockAppCC.bundle/ReaderLockAppCC"
require "$sb"
require "$books"
require "$mono"
require "$color"
require "$app"
require "$work/root/var/jb/Library/MobileSubstrate/DynamicLibraries/ReaderLockSB.plist"
require "$work/root/var/jb/Library/MobileSubstrate/DynamicLibraries/ReaderLockBooks.plist"
require "$work/DEBIAN/postinst"
[[ -x "$work/DEBIAN/postinst" ]] || { echo "postinst is not executable" >&2; exit 1; }

# Nothing in the data archive may live outside the rootless prefix.
while IFS= read -r -d '' path; do
  rel="${path#"$work/root"/}"
  case "$rel" in
    var/jb|var/jb/*|var|var/jb) ;;
    *)
      echo "path outside /var/jb: $rel" >&2
      exit 1
      ;;
  esac
done < <(find "$work/root" -mindepth 1 -print0)

objdump=""
if [[ -n "${THEOS:-}" && -x "$THEOS/toolchain/linux/iphone/bin/llvm-objdump" ]]; then
  objdump="$THEOS/toolchain/linux/iphone/bin/llvm-objdump"
elif command -v llvm-objdump >/dev/null 2>&1; then
  objdump="$(command -v llvm-objdump)"
fi
if [[ -z "$objdump" ]]; then
  echo "llvm-objdump not found; set THEOS" >&2
  exit 1
fi

check_macho() {
  local bin="$1"
  local headers
  headers="$("$objdump" --macho --private-headers "$bin")"
  if ! grep -q "LC_CODE_SIGNATURE" <<<"$headers"; then
    echo "no LC_CODE_SIGNATURE in $bin" >&2
    exit 1
  fi
  if ! grep -q "cputype.*ARM64\|ARM64" <<<"$headers"; then
    echo "not an arm64 Mach-O: $bin" >&2
    echo "$headers" >&2
    exit 1
  fi
}

check_macho "$sb"
check_macho "$books"
check_macho "$mono"
check_macho "$color"
check_macho "$app"

sha_file="${deb}.sha256"
sha256sum "$deb" | awk '{print $1}' > "$sha_file"
echo "verified $deb ($arch $version)"
echo "sha256 $(cat "$sha_file")"
