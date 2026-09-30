# Build status

Date: 2026-09-30
Release candidate: 0.1.7
Target: iPhone 7 (A10 / arm64), iOS 15.x, Dopamine rootless / ElleKit.

## What changed from 0.1.6

While Reader Lock is on, the reader hides Apple's status bar and shows a touch-through line at the bottom: 24-hour time, Wi-Fi or an em dash, and battery percent. Opening Books or MapleRead while Reader Lock is off does not change the status bar. The line does not reserve space in the page.

## What changed from 0.1.5

Pulling down from the top no longer tracks Notification Center while the reader is unlocked and the cover sheet is not already showing. Pulling up from the bottom no longer tracks Control Center. The first Home click still unlocks. A second click within that unlock is ignored, and a double-click does not open the app switcher. 0.1.5's Powercuff behavior is unchanged.

## What changed from 0.1.4

Once the chosen reader is actually in front, Reader Lock sets Powercuff's `PowerMode` to 4 (Heavy) and `RequireLowPowerMode` to false, posts Powercuff's settings and thermal notifications, and turns on iOS Low Power Mode. The previous values, including a Powercuff key that was absent, are saved first in `/var/mobile/Library/Preferences/com.quan.readerlock.power.plist` and written back on exit or on the next SpringBoard start. If that file cannot be saved, Powercuff and Low Power Mode are left alone and the kiosk still starts. This is not YukiPower Ultra: Choicy's tweak deny list is not touched, and SpringBoard is not restarted. Powercuff is not a package dependency. Wi-Fi and cellular are still not changed.

0.1.4's reader choice and 0.1.3's lock-screen behavior are unchanged.

## What a local Theos build checks

`make clean package FINALPACKAGE=1` with Theos, the L1ghtmann iOS toolchain, and the iPhoneOS 15.6 SDK produces:

`packages/com.quan.readerlock_0.1.7_iphoneos-arm64.deb`

`scripts/verify-deb.sh` then checks that package:

- Debian architecture `iphoneos-arm64` (rootless), version 0.1.7
- `ReaderLockSB.dylib` and `ReaderLockBooks.dylib` are arm64 Mach-O and have `LC_CODE_SIGNATURE`
- the Mono, Color, and Use Maple Control Center bundles are present and signed the same way
- every data-archive path is under `/var/jb`
- `postinst` is executable and force-kills a suspended Books or MapleRead SE process

That is a static package check. It does not run the README's device procedure, and no iPhone was attached for this build. Private SpringBoard selectors can still be wrong on a specific iOS 15.x build. MapleRead has to be installed as `com.maplepop.bmsea`; a signer that rewrites that bundle id will not match.

## Reproducible binary build

GitHub Actions (`.github/workflows/build.yml`) installs the same pinned toolchain and iPhoneOS 15.6 SDK on `ubuntu-24.04`, runs `make package FINALPACKAGE=1`, runs `scripts/verify-deb.sh`, and uploads the `.deb`. A respring is still required after install. A hard reboot drops tweak enforcement. 0.1.5 does not change radios, so a reboot does not need to restore them. A leftover 0.1.3 radio snapshot, and a 0.1.5 power snapshot, are still only consumed when the tweak actually loads. Heavy limits CPU, so the reader can feel slower. It does not turn the radios off.
