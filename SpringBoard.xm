#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import "Common/ReaderLockShared.h"

#pragma mark - Minimal private interfaces (runtime guarded)

@interface FBSystemServiceOpenApplicationRequest : NSObject
@property(nonatomic, copy) NSURL *URL;
@end

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
@end

@interface SpringBoard : UIApplication
- (id)_accessibilityFrontMostApplication;
@end

@interface SBMainSwitcherViewController : UIViewController
+ (instancetype)sharedInstance;
@end

@interface SBControlCenterController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isVisible;
@end

@interface SBNotificationCenterController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isVisible;
@end

@interface SBCoverSheetPresentationManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isVisible;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

@interface BBBulletin : NSObject
@property(nonatomic, copy) NSString *sectionID;
@end

@interface BBServer : NSObject
@end

@interface NCNotificationStructuredListViewController : UIViewController
@end

@interface NCNotificationListViewController : UIViewController
@end

@interface SBMainDisplayPolicyAggregator : NSObject
@end

#pragma mark - Runtime state

static RLReaderState gReaderState = RLReaderStateOff;
static BOOL gAuthenticationInProgress = NO;
static int gStateToken = -1;
static int gMonoCommandToken = -1;
static int gColorCommandToken = -1;
static int gExitCommandToken = -1;
static int gAuthBeginToken = -1;
static int gAuthEndToken = -1;
static dispatch_source_t gWatchdog = nil;
static NSUInteger gRadioEpoch = 0;
static NSString *gSessionReaderBundle = nil;

static inline BOOL RLActive(void) {
    return RLStateIsActive(gReaderState);
}

static void RLPublishState(RLReaderState state) {
    gReaderState = state;
    if (gStateToken < 0) {
        notify_register_check(RLStateNotification, &gStateToken);
    }
    if (gStateToken >= 0) {
        notify_set_state(gStateToken, (uint64_t)state);
    }
    notify_post(RLStateNotification);
    NSLog(@"[ReaderLock] state -> %llu", (unsigned long long)state);
}

#pragma mark - Generic dynamic Objective-C calls

static id RLSharedInstance(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:sel]) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))[cls methodForSelector:sel];
    return fn ? fn(cls, sel) : nil;
}

static BOOL RLGetBool(id obj, NSString *selectorName, BOOL *valid) {
    if (valid) *valid = NO;
    if (!obj) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return NO;
    BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))[obj methodForSelector:sel];
    if (!fn) return NO;
    if (valid) *valid = YES;
    return fn(obj, sel);
}

static BOOL RLSetBool(id obj, NSString *selectorName, BOOL value) {
    if (!obj) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return NO;
    void (*fn)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[obj methodForSelector:sel];
    if (!fn) return NO;
    fn(obj, sel, value);
    return YES;
}

static void RLCallVoidBool(id obj, NSString *selectorName, BOOL value) {
    if (!obj) return;
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return;
    void (*fn)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[obj methodForSelector:sel];
    if (fn) fn(obj, sel, value);
}

static void RLInvokeVoidCompletion(id completion) {
    if (!completion) return;
    void (^block)(void) = completion;
    block();
}

#pragma mark - Radio snapshot / isolation

static id RLRadiosPreferences(void) {
    static void *handle = NULL;
    if (!handle) {
        handle = dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_LAZY | RTLD_GLOBAL);
    }
    Class cls = NSClassFromString(@"RadiosPreferences");
    return cls ? [[cls alloc] init] : nil;
}

static id RLBluetoothManager(void) {
    static void *handle = NULL;
    if (!handle) {
        handle = dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY | RTLD_GLOBAL);
    }
    return RLSharedInstance(@"BluetoothManager");
}

static void RLSetBluetoothPowered(BOOL powered) {
    id bluetooth = RLBluetoothManager();
    if (!RLSetBool(bluetooth, @"setPowered:", powered)) {
        RLSetBool(bluetooth, @"setEnabled:", powered);
    }
}

static id RLWiFiManager(void) {
    return RLSharedInstance(@"SBWiFiManager");
}

static NSDictionary *RLReadRecoverySnapshot(void) {
    return [NSDictionary dictionaryWithContentsOfFile:RLRecoveryPath];
}

static void RLClearRecoverySnapshot(void) {
    [[NSFileManager defaultManager] removeItemAtPath:RLRecoveryPath error:nil];
}

// Reader mode no longer changes radios. This only replays a snapshot an older
// build already wrote, so a phone left in Airplane Mode by 0.1.3 can recover.
static void RLRestoreSnapshotAfter(NSDictionary *snapshot, NSTimeInterval initialDelay) {
    if (!snapshot) return;
    NSUInteger epoch = ++gRadioEpoch;
    NSNumber *stamp = snapshot[@"timestamp"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(initialDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (epoch != gRadioEpoch) return;

        id radios = RLRadiosPreferences();
        if ([snapshot[@"airplane.valid"] boolValue]) {
            RLSetBool(radios, @"setAirplaneMode:", [snapshot[@"airplane.value"] boolValue]);
            if ([radios respondsToSelector:NSSelectorFromString(@"synchronize")]) {
                void (*sync)(id, SEL) = (void (*)(id, SEL))[radios methodForSelector:NSSelectorFromString(@"synchronize")];
                if (sync) sync(radios, NSSelectorFromString(@"synchronize"));
            }
        }

        // Let the airplane transition settle before restoring the user's explicit Wi-Fi/BT choices.
        // The recovery file stays until that finishes, so a crash in this window can retry it.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (epoch != gRadioEpoch) return;
            if ([snapshot[@"wifi.valid"] boolValue]) {
                RLSetBool(RLWiFiManager(), @"setWiFiEnabled:", [snapshot[@"wifi.value"] boolValue]);
            }
            if ([snapshot[@"bluetooth.valid"] boolValue]) {
                RLSetBluetoothPowered([snapshot[@"bluetooth.value"] boolValue]);
            }
            NSDictionary *onDisk = RLReadRecoverySnapshot();
            if (stamp && [onDisk[@"timestamp"] isEqual:stamp]) {
                RLClearRecoverySnapshot();
            }
        });
    });
}

#pragma mark - App / SpringBoard helpers

static NSString *RLFrontmostBundleIdentifier(void) {
    SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
    if (![sb respondsToSelector:@selector(_accessibilityFrontMostApplication)]) return nil;
    id app = [sb _accessibilityFrontMostApplication];
    if ([app respondsToSelector:@selector(bundleIdentifier)]) return [app bundleIdentifier];
    return nil;
}

static BOOL RLDeviceIsLocked(void) {
    id manager = RLSharedInstance(@"SBLockScreenManager");
    BOOL valid = NO;
    BOOL locked = RLGetBool(manager, @"isUILocked", &valid);
    return valid ? locked : NO;
}

// The iPhone 7 unlock click is the Home button. Swallowing it while the lock
// screen is up authenticates and then leaves SpringBoard on the cover sheet.
static BOOL RLCoverSheetIsVisible(void) {
    id cover = RLSharedInstance(@"SBCoverSheetPresentationManager");
    BOOL valid = NO;
    BOOL visible = RLGetBool(cover, @"isVisible", &valid);
    if (valid) return visible;
    valid = NO;
    visible = RLGetBool(cover, @"isPresented", &valid);
    return valid && visible;
}

static BOOL RLPassHomeButtonThrough(void) {
    if (!RLActive() || gAuthenticationInProgress) return YES;
    return RLDeviceIsLocked() || RLCoverSheetIsVisible();
}

static void RLLockSessionReader(void) {
    gSessionReaderBundle = [RLSelectedReaderBundleIdentifier() copy];
}

static void RLUnlockSessionReader(void) {
    gSessionReaderBundle = nil;
}

static NSString *RLSessionReaderBundle(void) {
    return gSessionReaderBundle.length ? gSessionReaderBundle : RLSelectedReaderBundleIdentifier();
}

static BOOL RLIsSafetyBundle(NSString *bundleIdentifier) {
    if (!bundleIdentifier.length) return NO;
    if ([bundleIdentifier isEqualToString:RLSessionReaderBundle()]) return YES;
    static NSSet<NSString *> *allow = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allow = [NSSet setWithArray:@[
            @"com.apple.springboard",
            @"com.apple.InCallService",      // keep emergency-call UI viable
            @"com.apple.CoreAuthUI",         // LocalAuthentication / passcode UI
            @"com.apple.PasscodeUI",
            @"com.apple.PreBoard"
        ]];
    });
    return [allow containsObject:bundleIdentifier];
}

static void RLDismissControlCenter(void) {
    id cc = RLSharedInstance(@"SBControlCenterController");
    if (!cc) return;
    BOOL valid = NO;
    BOOL visible = RLGetBool(cc, @"isVisible", &valid);
    if (!valid || !visible) return;

    SEL sel2 = NSSelectorFromString(@"dismissAnimated:completion:");
    if ([cc respondsToSelector:sel2]) {
        void (*fn)(id, SEL, BOOL, id) = (void (*)(id, SEL, BOOL, id))[cc methodForSelector:sel2];
        if (fn) fn(cc, sel2, YES, nil);
        return;
    }
    RLCallVoidBool(cc, @"dismissAnimated:", YES);
}

static void RLDismissAssistantIfNeeded(void) {
    if (!RLActive()) return;
    id assistant = RLSharedInstance(@"SBAssistantController");
    if (!assistant) return;
    for (NSString *name in @[@"dismissAssistantViewIfNecessary", @"dismissAssistantViewInEverySceneIfNecessary"]) {
        SEL sel = NSSelectorFromString(name);
        if (![assistant respondsToSelector:sel]) continue;
        void (*fn)(id, SEL) = (void (*)(id, SEL))[assistant methodForSelector:sel];
        if (fn) fn(assistant, sel);
        return;
    }
}

static void RLDismissNotificationCenterIfAppropriate(void) {
    if (!RLActive() || RLDeviceIsLocked()) return;

    id nc = RLSharedInstance(@"SBNotificationCenterController");
    BOOL valid = NO;
    if (nc && RLGetBool(nc, @"isVisible", &valid) && valid) {
        SEL sel2 = NSSelectorFromString(@"dismissAnimated:completion:");
        if ([nc respondsToSelector:sel2]) {
            void (*fn)(id, SEL, BOOL, id) = (void (*)(id, SEL, BOOL, id))[nc methodForSelector:sel2];
            if (fn) fn(nc, sel2, YES, nil);
        } else {
            RLCallVoidBool(nc, @"dismissAnimated:", YES);
        }
    }
}

static BOOL RLOpenReaderBundle(NSString *bundleIdentifier) {
    if (!bundleIdentifier.length) return NO;
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) {
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_GLOBAL);
        cls = NSClassFromString(@"LSApplicationWorkspace");
    }
    if (!cls) return NO;

    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    if (![cls respondsToSelector:defaultSel]) return NO;
    id (*getWorkspace)(id, SEL) = (id (*)(id, SEL))[cls methodForSelector:defaultSel];
    id workspace = getWorkspace ? getWorkspace(cls, defaultSel) : nil;
    if (!workspace) return NO;

    SEL modern = NSSelectorFromString(@"openApplicationWithBundleIdentifier:configuration:completionHandler:");
    if ([workspace respondsToSelector:modern]) {
        void (*fn)(id, SEL, NSString *, id, id) = (void (*)(id, SEL, NSString *, id, id))[workspace methodForSelector:modern];
        if (fn) {
            fn(workspace, modern, bundleIdentifier, nil, nil);
            return YES;
        }
    }

    SEL legacy = NSSelectorFromString(@"openApplicationWithBundleIdentifier:");
    if ([workspace respondsToSelector:legacy]) {
        BOOL (*fn)(id, SEL, NSString *) = (BOOL (*)(id, SEL, NSString *))[workspace methodForSelector:legacy];
        if (fn) return fn(workspace, legacy, bundleIdentifier);
    }
    return NO;
}

static BOOL RLOpenSelectedReader(void) {
    return RLOpenReaderBundle(RLSessionReaderBundle());
}

static void RLForceReaderForegroundIfNeeded(void) {
    if (!RLActive() || gAuthenticationInProgress || RLDeviceIsLocked() || RLCoverSheetIsVisible()) return;
    NSString *front = RLFrontmostBundleIdentifier();
    if (![front isEqualToString:RLSessionReaderBundle()]) {
        RLOpenSelectedReader();
    }
}

#pragma mark - State machine

static void RLAbortEntry(NSString *reason) {
    NSLog(@"[ReaderLock] entry failed: %@", reason ?: @"unknown");
    RLPublishState(RLReaderStateExiting);
    RLRestoreSnapshotAfter(RLReadRecoverySnapshot(), 0);
    RLUnlockSessionReader();
    RLPublishState(RLReaderStateOff);
}

static void RLBeginReaderMode(RLReaderState requestedMode) {
    if (gReaderState != RLReaderStateOff) return;
    if (requestedMode != RLReaderStateMono && requestedMode != RLReaderStateColor) return;

    RLLockSessionReader();
    NSString *reader = RLSessionReaderBundle();
    NSLog(@"[ReaderLock] entering %@ reader %@", requestedMode == RLReaderStateMono ? @"MONO" : @"COLOR", reader);
    RLPublishState(RLReaderStateArming);

    RLDismissControlCenter();
    RLDismissAssistantIfNeeded();

    if (!RLOpenSelectedReader()) {
        RLAbortEntry(@"Could not ask LaunchServices to open the reader");
        return;
    }

    // Do not arm the firewall until the chosen reader has genuinely reached the foreground.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.70 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *front = RLFrontmostBundleIdentifier();
        if (![front isEqualToString:reader]) {
            RLOpenSelectedReader();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSString *second = RLFrontmostBundleIdentifier();
                if (![second isEqualToString:reader]) {
                    RLAbortEntry([NSString stringWithFormat:@"%@ never became foreground", reader]);
                    return;
                }
                RLPublishState(requestedMode);
            });
            return;
        }
        RLPublishState(requestedMode);
    });
}

static void RLEndReaderMode(void) {
    if (gReaderState == RLReaderStateOff || gReaderState == RLReaderStateExiting) return;

    NSLog(@"[ReaderLock] authenticated exit");
    RLPublishState(RLReaderStateExiting); // firewall hooks become permissive immediately
    gAuthenticationInProgress = NO;

    // Radios were not changed. A snapshot here is one left behind by an older build.
    RLRestoreSnapshotAfter(RLReadRecoverySnapshot(), 0);
    RLUnlockSessionReader();
    RLPublishState(RLReaderStateOff);
}

static void RLRequestSpringBoardAuthenticatedExit(void) {
    if (!RLActive() || gAuthenticationInProgress) return;

    LAContext *context = [LAContext new];
    context.localizedCancelTitle = @"Keep Reading";
    NSError *error = nil;
    if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        NSLog(@"[ReaderLock] SpringBoard authentication unavailable: %@", error);
        return;
    }

    gAuthenticationInProgress = YES;
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:@"Exit Reader Lock and restore the iPhone"
                      reply:^(BOOL success, NSError *authError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                RLEndReaderMode();
            } else {
                gAuthenticationInProgress = NO;
                RLForceReaderForegroundIfNeeded();
                NSLog(@"[ReaderLock] SpringBoard exit authentication failed/cancelled: %@", authError);
            }
        });
    }];
}

static void RLRecoverIfNeeded(void) {
    NSDictionary *snapshot = RLReadRecoverySnapshot();
    RLPublishState(RLReaderStateOff); // fail-open first
    gAuthenticationInProgress = NO;
    RLUnlockSessionReader();

    if (!snapshot) return;
    NSLog(@"[ReaderLock] recovery snapshot found after SpringBoard restart; restoring system state");
    // Radio managers are not ready at constructor time. Keep the file until the delayed restore finishes.
    RLRestoreSnapshotAfter(snapshot, 1.25);
}

#pragma mark - App launch firewall

%hook FBSystemServiceOpenApplicationRequest

- (void)setBundleIdentifier:(NSString *)bundleIdentifier {
    // Stay enforced during the exit-auth sheet, but not while locked. Rewriting a
    // launch to Books during unlock keeps the cover sheet from dismissing.
    if (!RLActive() || RLDeviceIsLocked() || RLCoverSheetIsVisible() || !bundleIdentifier.length || RLIsSafetyBundle(bundleIdentifier)) {
        %orig;
        return;
    }

    NSString *reader = RLSessionReaderBundle();
    if (![bundleIdentifier isEqualToString:reader]) {
        NSLog(@"[ReaderLock] blocked app launch %@ -> %@", bundleIdentifier, reader);
        if ([self respondsToSelector:@selector(setURL:)]) {
            self.URL = nil;
        }
        %orig(reader);
        return;
    }

    %orig;
}

%end

#pragma mark - Home / app switcher / Control Center / Siri / reachability

%hook SBHomeHardwareButton

- (void)singlePressUp:(id)press {
    if (!RLPassHomeButtonThrough()) {
        RLForceReaderForegroundIfNeeded();
        return;
    }
    %orig;
}

- (void)doublePressUp:(id)press {
    if (!RLPassHomeButtonThrough()) return;
    %orig;
}

- (void)doubleTapUp:(id)press {
    if (!RLPassHomeButtonThrough()) return;
    %orig;
}

- (void)triplePressUp:(id)press {
    if (RLActive() && !RLPassHomeButtonThrough()) {
        RLRequestSpringBoardAuthenticatedExit();
        return;
    }
    %orig;
}

- (void)longPress:(id)press {
    if (!RLPassHomeButtonThrough()) return;
    %orig;
}

- (void)screenshotRecognizerDidRecognize:(id)recognizer {
    if (!RLPassHomeButtonThrough()) return;
    %orig;
}

%end

%hook SBMainSwitcherViewController

- (BOOL)toggleMainSwitcherNoninteractivelyWithSource:(long long)source animated:(BOOL)animated {
    if (RLActive()) return NO;
    return %orig;
}

%end

%hook SBControlCenterController

- (void)presentAnimated:(BOOL)animated {
    if (RLActive()) return;
    %orig;
}

- (void)presentAnimated:(BOOL)animated completion:(id)completion {
    if (RLActive()) {
        RLInvokeVoidCompletion(completion);
        return;
    }
    %orig;
}

%end

%hook SBNotificationCenterController

- (void)presentAnimated:(BOOL)animated {
    if (RLActive() && !RLDeviceIsLocked()) return;
    %orig;
}

- (void)presentAnimated:(BOOL)animated completion:(id)completion {
    if (RLActive() && !RLDeviceIsLocked()) {
        RLInvokeVoidCompletion(completion);
        return;
    }
    %orig;
}

%end

%hook SBCoverSheetSlidingViewController

- (void)_presentCoverSheetAnimated:(BOOL)animated forUserGesture:(BOOL)gesture withCompletion:(id)completion {
    // User-driven cover sheet (Notification Center) is blocked while unlocked.
    // Non-gesture presentation is left alone so side-button sleep/wake can still lock.
    if (RLActive() && gesture && !RLDeviceIsLocked()) {
        RLInvokeVoidCompletion(completion);
        return;
    }
    %orig;
}

%end

%hook SBReachabilityManager

- (void)toggleReachability {
    if (RLActive()) return;
    %orig;
}

%end

%hook SBAssistantController

- (void)_setVisible:(BOOL)visible {
    if (RLActive() && visible) return;
    %orig;
}

%end

%hook SpringBoard

- (void)frontDisplayDidChange:(id)newDisplay {
    %orig;
    if (!RLActive() || gAuthenticationInProgress) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RLForceReaderForegroundIfNeeded();
    });
}

- (void)takeScreenshot {
    if (RLActive()) return;
    %orig;
}

%end

%hook SBScreenshotManager

- (void)saveScreenshots {
    if (RLActive()) return;
    %orig;
}

%end

#pragma mark - Notification / alert suppression

static NSString *RLSectionIDFromBulletinLikeObject(id object) {
    if (!object) return nil;
    SEL sectionSel = NSSelectorFromString(@"sectionID");
    if ([object respondsToSelector:sectionSel]) {
        id (*fn)(id, SEL) = (id (*)(id, SEL))[object methodForSelector:sectionSel];
        id value = fn ? fn(object, sectionSel) : nil;
        return [value isKindOfClass:[NSString class]] ? value : nil;
    }
    return nil;
}

static BOOL RLShouldAllowBulletinSection(NSString *section) {
    // Keep only SpringBoard-owned safety/system bulletins. Ordinary app notifications,
    // Messages, Mail, Calendar, alarms delivered as app bulletins, etc. are dropped.
    return section.length && [section hasPrefix:@"com.apple.springboard"];
}

static BOOL RLShouldAllowSystemAlert(id alertItem) {
    NSString *name = NSStringFromClass([alertItem class]);
    if (!name.length) return NO;
    static NSArray<NSString *> *safetyFragments = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        safetyFragments = @[@"LowPower", @"Battery", @"Thermal", @"Emergency", @"SOS", @"Shutdown", @"PowerDown", @"PowerOff", @"Restart", @"Reboot", @"Reset"];
    });
    for (NSString *fragment in safetyFragments) {
        if ([name rangeOfString:fragment options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

%hook SBAlertItemsController

- (void)activateAlertItem:(id)alertItem {
    if (RLActive() && !RLShouldAllowSystemAlert(alertItem)) {
        NSLog(@"[ReaderLock] suppressed SpringBoard alert item %@", NSStringFromClass([alertItem class]));
        return;
    }
    %orig;
}

- (void)activateAlertItem:(id)alertItem animated:(BOOL)animated {
    if (RLActive() && !RLShouldAllowSystemAlert(alertItem)) {
        NSLog(@"[ReaderLock] suppressed SpringBoard alert item %@", NSStringFromClass([alertItem class]));
        return;
    }
    %orig;
}

%end

%hook BBServer

- (void)publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)destinations {
    if (RLActive()) {
        NSString *section = RLSectionIDFromBulletinLikeObject(bulletin);
        if (!RLShouldAllowBulletinSection(section)) {
            NSLog(@"[ReaderLock] suppressed bulletin %@", section ?: @"<unknown>");
            return;
        }
    }
    %orig;
}

- (void)publishBulletinRequest:(id)request destinations:(unsigned long long)destinations {
    if (RLActive()) {
        NSString *section = RLSectionIDFromBulletinLikeObject(request);
        if (!RLShouldAllowBulletinSection(section)) {
            NSLog(@"[ReaderLock] suppressed bulletin request %@", section ?: @"<unknown>");
            return;
        }
    }
    %orig;
}

- (void)_publishBulletinRequest:(id)request forSectionID:(id)section forDestinations:(unsigned long long)destinations {
    NSString *sectionID = [section isKindOfClass:[NSString class]] ? section : nil;
    if (RLActive() && !RLShouldAllowBulletinSection(sectionID)) {
        NSLog(@"[ReaderLock] suppressed private bulletin request %@", sectionID ?: @"<unknown>");
        return;
    }
    %orig;
}

%end

// Hide already-existing Notification Center / Lock Screen notification history too.
// This complements BBServer suppression: it prevents notifications queued before
// Reader Lock was entered from remaining visible on the Cover Sheet.
%hook NCNotificationStructuredListViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (RLActive()) self.view.hidden = YES;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    self.view.hidden = RLActive();
}

- (void)viewWillLayoutSubviews {
    %orig;
    self.view.hidden = RLActive();
}

- (BOOL)hasVisibleContent {
    if (RLActive()) return NO;
    return %orig;
}

%end

%hook NCNotificationListViewController

- (BOOL)hasVisibleContent {
    if (RLActive()) return NO;
    return %orig;
}

%end

// Prevent the lock-screen Today View from becoming a second usable environment.
%hook SBMainDisplayPolicyAggregator

- (BOOL)_allowsCapabilityLockScreenTodayViewWithExplanation:(id *)explanation {
    if (RLActive()) return NO;
    return %orig;
}

- (BOOL)_allowsCapabilityTodayViewWithExplanation:(id *)explanation {
    if (RLActive()) return NO;
    return %orig;
}

%end

#pragma mark - Watchdog / notifications

static void RLStartWatchdog(void) {
    if (gWatchdog) return;
    gWatchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gWatchdog,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              1 * NSEC_PER_SEC,
                              150 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gWatchdog, ^{
        if (!RLActive()) return;
        RLDismissControlCenter();
        RLDismissNotificationCenterIfAppropriate();
        RLDismissAssistantIfNeeded();
        RLForceReaderForegroundIfNeeded();
    });
    dispatch_resume(gWatchdog);
}

%ctor {
    @autoreleasepool {
        %init;
        NSLog(@"[ReaderLock] SpringBoard component loaded on iOS %@", [UIDevice currentDevice].systemVersion);

        notify_register_check(RLStateNotification, &gStateToken);

        notify_register_dispatch(RLCommandMonoNotification, &gMonoCommandToken, dispatch_get_main_queue(), ^(int token) {
            RLBeginReaderMode(RLReaderStateMono);
        });
        notify_register_dispatch(RLCommandColorNotification, &gColorCommandToken, dispatch_get_main_queue(), ^(int token) {
            RLBeginReaderMode(RLReaderStateColor);
        });
        notify_register_dispatch(RLCommandExitNotification, &gExitCommandToken, dispatch_get_main_queue(), ^(int token) {
            RLEndReaderMode();
        });
        notify_register_dispatch(RLAuthBeginNotification, &gAuthBeginToken, dispatch_get_main_queue(), ^(int token) {
            if (RLActive()) gAuthenticationInProgress = YES;
        });
        notify_register_dispatch(RLAuthEndNotification, &gAuthEndToken, dispatch_get_main_queue(), ^(int token) {
            gAuthenticationInProgress = NO;
            RLForceReaderForegroundIfNeeded();
        });

        RLRecoverIfNeeded();
        RLStartWatchdog();
    }
}
