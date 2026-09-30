# ReaderLock engineering / research notes

Date: 2026-09-30
Primary target: iPhone 7 (A10, arm64), iOS 15.x, Dopamine rootless/ElleKit.

## Compatibility anchors

### Rootless packaging

Theos rootless mode uses `THEOS_PACKAGE_SCHEME=rootless`, emits `iphoneos-arm64`, adds rootless runpaths and maps package layout to `/var/jb`. The iPhone 7 is plain arm64, so the later arm64e ABI/toolchain issue is irrelevant to this target.

References:
- https://theos.dev/docs/rootless
- https://theos.dev/docs/packaging

### Central application-launch interception

`FBSystemServiceOpenApplicationRequest -setBundleIdentifier:` is used by the open-source ReynardDefault tweak to redirect launches at SpringBoard level. Its README reports a working rootless build on iPhone 7 / iOS 15.7.7 / Dopamine. ReaderLock uses the same interception point, but redirects every non-allowlisted application launch to `com.apple.iBooks` while active.

References:
- https://github.com/guacforlife/ReynardDefault
- https://github.com/guacforlife/ReynardDefault/blob/master/Tweak.x

### Apple Books bundle ID

Apple Books uses `com.apple.iBooks`.

Reference:
- https://github.com/petarov/apple-bundle-ids

### CCSupport module ABI

CCSupport modules can subclass `CCUIToggleModule`, implement `isSelected`, `setSelected:`, `iconGlyph`, and `selectedColor`, and install to `/Library/ControlCenter/Bundles/` (rootless prefix applied by Theos). ReynardDefault provides a current minimal example using exactly this structure.

References:
- https://github.com/guacforlife/ReynardDefault/tree/master/ReynardDefaultCC
- https://github.com/opa334/CCSupport

### Why not Autonomous Single App Mode

`UIAccessibilityRequestGuidedAccessSession` is public, but Apple documents that entry into programmatic Single App Mode is supported only on supervised MDM devices with the app allow-listed. Therefore it is not a reliable foundation for an ordinary personal jailbroken iPhone.

Reference:
- https://developer.apple.com/documentation/uikit/uiaccessibility/requestguidedaccesssession(enabled:completionhandler:)

### Authenticated exit

`LAPolicyDeviceOwnerAuthentication` authenticates with biometry and falls back to device passcode. That is ideal for an iPhone 7 with Touch ID.

References:
- https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication
- https://developer.apple.com/documentation/localauthentication/logging-a-user-into-your-app-with-face-id-or-touch-id

### Grayscale

UIKit exposes `UIAccessibilityIsGrayscaleEnabled` as a read-only state query. Instead of modifying the user's global Accessibility preferences with undocumented setters, ReaderLock applies a private CoreAnimation `CAFilter` (`colorSaturate`, `inputAmount=0`) to the chosen reader's windows and restores the window's prior filters on exit.

References:
- https://developer.apple.com/documentation/uikit/uiaccessibility/isgrayscaleenabled
- https://github.com/kageroumado/core-animation-private

### Network

As of 0.1.4, entering Reader Lock does not change Airplane Mode, Wi-Fi, or Bluetooth. The reader is expected to sync and download over whatever connection is already up. `RadiosPreferences`, `SBWiFiManager`, and `BluetoothManager` are still loaded dynamically, with selector checks, only to restore a snapshot that 0.1.3 may have left on disk.

References:
- https://github.com/joncardasis/To-The-Apples-Core
- https://github.com/nahtedetihw/ShakeItOff
- https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/BluetoothManager.framework/BluetoothManager.h

### Control Center / Notification Center / Siri / Reachability

On iOS 14 and iOS 17 dumps, `SBUIController` has no `clickedMenuButton`, and `SBAssistantController` has no `handleSiriButtonDownEventFromSource:activationEvent:`. The iPhone 7 Home button is `SBHomeHardwareButton`: single press is swallowed, double press blocks the switcher, double-tap blocks Reachability, triple press starts the SpringBoard authenticated exit, and long-press blocks hold-Home Siri. `SBAssistantController -_setVisible:` refuses to show Siri and still allows dismiss. Presentation hooks plus the frontmost-app watchdog remain the fallback.

Reference:
- https://github.com/DGh0st/DVirtualHome/blob/master/Tweak.xm

### Notification and alert suppression

BulletinBoard headers for iOS 14 and iOS 17 both expose `publishBulletin:destinations:`, `publishBulletinRequest:destinations:`, and `_publishBulletinRequest:forSectionID:forDestinations:`. They do not expose the older `alwaysToLockScreen:` overloads, so those are not hooked. ReaderLock hooks the three methods that exist on both dumps, hides the structured notification list (including `hasVisibleContent` and a layout pass so a list already on screen disappears), and hooks both `SBAlertItemsController` `activateAlertItem:` and `activateAlertItem:animated:`. Critical-looking battery/thermal/emergency/SOS/shutdown classes are allowed through.

References:
- https://github.com/minh-ton/NineLS/blob/main/NineLS.xm
- https://gist.github.com/iCrazeiOS/c6d32ade3f91a379101decebdabc9c92
- https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/BulletinBoard.framework/BBServer.h
- https://github.com/udevsharold/battsafepro/blob/master/SpringBoard-Private.h
- https://github.com/Baw-Appie/Axon/blob/master/Tweak/Tweak.xm

## Threat model / what “Books only” means

ReaderLock is aimed at eliminating casual and normal-system escape paths while retaining recovery and critical device behavior. It is **not** a security boundary against a technically skilled person with SSH, a computer, a jailbreak package manager, safe mode, or physical reboot access.

Blocked/redirected surfaces:
- visible app launches other than Books;
- Home / switcher;
- Control Center;
- Notification Center from the unlocked Books session;
- queued Lock Screen notification history;
- Lock Screen Today View;
- Siri;
- Reachability;
- screenshots;
- Books share sheet and common external view controllers;
- external URL opens;
- ordinary notifications;
- ordinary SpringBoard alert items / alarms;
- network connectivity via Airplane + explicit Wi-Fi/Bluetooth OFF.

Retained escape/safety surfaces:
- Touch ID/device-passcode exit from Books;
- independent triple-Home Touch ID/passcode exit in SpringBoard;
- 3-finger 8-second emergency exit;
- reboot / respring fail-open;
- side-button sleep/wake;
- critical-ish system alert classes;
- emergency/authentication service allowlist.

## Failure handling

### Failure while entering

The launch firewall is not activated until Books is confirmed in the foreground. If Books cannot be foregrounded, ReaderLock restores the saved radios and returns OFF.

### SpringBoard crash / respring while active

The active state is process-local and explicitly reset to OFF at constructor time. The recovery plist is then restored after a short delay, so a SpringBoard crash/respring cannot make the lock persist unintentionally.

### Full reboot while active

The jailbreak hooks are gone after reboot, so the *kiosk* is fail-open. 0.1.4 does not change radios. A snapshot written by 0.1.3 is a persistent Airplane/Wi-Fi/Bluetooth state until SpringBoard loads ReaderLock and restores that file. A hard reboot by itself still does not restore those settings.

### API missing on a point release

Radio calls use dynamic class/selector checks. Grayscale creation checks for `CAFilter`. A missing optional private API therefore degrades an individual feature rather than dereferencing a missing selector.

### LocalAuthentication unavailable

Both the 2-finger reader exit and triple-Home SpringBoard exit use device-owner authentication. If it cannot be evaluated, the user can use the 3-finger 8-second emergency exit inside the reader, respring, or reboot. Keeping an authenticated exit in SpringBoard also protects against the reader process having been launched before its injection dylib was loaded. The reader dylib is injected into `com.apple.iBooks` and `com.maplepop.bmsea`.

## Areas that require exact-device verification

Private APIs are not contracts. These are the tests that determine whether a particular `.deb` is truly production-ready on a specific iOS 15.x build:

1. `FBSystemServiceOpenApplicationRequest` receives launches for Safari, Messages, Settings, Camera, App Store.
2. Home click is caught by `SBHomeHardwareButton -singlePressUp:` on the installed build, and triple-press reaches the SpringBoard authentication sheet.
3. `SBMainSwitcherViewController -toggleMainSwitcherNoninteractivelyWithSource:animated:` is the live switcher selector and returns BOOL.
4. Control Center entry is blocked for the actual iOS point release.
5. Cover Sheet/Notification Center entry is blocked while unlocked but normal lock/unlock still works.
6. Siri does not overlay the reader.
7. bulletin hook actually suppresses third-party/local notifications.
8. an existing Clock alarm is suppressed by the alert-item hook (alarm presentation has changed between iOS versions).
9. entering Reader Lock leaves Airplane Mode, Wi-Fi, and Bluetooth unchanged, and a leftover 0.1.3 recovery plist is still restored on SpringBoard start.
10. the reader window has no pre-existing layer filters that are lost after Mono -> OFF.
11. LocalAuthentication UI is not redirected by the app-launch firewall.
12. all states recover correctly after a forced SpringBoard restart.

## Why the CC controls are separate toggles

`CCUIToggleModule` is the narrowest CCSupport interface on iOS 15. Mono and Color each enter in one tap. A third toggle, checked only while Reader Lock is off, stores `maple` or `books` in the preference plist. The session then locks that bundle id so a later tap cannot retarget the firewall.

## Build-environment note

A functional `.deb` contains iOS Mach-O binaries and must be linked with an iOS-capable Apple/cctools linker and an iOS SDK. A generic Linux/Swift clang installation that can emit an arm64 Apple object file is not sufficient if its `ld64.lld` lacks iOS platform support. The included GitHub Actions workflow avoids that local-toolchain problem.
