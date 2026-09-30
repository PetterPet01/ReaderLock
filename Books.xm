#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import "Common/ReaderLockShared.h"

@interface CAFilter : NSObject
+ (instancetype)filterWithType:(NSString *)type;
+ (instancetype)filterWithName:(NSString *)name;
@end

static RLReaderState gBooksReaderState = RLReaderStateOff;
static int gBooksStateToken = -1;
static const void *kRLOriginalFiltersKey = &kRLOriginalFiltersKey;
static const void *kRLGesturesInstalledKey = &kRLGesturesInstalledKey;

static inline BOOL RLBooksActive(void) {
    return RLStateIsActive(gBooksReaderState);
}

static NSArray<UIWindow *> *RLApplicationWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    if (windows.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [windows addObjectsFromArray:app.windows];
#pragma clang diagnostic pop
    }
    return windows;
}

#pragma mark - Grayscale rendering

static NSArray *RLCreateMonoFilters(void) {
    Class filterClass = NSClassFromString(@"CAFilter");
    if (!filterClass) return nil;

    id filter = nil;
    for (NSString *factoryName in @[@"filterWithType:", @"filterWithName:"]) {
        SEL factory = NSSelectorFromString(factoryName);
        if (![filterClass respondsToSelector:factory]) continue;
        id (*fn)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))[filterClass methodForSelector:factory];
        filter = fn ? fn(filterClass, factory, @"colorSaturate") : nil;
        if (filter) break;
    }
    if (!filter) return nil;

    @try {
        [filter setValue:@0.0 forKey:@"inputAmount"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return @[filter];
}

static void RLApplyRenderingModeToWindow(UIWindow *window) {
    if (!window) return;

    id stored = objc_getAssociatedObject(window, kRLOriginalFiltersKey);
    if (!stored) {
        NSArray *original = window.layer.filters;
        objc_setAssociatedObject(window,
                                 kRLOriginalFiltersKey,
                                 original ?: (id)[NSNull null],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (gBooksReaderState == RLReaderStateMono) {
        NSArray *mono = RLCreateMonoFilters();
        if (mono) window.layer.filters = mono;
    } else {
        id original = objc_getAssociatedObject(window, kRLOriginalFiltersKey);
        window.layer.filters = (original && original != (id)[NSNull null]) ? original : nil;
    }
}

static void RLApplyRenderingModeToAllWindows(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in RLApplicationWindows()) {
            RLApplyRenderingModeToWindow(window);
        }
    });
}

#pragma mark - Authenticated exit

@interface RLExitGestureHandler : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, assign) BOOL authenticating;
+ (instancetype)shared;
- (void)authenticatedExitGesture:(UILongPressGestureRecognizer *)recognizer;
- (void)emergencyExitGesture:(UILongPressGestureRecognizer *)recognizer;
@end

@implementation RLExitGestureHandler

+ (instancetype)shared {
    static RLExitGestureHandler *handler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handler = [RLExitGestureHandler new];
    });
    return handler;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)authenticatedExitGesture:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan || !RLBooksActive() || self.authenticating) return;

    self.authenticating = YES;
    LAContext *context = [LAContext new];
    context.localizedCancelTitle = @"Keep Reading";

    NSError *error = nil;
    if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        self.authenticating = NO;
        RLPostCommand(RLAuthEndNotification);

        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"Reader Lock"
                message:@"Touch ID/device-passcode authentication is unavailable. Use the 3-finger 8-second emergency hold, respring, or reboot to leave Reader Lock."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];

            UIViewController *vc = nil;
            for (UIWindow *window in RLApplicationWindows()) {
                if (window.isKeyWindow) { vc = window.rootViewController; break; }
            }
            while (vc.presentedViewController) vc = vc.presentedViewController;
            [vc presentViewController:alert animated:YES completion:nil];
        });
        return;
    }

    RLPostCommand(RLAuthBeginNotification);
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:@"Exit Reader Lock and restore the iPhone"
                      reply:^(BOOL success, NSError *authError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.authenticating = NO;
            if (success) {
                RLPostCommand(RLCommandExitNotification);
            } else {
                RLPostCommand(RLAuthEndNotification);
                NSLog(@"[ReaderLock] exit authentication failed/cancelled: %@", authError);
            }
        });
    }];
}

- (void)emergencyExitGesture:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan || !RLBooksActive()) return;
    NSLog(@"[ReaderLock] emergency exit gesture used");
    RLPostCommand(RLCommandExitNotification);
}

@end

static void RLInstallExitGestures(UIWindow *window) {
    if (!window || objc_getAssociatedObject(window, kRLGesturesInstalledKey)) return;
    objc_setAssociatedObject(window, kRLGesturesInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    RLExitGestureHandler *handler = [RLExitGestureHandler shared];

    // Normal exit: hold TWO fingers for 2.5 s, then authenticate with Touch ID/passcode.
    UILongPressGestureRecognizer *authenticated = [[UILongPressGestureRecognizer alloc]
        initWithTarget:handler action:@selector(authenticatedExitGesture:)];
    authenticated.minimumPressDuration = 2.5;
    authenticated.numberOfTouchesRequired = 2;
    authenticated.cancelsTouchesInView = NO;
    authenticated.delaysTouchesBegan = NO;
    authenticated.delegate = handler;
    [window addGestureRecognizer:authenticated];

    // Fail-safe only: hold THREE fingers for 8 s. No authentication.
    // This prevents a missing/disabled passcode or LocalAuthentication failure from trapping the user.
    UILongPressGestureRecognizer *emergency = [[UILongPressGestureRecognizer alloc]
        initWithTarget:handler action:@selector(emergencyExitGesture:)];
    emergency.minimumPressDuration = 8.0;
    emergency.numberOfTouchesRequired = 3;
    emergency.cancelsTouchesInView = NO;
    emergency.delaysTouchesBegan = NO;
    emergency.delegate = handler;
    [window addGestureRecognizer:emergency];
}

#pragma mark - Keep the reader self-contained

static BOOL RLURLIsExternal(id urlObject) {
    if (![urlObject isKindOfClass:[NSURL class]]) return YES;
    NSString *scheme = ((NSURL *)urlObject).scheme.lowercaseString ?: @"";
    // file: stays inside the reader. http(s) and other schemes hand off to another app.
    // The reader's own URLSession downloads are not openURL and are not affected.
    if (scheme.length == 0 || [scheme isEqualToString:@"file"]) return NO;
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:RLBooksBundleIdentifier]) {
        return !([scheme isEqualToString:@"ibooks"] || [scheme isEqualToString:@"itms-books"]);
    }
    return YES;
}

static BOOL RLBundleIsThisProcess(id bundleID) {
    if (![bundleID isKindOfClass:[NSString class]]) return NO;
    NSString *mine = [NSBundle mainBundle].bundleIdentifier;
    return mine.length && [bundleID isEqualToString:mine];
}

static BOOL RLIsEscapeViewController(UIViewController *vc) {
    if (!vc) return NO;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return RLIsEscapeViewController(((UINavigationController *)vc).visibleViewController);
    }
    if ([vc isKindOfClass:[UIActivityViewController class]]) return YES;

    NSString *name = NSStringFromClass([vc class]);
    static NSArray<NSString *> *blockedNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blockedNames = @[
            @"SFSafariViewController",
            @"UIDocumentPickerViewController",
            @"MFMailComposeViewController",
            @"MFMessageComposeViewController",
            @"SKStoreProductViewController"
        ];
    });

    for (NSString *blocked in blockedNames) {
        if ([name rangeOfString:blocked options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent
                     animated:(BOOL)flag
                   completion:(void (^)(void))completion {
    if (RLBooksActive() && RLIsEscapeViewController(viewControllerToPresent)) {
        NSLog(@"[ReaderLock] blocked reader escape UI %@", NSStringFromClass([viewControllerToPresent class]));
        if (completion) completion();
        return;
    }
    %orig;
}

%end

%hook UIApplication

- (BOOL)openURL:(NSURL *)url {
    if (RLBooksActive() && RLURLIsExternal(url)) {
        NSLog(@"[ReaderLock] blocked legacy external URL from reader: %@", url);
        return NO;
    }
    return %orig;
}

- (void)openURL:(NSURL *)url
        options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options
completionHandler:(void (^)(BOOL success))completion {
    if (RLBooksActive() && RLURLIsExternal(url)) {
        NSLog(@"[ReaderLock] blocked external URL from reader: %@", url);
        if (completion) completion(NO);
        return;
    }
    %orig;
}

%end

// The reader can leave through LaunchServices without touching UIApplication.
// These hooks run in whichever reader process this dylib was injected into.
// SpringBoard is a different process and still uses this class to reopen the reader.
%hook LSApplicationWorkspace

- (BOOL)openURL:(id)url {
    if (RLBooksActive() && RLURLIsExternal(url)) {
        NSLog(@"[ReaderLock] blocked LaunchServices URL from reader: %@", url);
        return NO;
    }
    return %orig;
}

- (BOOL)openURL:(id)url withOptions:(id)options {
    if (RLBooksActive() && RLURLIsExternal(url)) {
        NSLog(@"[ReaderLock] blocked LaunchServices URL from reader: %@", url);
        return NO;
    }
    return %orig;
}

- (BOOL)openURL:(id)url withOptions:(id)options error:(NSError **)error {
    if (RLBooksActive() && RLURLIsExternal(url)) {
        NSLog(@"[ReaderLock] blocked LaunchServices URL from reader: %@", url);
        if (error) *error = nil;
        return NO;
    }
    return %orig;
}

- (BOOL)openSensitiveURL:(id)url withOptions:(id)options {
    if (RLBooksActive() && RLURLIsExternal(url)) {
        NSLog(@"[ReaderLock] blocked sensitive URL from reader: %@", url);
        return NO;
    }
    return %orig;
}

- (BOOL)openSensitiveURL:(id)url withOptions:(id)options error:(NSError **)error {
    if (RLBooksActive() && RLURLIsExternal(url)) {
        NSLog(@"[ReaderLock] blocked sensitive URL from reader: %@", url);
        if (error) *error = nil;
        return NO;
    }
    return %orig;
}

- (void)openURL:(id)url configuration:(id)configuration completionHandler:(void (^)(BOOL success))completion {
    if (RLBooksActive() && RLURLIsExternal(url)) {
        NSLog(@"[ReaderLock] blocked configured URL from reader: %@", url);
        if (completion) completion(NO);
        return;
    }
    %orig;
}

- (BOOL)openApplicationWithBundleID:(id)bundleID {
    if (RLBooksActive() && !RLBundleIsThisProcess(bundleID)) {
        NSLog(@"[ReaderLock] blocked LaunchServices app open from reader: %@", bundleID);
        return NO;
    }
    return %orig;
}

- (void)openApplicationWithBundleIdentifier:(id)bundleID configuration:(id)configuration completionHandler:(void (^)(BOOL success))completion {
    if (RLBooksActive() && !RLBundleIsThisProcess(bundleID)) {
        NSLog(@"[ReaderLock] blocked LaunchServices app open from reader: %@", bundleID);
        if (completion) completion(NO);
        return;
    }
    %orig;
}

%end

#pragma mark - Window lifecycle

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    RLInstallExitGestures(self);
    RLApplyRenderingModeToWindow(self);
}

- (void)becomeKeyWindow {
    %orig;
    RLInstallExitGestures(self);
    RLApplyRenderingModeToWindow(self);
}

%end

%ctor {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        %init;
        NSLog(@"[ReaderLock] reader component loaded in %@", [NSBundle mainBundle].bundleIdentifier);

        gBooksReaderState = RLReadDarwinState();
        notify_register_dispatch(RLStateNotification, &gBooksStateToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t state = RLReaderStateOff;
            notify_get_state(token, &state);
            gBooksReaderState = (RLReaderState)state;
            RLApplyRenderingModeToAllWindows();
        });

        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIWindow *window in RLApplicationWindows()) {
                RLInstallExitGestures(window);
                RLApplyRenderingModeToWindow(window);
            }
        });
    }
}
