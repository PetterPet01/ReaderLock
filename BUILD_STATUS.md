# Build status

Date: 2026-09-30
Release candidate: 0.1.4
Target: iPhone 7 (A10 / arm64), iOS 15.x, Dopamine rootless / ElleKit.

## What changed from 0.1.3

Reader Lock no longer enables Airplane Mode or turns Wi-Fi and Bluetooth off. A recovery snapshot left by 0.1.3 is still restored once when SpringBoard loads. The kiosk can open either Apple Books (`com.apple.iBooks`) or MapleRead SE (`com.maplepop.bmsea`). The Control Center button "Use Maple" chooses before entry: highlighted means MapleRead, not highlighted means Books. The default, when that choice has never been saved, is MapleRead. The reader dylib injects into both apps.

0.1.3's lock-screen behavior is unchanged: Home is passed through while locked, while the cover sheet is visible, and during exit authentication, and launches are not redirected to the reader in that window.

## What a local Theos build checks

`make clean package FINALPACKAGE=1` with Theos, the L1ghtmann iOS toolchain, and the iPhoneOS 15.6 SDK produces:

`packages/com.quan.readerlock_0.1.4_iphoneos-arm64.deb`

`scripts/verify-deb.sh` then checks that package:

- Debian architecture `iphoneos-arm64` (rootless), version 0.1.4
- `ReaderLockSB.dylib` and `ReaderLockBooks.dylib` are arm64 Mach-O and have `LC_CODE_SIGNATURE`
- the Mono, Color, and Use Maple Control Center bundles are present and signed the same way
- every data-archive path is under `/var/jb`
- `postinst` is executable and force-kills a suspended Books or MapleRead SE process

That is a static package check. It does not run the README's device procedure, and no iPhone was attached for this build. Private SpringBoard selectors can still be wrong on a specific iOS 15.x build. MapleRead has to be installed as `com.maplepop.bmsea`; a signer that rewrites that bundle id will not match.

## Reproducible binary build

GitHub Actions (`.github/workflows/build.yml`) installs the same pinned toolchain and iPhoneOS 15.6 SDK on `ubuntu-24.04`, runs `make package FINALPACKAGE=1`, runs `scripts/verify-deb.sh`, and uploads the `.deb`. A respring is still required after install. A hard reboot drops tweak enforcement. 0.1.4 does not change radios, so a reboot does not need to restore them. A leftover 0.1.3 snapshot is still only consumed when the tweak actually loads.
