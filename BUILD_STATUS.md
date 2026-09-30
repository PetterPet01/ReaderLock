# Build status

Date: 2026-09-30
Release candidate: 0.1.2
Target: iPhone 7 (A10 / arm64), iOS 15.x, Dopamine rootless / ElleKit.

## What a local Theos build checked

`make clean package FINALPACKAGE=1` with Theos, the L1ghtmann iOS toolchain, and the iPhoneOS 15.6 SDK produced:

`packages/com.quan.readerlock_0.1.2_iphoneos-arm64.deb`

`scripts/verify-deb.sh` then checked that package:

- Debian architecture `iphoneos-arm64` (rootless), version 0.1.2
- `ReaderLockSB.dylib` and `ReaderLockBooks.dylib` are arm64 Mach-O and have `LC_CODE_SIGNATURE`
- both Control Center bundles are present and signed the same way
- every data-archive path is under `/var/jb`
- `postinst` is executable and still only force-kills a suspended Books process

That is a static package check. It does not run the README's 18-step procedure, and no iPhone was attached. Private SpringBoard selectors can still be wrong on a specific iOS 15.x build.

## Reproducible binary build

GitHub Actions (`.github/workflows/build.yml`) installs the same pinned toolchain and iPhoneOS 15.6 SDK on `ubuntu-24.04`, runs `make package FINALPACKAGE=1`, runs `scripts/verify-deb.sh`, and uploads the `.deb`. A respring is still required after install. A hard reboot drops tweak enforcement, but Airplane Mode, Wi-Fi, and Bluetooth are persistent settings and are not restored by the reboot itself.
