# Build status

Date: 2026-10-01
Release candidate: 0.1.15
Target: iPhone 7 (A10 / arm64), iOS 15.x, Dopamine rootless / ElleKit.

## What changed from 0.1.14

On device, 0.1.14's bottom time line is visible on MapleRead's black theme and disappears on the white theme, because the text was always `secondaryLabelColor` (white while the phone is in dark mode). 0.1.15 picks the line color from the open book's page or progress text, or from the paper luminance, and refreshes it when MapleRead restyles that chrome. Appear methods are still not wrapped. The native top-bar hide is unchanged and still needs device confirmation. This has not been run on a phone.

## What changed from 0.1.13

On device, 0.1.13 opened MapleRead SE, hung on the initialization waiting screen, exited, and opened it again. Wrapping every view controller's `viewWillAppear:` / `viewDidAppear:` with a shared original lookup made a parent and child that both own the method recurse through `super`. 0.1.14 does not wrap those appear methods. Every subclass still answers `prefersStatusBarHidden`, SpringBoard still hides the native bar, and the child status-bar walk is still left alone. The bottom time line is unchanged. This has not been run on a phone.

## What changed from 0.1.12

The native iPhone top status bar (carrier, Wi-Fi, clock, Do Not Disturb, rotation lock, battery) must stay gone the whole time Reader Lock is on, on every screen inside the reader. 0.1.12 still depended on MapleRead's per-screen `prefersStatusBarHidden` and has not been run on a phone. 0.1.13 does not return nil from `childViewControllerForStatusBarHidden`. Every view-controller subclass answers hidden, including classes that never implemented that method. SpringBoard forces the frontmost app scene's status bar hidden using selectors present on both the iOS 14 and iOS 17 dumps, and takes a status-bar assertion when that iOS 14-shaped initializer exists. The bottom time line is unchanged. On device that appear wrap hung MapleRead, which 0.1.14 removes.

## What changed from 0.1.11

On device, 0.1.11 showed the system status bar on every reader screen, including MapleRead's home screen and the open book, where it had stayed hidden. Stopping the status-bar handoff made UIKit ask the tab bar, and the tab bar's answer is visible, so the clock came back and kept being asked for again on each screen. 0.1.12 leaves that handoff in place, still forces every controller that owns the answer to hide the bar, and hides the status-bar view itself when it appears. The bottom time line is unchanged. This has not been run on a phone.

## What changed from 0.1.10

On device, the system status bar stayed hidden on MapleRead's home screen and on an open book, then came back on other panels such as Go to Exchange. Those panels answer the status-bar query themselves, and the tab bar forwards to them. 0.1.11 tried to stop that forwarding. On device that showed the bar everywhere, so 0.1.12 does not.

## What changed from 0.1.9

0.1.9 kept the time line up for the whole Reader Lock session, so it covered MapleRead's home-screen controls. The book screen itself was already right. 0.1.10 hides that line unless the open book is the screen in front. Apple Books still shows it on every screen. This has not been run on a phone.

## What changed from 0.1.8

0.1.8 drew the bottom line and left the library clear, but an open book kept its own grey top strip and the line covered that book's progress text. 0.1.9 hides that reading-only strip, drops its short height constraint, and keeps the progress text above the line. The library is not inset. This has not been run on a phone.

## What changed from 0.1.7

0.1.7 collapsed the status-bar layout but left the bar itself on screen, so a black strip covered the book title, and the bottom line was a full-screen window whose label did not come up. 0.1.8 hides the status bar on the view controllers that actually implement it, including ones compiled with offset type encodings, and draws the line in a 22-point window at the bottom only.

## What changed from 0.1.6

While Reader Lock is on, the reader hides Apple's status bar and shows a touch-through line at the bottom: 24-hour time, Wi-Fi or an em dash, and battery percent. Opening Books or MapleRead while Reader Lock is off does not change the status bar. The line does not reserve space in the page.

## What changed from 0.1.5

Pulling down from the top no longer tracks Notification Center while the reader is unlocked and the cover sheet is not already showing. Pulling up from the bottom no longer tracks Control Center. The first Home click still unlocks. A second click within that unlock is ignored, and a double-click does not open the app switcher. 0.1.5's Powercuff behavior is unchanged.

## What changed from 0.1.4

Once the chosen reader is actually in front, Reader Lock sets Powercuff's `PowerMode` to 4 (Heavy) and `RequireLowPowerMode` to false, posts Powercuff's settings and thermal notifications, and turns on iOS Low Power Mode. The previous values, including a Powercuff key that was absent, are saved first in `/var/mobile/Library/Preferences/com.quan.readerlock.power.plist` and written back on exit or on the next SpringBoard start. If that file cannot be saved, Powercuff and Low Power Mode are left alone and the kiosk still starts. This is not YukiPower Ultra: Choicy's tweak deny list is not touched, and SpringBoard is not restarted. Powercuff is not a package dependency. Wi-Fi and cellular are still not changed.

0.1.4's reader choice and 0.1.3's lock-screen behavior are unchanged.

## What a local Theos build checks

`make clean package FINALPACKAGE=1` with Theos, the L1ghtmann iOS toolchain, and the iPhoneOS 15.6 SDK produces:

`packages/com.quan.readerlock_0.1.15_iphoneos-arm64.deb`

`scripts/verify-deb.sh` then checks that package:

- Debian architecture `iphoneos-arm64` (rootless), version 0.1.15
- `ReaderLockSB.dylib` and `ReaderLockBooks.dylib` are arm64 Mach-O and have `LC_CODE_SIGNATURE`
- the Mono, Color, and Use Maple Control Center bundles are present and signed the same way
- every data-archive path is under `/var/jb`
- `postinst` is executable and force-kills a suspended Books or MapleRead SE process

That is a static package check. It does not run the README's device procedure, and no iPhone was attached for this build. Private SpringBoard selectors can still be wrong on a specific iOS 15.x build. MapleRead has to be installed as `com.maplepop.bmsea`; a signer that rewrites that bundle id will not match.

## Reproducible binary build

GitHub Actions (`.github/workflows/build.yml`) installs the same pinned toolchain and iPhoneOS 15.6 SDK on `ubuntu-24.04`, runs `make package FINALPACKAGE=1`, runs `scripts/verify-deb.sh`, and uploads the `.deb`. A respring is still required after install. A hard reboot drops tweak enforcement. 0.1.5 does not change radios, so a reboot does not need to restore them. A leftover 0.1.3 radio snapshot, and a 0.1.5 power snapshot, are still only consumed when the tweak actually loads. Heavy limits CPU, so the reader can feel slower. It does not turn the radios off.
