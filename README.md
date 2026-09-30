# ReaderLock for Dopamine / iOS 15

ReaderLock turns an iPhone into a deliberately dumb Apple Books appliance from Control Center.

This project targets the **iPhone 7 / iOS 15 / Dopamine rootless** case first. It is an engineering release candidate: the source is complete and packageable, but private SpringBoard APIs always require testing on the exact iOS point release before calling a build production-safe.

## User experience

After installation and respring, add either or both CCSupport modules to Control Center:

- **Reader Mono** — opens Books, isolates the phone, and renders Books in grayscale.
- **Reader Color** — same isolation, normal color rendering.

One tap enters the chosen mode. Once active:

- Apple Books is forced to the foreground.
- attempts to launch another app are redirected to Books;
- the Home action is eaten and a foreground watchdog re-opens Books if another route reaches SpringBoard;
- app switcher presentation is blocked;
- Control Center presentation is blocked;
- Notification Center / Cover Sheet presentation from the unlocked Books session is blocked;
- queued notification history is hidden on the Lock Screen while Reader Lock is active;
- the Lock Screen Today View is disabled while Reader Lock is active;
- Siri activation is blocked;
- Reachability is blocked;
- screenshots are blocked;
- ordinary BulletinBoard notifications are dropped across both legacy bulletin and newer bulletin-request publication paths;
- ordinary SpringBoard alert items (including normal alarms) are suppressed;
- share sheet, Safari view controller, document picker, Mail/Message composer and Store product UI from Books are blocked;
- both legacy and modern external `openURL:` calls from Books are denied;
- Airplane Mode is enabled and Wi-Fi + Bluetooth are explicitly disabled;
- the previous radio state is snapshotted before isolation and restored on exit.

Critical-ish SpringBoard alerts whose class name includes LowPower, Battery, Thermal, Emergency, SOS or Shutdown are allowed through. `InCallService`, CoreAuth UI and passcode UI are on the launch safety allowlist so emergency/authentication infrastructure is not accidentally redirected.

## Exiting Reader Lock

Normal exit is intentionally *not* in Control Center, because Control Center is inaccessible in Reader Lock.

Normal exit has **two independent authenticated triggers**:

- in Books, hold **two fingers** for **2.5 seconds**; or
- on the iPhone 7, **triple-click the Home button** while Reader Lock is active.

Either path asks iOS for Touch ID or the device passcode using `LAPolicyDeviceOwnerAuthentication`. On success, ReaderLock disables the firewall first, restores the radio snapshot, removes the grayscale filter, and returns to OFF. The SpringBoard/Home-button path exists specifically so exit does not depend on the Books process having received tweak injection.

Fail-safe exit: hold **three fingers for 8 seconds inside Books**. This skips authentication and exists only to prevent lockout if LocalAuthentication is broken or no device passcode is configured. A reboot is the final physical escape because jailbreak enforcement disappears when SpringBoard is no longer running the tweak.

A SpringBoard restart/respring is fail-open: active Reader Lock is deliberately never restored across SpringBoard startup, and the recovery snapshot is restored when the tweak loads. A full reboot also removes the kiosk enforcement because tweak injection is gone; however, radio settings are persistent system settings, so if the phone is rebooted while Airplane Mode is ON they can remain isolated until you turn them back on manually or re-enable Dopamine and let ReaderLock consume its recovery snapshot. This is why the emergency exit is provided and why the package never tries to survive a reboot.

## State machine

```
OFF
  | tap Reader Mono / Reader Color
  v
ARMING
  - write recovery snapshot
  - dismiss Control Center
  - set Airplane Mode ON
  - force Wi-Fi OFF
  - force Bluetooth OFF
  - request Books launch
  - confirm Books is actually foreground
  |
  +-- failure --> EXITING -> restore snapshot -> OFF
  |
  v
MONO or COLOR
  - app launch firewall active
  - system surfaces restricted
  - notifications / ordinary alerts suppressed
  - Books-only escape UI blocked
  - watchdog keeps Books foreground
  |
  | authenticated exit / emergency exit
  v
EXITING
  - firewall becomes permissive immediately
  - restore radios
  - delete recovery snapshot
  - notify Books to restore rendering
  v
OFF
```

## Why ReaderLock does not programmatically start Apple's Single App Mode

Apple exposes `UIAccessibilityRequestGuidedAccessSession`, but Apple's own documentation says programmatic Single App Mode requires a supervised MDM device and an allow-listed app. A normal personal iPhone is not eligible. ReaderLock therefore implements the required kiosk behavior in the jailbreak layer instead of making an unsupported Guided Access call the foundation of the lock.

You can still enable stock Guided Access manually as an additional independent layer if desired, but ReaderLock does not depend on it.

## Why grayscale is implemented as a Books rendering filter

The public UIKit grayscale API is read-only. ReaderLock therefore does **not** mutate your global Accessibility Color Filters preference. In Mono mode it installs a private CoreAnimation `CAFilter` of type `colorSaturate` with `inputAmount = 0` on each Books window and restores the window's previous filters in Color/OFF mode.

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

Or copy the generated `.deb` to the phone and install it in Sileo / Zebra. The package `postinst` kills any already-suspended Books process so the Books-side component is injected on next launch; then respring SpringBoard so the SpringBoard/CC pieces load.

## GitHub Actions build

`.github/workflows/build.yml` is included. Put this directory in a GitHub repository, open **Actions → Build ReaderLock rootless deb → Run workflow**, then download the `ReaderLock-rootless-deb` artifact. This is the easiest way to obtain a correctly linked `.deb` if your local Linux machine does not yet have an Apple-compatible ld64/toolchain.

## First-device validation sequence

Do **not** make the first test with important unsaved work or with no way to reboot/respring.

1. Install CCSupport and ReaderLock; respring.
2. Add Reader Mono and Reader Color to Control Center.
3. Confirm the phone has a device passcode / Touch ID configured.
4. Record baseline Airplane/Wi-Fi/Bluetooth states.
5. Tap Reader Color first.
6. Confirm Books opens and remains in normal color.
7. Try Home, app switcher, CC, NC, Siri, Reachability, screenshot, a Books web link, a share action, and a different-app URL.
8. Send a Message/push notification from another device and verify no banner/notification surface appears.
9. If you have a harmless alarm configured for the next minute, verify it is suppressed (this tests `SBAlertItemsController` behavior on your point release).
10. Hold two fingers for 2.5s; verify Touch ID/passcode appears.
11. Cancel authentication once; verify Reader Lock stays active.
12. Triple-click Home; verify the independent SpringBoard authentication path appears.
13. Authenticate; verify radios restore exactly.
14. Enter Reader Mono; verify all Books windows become grayscale.
15. Exit and verify color returns.
16. Enter again and deliberately respring; verify the device returns OFF and radio state is restored from the recovery plist.
17. Finally test the three-finger 8-second emergency exit.
18. Only after all of the above, test lock/wake, queued notifications, the Today View gesture, Camera-from-lock-screen, and a full reboot while active so you understand the radio-state caveat.

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
- `blocked app launch ... -> Books`
- `suppressed bulletin ...`
- `authenticated exit`
- `recovery snapshot found after SpringBoard restart`

## Source layout

```
SpringBoard.xm                  kiosk state machine + SpringBoard enforcement
Books.xm                       grayscale, share/link blocking, authenticated exit
Common/ReaderLockShared.h       Darwin notification protocol / state enum
ReaderLockSB.plist              inject only into SpringBoard
ReaderLockBooks.plist           inject only into Apple Books
layout/DEBIAN/postinst          force-relaunch Books after package install
ReaderLockMonoCC/               CCSupport one-tap Mono module
ReaderLockColorCC/              CCSupport one-tap Color module
.github/workflows/build.yml     cloud .deb build
RESEARCH_NOTES.md               API/hook rationale and risk notes
```

## Known private-API risk boundaries

This is deliberately conservative, but several parts are private and must be validated on-device:

- `FBSystemServiceOpenApplicationRequest -setBundleIdentifier:` is the central launch firewall hook. A current open-source rootless tweak reports this exact hook working on iPhone 7 / iOS 15.7.7 / Dopamine, making it the strongest compatibility anchor in the project.
- Home, the app switcher, Reachability, and the Side+Home screenshot chord are handled on `SBHomeHardwareButton` (`singlePressUp:`, `doublePressUp:`, `triplePressUp:`, `longPress:`, `screenshotRecognizerDidRecognize:`). Triple-press is the SpringBoard authenticated exit. Switcher, Control Center, Notification Center, and cover-sheet classes are still private; the foreground watchdog and launch firewall are the fallback if a presentation hook changes.
- `BBServer` and `SBAlertItemsController` are best-effort suppression paths. ReaderLock hooks `publishBulletin:destinations:`, `publishBulletinRequest:destinations:`, and `_publishBulletinRequest:forSectionID:forDestinations:`, plus both `activateAlertItem:` variants, and hides an already-visible notification list. An iOS point release can still move an alarm through another presentation or audio route, which is why the validation plan tests them.
- `RadiosPreferences`, `SBWiFiManager`, and `BluetoothManager` are loaded dynamically and guarded with selector checks. A missing API causes that individual operation to fail open rather than crash SpringBoard.
- CoreAnimation's `CAFilter` is private. If unavailable, Mono rendering fails gracefully while the kiosk lock remains active.

## Recovery file

While arming/active, the pre-reader radio snapshot lives at:

```
/var/mobile/Library/Preferences/com.quan.readerlock.recovery.plist
```

It is deleted after normal exit. If SpringBoard starts and finds the file, ReaderLock sets itself OFF first, restores the snapshot after SpringBoard has had time to initialize radio managers, then deletes the file.

## Safety policy inside the implementation

ReaderLock intentionally does not try to interfere with:

- sleep/wake via the side button;
- shutdown/reboot;
- critical low-battery / thermal / emergency/SOS alert classes;
- LocalAuthentication UI required to leave Reader Lock.

Everything else is biased toward “Books only.”
