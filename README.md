# ReaderLock for Dopamine / iOS 15

ReaderLock turns an iPhone into a deliberately dumb ebook reader from Control Center. The reader is Apple Books or MapleRead SE.

This project targets the **iPhone 7 / iOS 15 / Dopamine rootless** case first. It is an engineering release candidate: the source is complete and packageable, but private SpringBoard APIs always require testing on the exact iOS point release before calling a build production-safe.

## User experience

After installation and respring, add these CCSupport modules to Control Center:

- **Use Maple** — highlighted means the next session opens MapleRead SE. Tap it so it is not highlighted to open Apple Books instead. This only changes the choice while Reader Lock is off.
- **Reader Mono** — opens the chosen reader and renders it in grayscale.
- **Reader Color** — opens the chosen reader in normal color.

MapleRead SE is the default when nothing has been chosen yet. Its bundle id is `com.maplepop.bmsea`. One tap on Mono or Color enters the chosen mode. Once active:

- the chosen reader is forced to the foreground, and the other reader is not allowed either;
- attempts to launch another app are redirected to that reader;
- the Home action is eaten and a foreground watchdog re-opens the reader if another route reaches SpringBoard. One Home click still unlocks the iPhone 7. A second click while that unlock is finishing is ignored, so it does not leave the reader and launch it again;
- app switcher presentation is blocked, including a double-click of Home;
- pulling up from the bottom does not open Control Center, and a Control Center that is already opening is dismissed;
- pulling down from the top does not open Notification Center over the reader. The same pull still works on the lock screen, and the side button can still lock;
- queued notification history is hidden on the Lock Screen while Reader Lock is active;
- the Lock Screen Today View is disabled while Reader Lock is active;
- Siri activation is blocked;
- Reachability is blocked;
- screenshots are blocked;
- ordinary BulletinBoard notifications are dropped across both legacy bulletin and newer bulletin-request publication paths;
- ordinary SpringBoard alert items (including normal alarms) are suppressed;
- share sheet, Safari view controller, document picker, Mail/Message composer and Store product UI from the reader are blocked;
- external `openURL:` calls from the reader are denied, including web links. A `file:` URL and, in Apple Books, `ibooks` / `itms-books` are left alone. Downloads made by the reader itself are not `openURL` and still work;
- Airplane Mode, Wi-Fi, and Bluetooth are not changed. Turn on Wi-Fi or cellular before entering if the reader should sync or download. Sign into the reader's account before entering, because a Safari login sheet is still blocked.
- once the reader is in front, Powercuff is set to its Heavy profile and iOS Low Power Mode is turned on. The previous Powercuff mode and Low Power Mode come back on exit, or on the next SpringBoard start if the phone resprings mid-session. Powercuff is optional; without it, only Low Power Mode changes. This does not disable other tweaks and does not respring by itself. Page turns can feel slower. A download the reader starts in the foreground still uses the network; iOS may defer background refresh.
- Apple's status bar is hidden, so the reader can use that space, and nothing of ours is drawn across the book title. A line at the bottom shows the time, the word Wi-Fi when the current route is Wi-Fi, or an em dash otherwise, and the battery percent. It does not receive touches. It is not shown when that reader app is opened outside Reader Lock. The text follows the system light or dark appearance, not the page color, and it floats over the page rather than pushing the text up;

Critical-ish SpringBoard alerts whose class name includes LowPower, Battery, Thermal, Emergency, SOS or Shutdown are allowed through. `InCallService`, CoreAuth UI and passcode UI are on the launch safety allowlist so emergency/authentication infrastructure is not accidentally redirected.

## Exiting Reader Lock

Normal exit is intentionally *not* in Control Center, because Control Center is inaccessible in Reader Lock.

Normal exit has **two independent authenticated triggers**:

- in the reader, hold **two fingers** for **2.5 seconds**; or
- on the iPhone 7, **triple-click the Home button** while Reader Lock is active and the lock screen is not showing.

Either path asks iOS for Touch ID or the device passcode using `LAPolicyDeviceOwnerAuthentication`. On success, ReaderLock disables the firewall first, removes the grayscale filter, and returns to OFF. The SpringBoard/Home-button path exists specifically so exit does not depend on the reader process having received tweak injection.

Fail-safe exit: hold **three fingers for 8 seconds inside the reader**. This skips authentication and exists only to prevent lockout if LocalAuthentication is broken or no device passcode is configured. A reboot is the final physical escape because jailbreak enforcement disappears when SpringBoard is no longer running the tweak.

A SpringBoard restart/respring is fail-open: active Reader Lock is deliberately never restored across SpringBoard startup. A full reboot also removes the kiosk enforcement because tweak injection is gone. Version 0.1.4 and later do not change radios. A recovery snapshot left by 0.1.3 is still restored once, on the next SpringBoard start, because Airplane Mode, Wi-Fi, and Bluetooth are persistent settings and 0.1.3 may have turned them off. A power snapshot from 0.1.5 is restored on that same start, so Powercuff and Low Power Mode do not stay on Heavy after a respring.

## State machine

```
OFF
  | tap Reader Mono / Reader Color
  v
ARMING
  - remember Books or MapleRead for this session
  - dismiss Control Center
  - request that reader (radios are left as they are)
  - confirm that reader is actually foreground
  |
  +-- failure --> EXITING -> OFF
  |
  - snapshot Powercuff and Low Power Mode, then set Powercuff Heavy
  |
  v
MONO or COLOR
  - app launch firewall active
  - system surfaces restricted
  - notifications / ordinary alerts suppressed
  - reader escape UI blocked
  - watchdog keeps that reader foreground
  |
  | authenticated exit / emergency exit
  v
EXITING
  - firewall becomes permissive immediately
  - restore Powercuff and Low Power Mode from this session's snapshot
  - restore a leftover 0.1.3 radio snapshot, if one is still on disk
  - notify the reader to restore rendering
  v
OFF
```

## Why ReaderLock does not programmatically start Apple's Single App Mode

Apple exposes `UIAccessibilityRequestGuidedAccessSession`, but Apple's own documentation says programmatic Single App Mode requires a supervised MDM device and an allow-listed app. A normal personal iPhone is not eligible. ReaderLock therefore implements the required kiosk behavior in the jailbreak layer instead of making an unsupported Guided Access call the foundation of the lock.

You can still enable stock Guided Access manually as an additional independent layer if desired, but ReaderLock does not depend on it.

## Why grayscale is implemented as a reader rendering filter

The public UIKit grayscale API is read-only. ReaderLock therefore does **not** mutate your global Accessibility Color Filters preference. In Mono mode it installs a private CoreAnimation `CAFilter` of type `colorSaturate` with `inputAmount = 0` on each window of the chosen reader and restores that window's previous filters in Color/OFF mode.

This has two advantages:

- exiting ReaderLock cannot leave the whole iPhone accidentally grayscale;
- the effect is scoped to the only app you are allowed to use anyway.

If you independently enable iOS's global Accessibility grayscale/color-filter setting, Reader Color cannot override that final system display transform; turn the global filter off if you want Reader Color to show color.

## Build requirements

- Theos
- a patched iOS SDK (15.6 is a good target; newer SDK with deployment target 15.0 is fine)
- an iOS-capable clang/ld64 toolchain
- `ldid`, `dpkg`, `fakeroot`
- CCSupport installed on the phone
- Dopamine / ElleKit rootless environment

The Makefile is intentionally `ARCHS = arm64`, because this package is aimed at the A10 iPhone 7. It does not need arm64e.

### Build

```bash
export THEOS="$HOME/theos"
cd ReaderLock
./scripts/build.sh
```

The result is written to `packages/*.deb`. Because `THEOS_PACKAGE_SCHEME = rootless` is set in the Makefile, Theos emits an `iphoneos-arm64` package and rewrites install paths for the rootless `/var/jb` layout.

### Install over SSH with Theos

```bash
export THEOS="$HOME/theos"
export THEOS_DEVICE_IP=192.168.1.123
# optionally: export THEOS_DEVICE_PORT=22
./scripts/install.sh
```

Or copy the generated `.deb` to the phone and install it in Sileo / Zebra. The package `postinst` kills an already-suspended Books or MapleRead SE process so the reader component is injected on next launch; then respring SpringBoard so the SpringBoard/CC pieces load. If an older ReaderLock that could trap the lock screen is still installed, install this package while tweak injection is off, then turn tweaks back on.

## GitHub Actions build

`.github/workflows/build.yml` is included. Put this directory in a GitHub repository, open **Actions → Build ReaderLock rootless deb → Run workflow**, then download the `ReaderLock-rootless-deb` artifact. This is the easiest way to obtain a correctly linked `.deb` if your local Linux machine does not yet have an Apple-compatible ld64/toolchain.

## First-device validation sequence

Do **not** make the first test with important unsaved work or with no way to reboot/respring.

1. Install CCSupport and ReaderLock; respring.
2. Add Use Maple, Reader Mono, and Reader Color to Control Center.
3. Confirm the phone has a device passcode / Touch ID configured.
4. Turn on Wi-Fi or cellular. Reader Lock will leave that choice alone.
5. Leave Use Maple highlighted and tap Reader Color.
6. Confirm MapleRead SE opens and remains in normal color, and that it can reach the network.
7. Try Home, app switcher, CC, NC, Siri, Reachability, screenshot, a web link, a share action, and a different-app URL. Then exit, turn Use Maple off, and repeat with Apple Books.
8. Send a Message/push notification from another device and verify no banner/notification surface appears.
9. If you have a harmless alarm configured for the next minute, verify it is suppressed (this tests `SBAlertItemsController` behavior on your point release).
10. Hold two fingers for 2.5s; verify Touch ID/passcode appears.
11. Cancel authentication once; verify Reader Lock stays active.
12. Triple-click Home; verify the independent SpringBoard authentication path appears.
13. Authenticate; verify Reader Lock returns to OFF, the radios are still whatever you set in step 4, and Low Power Mode is back to what it was before entry.
14. Enter Reader Mono; verify the reader windows become grayscale.
15. Exit and verify color returns.
16. Enter again and deliberately respring; verify the device returns OFF and Powercuff / Low Power Mode return to what they were. A radio recovery plist left by 0.1.3 is restored on that start; 0.1.4 and later do not write a new one.
17. Finally test the three-finger 8-second emergency exit inside the reader.
18. Only after all of the above, test lock/wake, queued notifications, the Today View gesture, Camera-from-lock-screen, and a full reboot while active. The kiosk does not survive a reboot. Radios stay as you left them.

## Logging / diagnostics

ReaderLock logs with the prefix `[ReaderLock]`.

Examples on a development Mac/Linux host with libimobiledevice:

```bash
idevicesyslog | grep ReaderLock
```

Or over SSH on the device, use the logging tools available in your bootstrap.

Useful expected messages:

- `state -> 3` : arming
- `state -> 1` : Mono active
- `state -> 2` : Color active
- `blocked app launch ... -> com.maplepop.bmsea` or `com.apple.iBooks`
- `suppressed bulletin ...`
- `authenticated exit`
- `Powercuff Heavy engaged`
- `restored Powercuff and Low Power Mode`
- `recovery snapshot found after SpringBoard restart`

## Source layout

```
SpringBoard.xm                  kiosk state machine + SpringBoard enforcement
Books.xm                       grayscale, share/link blocking, authenticated exit
Common/ReaderLockShared.h       Darwin notification protocol / state enum
ReaderLockSB.plist              inject only into SpringBoard
ReaderLockBooks.plist           inject into Apple Books and MapleRead SE
layout/DEBIAN/postinst          force-relaunch Books and MapleRead after package install
ReaderLockMonoCC/               CCSupport one-tap Mono module
ReaderLockColorCC/              CCSupport one-tap Color module
ReaderLockAppCC/                CCSupport switch: highlighted = MapleRead, otherwise Books
.github/workflows/build.yml     cloud .deb build
RESEARCH_NOTES.md               API/hook rationale and risk notes
```

## Known private-API risk boundaries

This is deliberately conservative, but several parts are private and must be validated on-device:

- `FBSystemServiceOpenApplicationRequest -setBundleIdentifier:` is the central launch firewall hook. A current open-source rootless tweak reports this exact hook working on iPhone 7 / iOS 15.7.7 / Dopamine, making it the strongest compatibility anchor in the project.
- Home, the app switcher, Reachability, and the Side+Home screenshot chord are handled on `SBHomeHardwareButton` (`singlePressUp:`, `doublePressUp:`, `triplePressUp:`, `longPress:`, `screenshotRecognizerDidRecognize:`). Triple-press is the SpringBoard authenticated exit. A repeat `singlePressUp:` during unlock is not forwarded. `doublePressUp:` is not forwarded while Reader Lock is active. Switcher, Control Center, Notification Center, and cover-sheet classes are still private; the foreground watchdog and launch firewall are the fallback if a presentation hook changes. The Control Center pull is refused by `_shouldAllowControlCenterGesture`, `allowShowTransitionSystemGesture`, `gestureRecognizerShouldBegin:`, and `grabberTongueOrPullEnabled:forGestureRecognizer:`. The Notification Center pull is refused by `_presentGestureBeganWithGestureRecognizer:` and the two `_presentOrDismissGesture` methods, and only while the cover sheet is not already up.
- `BBServer` and `SBAlertItemsController` are best-effort suppression paths. ReaderLock hooks `publishBulletin:destinations:`, `publishBulletinRequest:destinations:`, and `_publishBulletinRequest:forSectionID:forDestinations:`, plus both `activateAlertItem:` variants, and hides an already-visible notification list. An iOS point release can still move an alarm through another presentation or audio route, which is why the validation plan tests them.
- `RadiosPreferences`, `SBWiFiManager`, and `BluetoothManager` are loaded dynamically and guarded with selector checks. 0.1.4 and later do not call them on entry. They remain only so a recovery snapshot written by 0.1.3 can still be restored. A missing API causes that restore to fail open rather than crash SpringBoard.
- Powercuff's `PowerMode` / `RequireLowPowerMode` preferences and `_CDBatterySaver -setPowerMode:error:` are private. `PowerMode` 4 is the Heavy value YukiPower writes. If Powercuff is not installed, the preference write has nothing to apply and Low Power Mode is still requested. Neither path disables other tweaks.
- CoreAnimation's `CAFilter` is private. If unavailable, Mono rendering fails gracefully while the kiosk lock remains active.
- While Reader Lock is on, the reader hides `UIStatusBar` and `_UIStatusBar` if those views are still in the window after the status bar is marked hidden. They are restored when Reader Lock turns off.

## Recovery file

0.1.4 and later do not write a radio snapshot. If SpringBoard starts and finds one left by an older build, ReaderLock sets itself OFF first, restores that snapshot after SpringBoard has had time to initialize radio managers, then deletes the file:

```
/var/mobile/Library/Preferences/com.quan.readerlock.recovery.plist
```

0.1.5 writes a separate power snapshot only after the chosen reader is actually in front, and deletes it after Powercuff and Low Power Mode are restored:

```
/var/mobile/Library/Preferences/com.quan.readerlock.power.plist
```

The chosen reader is a separate file, and it is not deleted on exit:

```
/var/mobile/Library/Preferences/com.quan.readerlock.plist
```

`reader` is `maple` or `books`. A missing key means MapleRead.

## Safety policy inside the implementation

ReaderLock intentionally does not try to interfere with:

- sleep/wake via the side button;
- the lock screen itself: the first Home click is delivered so an iPhone 7 can finish Touch ID or passcode unlock. A second click during that unlock is ignored. Home is swallowed again once the cover sheet is gone;
- shutdown/reboot, including power-off, restart, and reset alerts;
- critical low-battery / thermal / emergency/SOS alert classes;
- LocalAuthentication UI required to leave Reader Lock.

Everything else is biased toward the one reader chosen for that session.
