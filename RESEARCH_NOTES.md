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

### Bottom line instead of the status bar

The replacement is drawn by `ReaderLockBooks`, which is already injected into `com.apple.iBooks` and `com.maplepop.bmsea`. It appears only while the Darwin state is Mono or Color. Time is a 24-hour `HH:mm` formatter. Battery is `UIDevice` battery monitoring. Wi-Fi is `SCNetworkReachability` on `0.0.0.0`: reachable and not `kSCNetworkReachabilityFlagsIsWWAN`. Anything else, including cellular, is an em dash. The window's `hitTest:withEvent:` returns nil, so page turns pass through.

`prefersStatusBarHidden` on `UIViewController` is not enough, because a subclass override never reaches that implementation. Each view-controller class that implements the method gets its own replacement, which returns hidden only while Reader Lock is on and otherwise calls the saved implementation. MapleRead is built with a newer clang, so those overrides are encoded `B16@0:8` rather than `B@:`. Comparing the whole encoding string skipped them: the layout inset collapsed, and the still-visible status bar sat on the book title as a black strip. The return type and argument count are what get checked. `UIStatusBarManager`'s hidden flag and frame are forced as well. A leftover `UIStatusBar` or `_UIStatusBar` view is hidden while Reader Lock is on and restored on exit. The bottom line is a 22-point window, not a full-screen one, because a full-screen window at status-bar level paints its own black gap across the top. Its color is `secondaryLabelColor`, which follows the system appearance and not a sepia or night page theme.

The library has no grey band, so the band that remains after the system status bar is hidden is the open book's own `blackStatusBar` / `blackStatusBarArea`, plus a thin unsafe-area theme view, not another system status bar. Only that screen's bottom safe area grows by 22 points. A short frame-based progress label that still intersects the line is translated up, and the translation is reduced if the inset already moved it. `UIApplication`'s `statusBarFrame` is returned as `CGRectZero` while Reader Lock is on, through a real C function rather than a block, because `CGRect` is a 32-byte return on arm64. This has not been run on a phone.

The time line is its own window, so leaving it up for the whole session covers MapleRead's library. It is shown only when the frontmost controller, walking up through parents but not through a presented controller's presenter, has `blackStatusBar`, `blackStatusBarArea`, `pageLabel`, or `progressLabel` in a window. `viewDidAppear:` and `viewDidDisappear:` schedule that check, and so does the book's own layout while the line is still hidden. Apple Books has none of those views, so the check is skipped there and the line stays up.

On device with 0.1.10, that system bar was still visible on MapleRead panels other than the home screen and the open book. Go to Exchange is one of them. UIKit does not ask `UIViewController` once a container implements `childViewControllerForStatusBarHidden`: it asks the visible child, and that child can answer NO. MapleRead's download controller always does, and its library controller does on screens other than the home list. Replacing `prefersStatusBarHidden` with a block, and telling `UIStatusBarManager` the bar is hidden, does not draw it hidden while that walk reaches a NO.

0.1.11 returned no child from those container methods so the walk would stop on the tab bar, and forced every owning `prefersStatusBarHidden` to return hidden. On device the system bar then showed on every screen, including home and the open book. Stopping the walk moved the decision off the controllers that already returned hidden, and the tab bar's own answer is visible. A full-screen present was also told not to capture the status bar, and every appearance asked UIKit to apply that visible answer again, which is the bar popping back in. The view hide only matched a class list taken once; if that list was still empty, it never matched later. 0.1.12 leaves the child methods alone, still returns hidden from every class that owns `prefersStatusBarHidden` (a miss is not cached), and hides a view when its class or a superclass is a status-bar class. That match is remembered on the class the first time the class is seen, not in a once-block that can freeze empty. This has not been run on a phone.

0.1.13 still leaves the child methods alone. It also adds `prefersStatusBarHidden` to every `UIViewController` subclass that never implemented it, so a leaf UIKit actually asks cannot keep the default visible answer. MapleRead overrides of `viewWillAppear:` / `viewDidAppear:` that skip super still refresh that hidden answer. SpringBoard hides the native bar independently: `SBDeviceApplicationSceneStatusBarStateProvider -_statusBarHiddenGivenFallbackOrientation:` and `-_statusBarAlpha` exist on both the iOS 14 and iOS 17 dumps, and `SBMainDisplaySceneLayoutStatusBarView` is told the bar is hidden on those same dumps. `SBAppStatusBarSettingsAssertion -initWithStatusBarHidden:atLevel:reason:` is iOS 14-shaped and is taken at runtime if the selector exists; it is not called if iOS 17's private window-scene initializer is the only one present. `SBStatusBarManager -acquireHideFrontmostStatusBarAssertionForReason:` is not used, because it can hide the lock-screen bar. This has not been run on a phone.

### Control Center / Notification Center / Siri / Reachability

On iOS 14 and iOS 17 dumps, `SBUIController` has no `clickedMenuButton`, and `SBAssistantController` has no `handleSiriButtonDownEventFromSource:activationEvent:`. The iPhone 7 Home button is `SBHomeHardwareButton`: single press is swallowed once the cover sheet is gone, double press blocks the switcher even on the lock screen, double-tap blocks Reachability, triple press starts the SpringBoard authenticated exit, and long-press blocks hold-Home Siri. The first `singlePressUp:` while locked, or while the cover sheet is still visible, is forwarded so Touch ID can dismiss the lock screen. A second one inside 0.55 seconds while still locked, or inside 4 seconds after Touch ID has already cleared the lock, is not forwarded. `initialButtonDown:` and `initialButtonUp:` are not hooked. `SBAssistantController -_setVisible:` refuses to show Siri and still allows dismiss.

`presentAnimated:` only runs after the finger has dragged the panel. The Control Center pull is refused earlier by `_shouldAllowControlCenterGesture`, `allowShowTransitionSystemGesture`, `gestureRecognizerShouldBegin:`, and `grabberTongueOrPullEnabled:forGestureRecognizer:`, which exist on both dumps. `allowShowTransition` exists only on the iOS 14 dump and is not hooked. The Notification Center pull is `SBCoverSheetSlidingViewController`'s `_presentGestureBeganWithGestureRecognizer:`, `_presentOrDismissGestureChangedWithGestureRecognizer:`, and `_presentOrDismissGestureEndedWithGestureRecognizer:`. Those are refused only while Reader Lock is active, the phone is unlocked, and the cover sheet is not already visible, so lock-screen dismiss and the camera swipe still run. Side-button lock uses the non-gesture present path and is not hooked. Presentation hooks plus the frontmost-app watchdog remain the fallback.

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

## Powercuff while the reader is foreground

YukiPower's battery profile writes Powercuff `PowerMode` = 4 (Heavy) and `RequireLowPowerMode` = false, synchronizes that domain, posts `com.rpetrich.powercuff.settingschanged` and `com.rpetrich.powercuff.thermals`, then sets `_CDBatterySaver` power mode to 1. Reader Lock does that only after the chosen reader is foreground, and only after its own snapshot is on disk. Exit and the fail-open constructor write the saved values back, deleting a key that was absent. A failed Low Power Mode restore keeps the snapshot for the next SpringBoard start. A failed Low Power Mode *enable* does not undo Heavy.

YukiPower Ultra also adds every non-keeper tweak dylib to Choicy `globalDeniedTweaks` and resprings with `kill(getpid(), SIGTERM)`. Reader Lock does neither. That deny list would include ReaderLock's own dylibs, and a respring publishes Off, so the kiosk would exit itself. `com.yukipower.state.plist` is not written. If Ultra was already on, the snapshot already says Heavy and Low Power Mode on, so leaving Reader Lock restores that instead of turning Ultra off. Powercuff is not a hard dependency.

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
13. after a session, Powercuff's previous mode and Low Power Mode are back, including when the session ended in a respring. Other tweaks are still injected.

## Why the CC controls are separate toggles

`CCUIToggleModule` is the narrowest CCSupport interface on iOS 15. Mono and Color each enter in one tap. A third toggle, checked only while Reader Lock is off, stores `maple` or `books` in the preference plist. The session then locks that bundle id so a later tap cannot retarget the firewall.

## Build-environment note

A functional `.deb` contains iOS Mach-O binaries and must be linked with an iOS-capable Apple/cctools linker and an iOS SDK. A generic Linux/Swift clang installation that can emit an arm64 Apple object file is not sufficient if its `ld64.lld` lacks iOS platform support. The included GitHub Actions workflow avoids that local-toolchain problem.
