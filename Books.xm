#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <netinet/in.h>
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

#pragma mark - Status bar and bottom line

@interface RLBottomBarWindow : UIWindow
@end

// A hook on UIViewController's own method does not run when Books or MapleRead
// overrides it. Replace each class's own implementation so the override returns
// hidden while Reader Lock is on, and the original answer otherwise.
static NSMutableSet<NSString *> *gHookedStatusBarHidden = nil;
static NSMutableSet<NSString *> *gHookedStatusBarAnimation = nil;

static BOOL RLInheritsViewController(Class cls) {
    Class viewController = [UIViewController class];
    while (cls) {
        if (cls == viewController) return YES;
        cls = class_getSuperclass(cls);
    }
    return NO;
}

static void RLHookStatusMethod(Class cls, SEL sel, NSMutableSet<NSString *> *hooked, BOOL hiddenMethod) {
    if (!cls || !hooked) return;
    NSString *name = NSStringFromClass(cls);
    if ([hooked containsObject:name]) return;
    [hooked addObject:name];

    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (sel_isEqual(method_getName(list[i]), sel)) {
            found = list[i];
            break;
        }
    }
    free(list);
    if (!found) return;

    const char *encoding = method_getTypeEncoding(found);
    if (hiddenMethod) {
        if (!encoding || (strcmp(encoding, "B@:") != 0 && strcmp(encoding, "c@:") != 0)) return;
        BOOL (*original)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(found);
        IMP replacement = imp_implementationWithBlock(^BOOL(id self) {
            if (RLBooksActive()) return YES;
            return original(self, sel);
        });
        method_setImplementation(found, replacement);
        return;
    }

    if (!encoding || (strcmp(encoding, "q@:") != 0 && strcmp(encoding, "i@:") != 0)) return;
    NSInteger (*original)(id, SEL) = (NSInteger (*)(id, SEL))method_getImplementation(found);
    IMP replacement = imp_implementationWithBlock(^NSInteger(id self) {
        if (RLBooksActive()) return UIStatusBarAnimationNone;
        return original(self, sel);
    });
    method_setImplementation(found, replacement);
}

static void RLHookStatusMethods(Class cls) {
    if (!gHookedStatusBarHidden) gHookedStatusBarHidden = [NSMutableSet set];
    if (!gHookedStatusBarAnimation) gHookedStatusBarAnimation = [NSMutableSet set];
    RLHookStatusMethod(cls, @selector(prefersStatusBarHidden), gHookedStatusBarHidden, YES);
    RLHookStatusMethod(cls, @selector(preferredStatusBarUpdateAnimation), gHookedStatusBarAnimation, NO);
}

static void RLScanStatusBarControllers(void) {
    RLHookStatusMethods([UIViewController class]);
    int capacity = objc_getClassList(NULL, 0);
    if (capacity <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)capacity);
    if (!classes) return;
    int reported = objc_getClassList(classes, capacity);
    int limit = reported < capacity ? reported : capacity;
    for (int i = 0; i < limit; i++) {
        Class cls = classes[i];
        if (!cls || cls == [UIViewController class] || !RLInheritsViewController(cls)) continue;
        RLHookStatusMethods(cls);
    }
    free(classes);
}

static void RLRefreshStatusBarAppearance(void) {
    for (UIWindow *window in RLApplicationWindows()) {
        if ([window isKindOfClass:[RLBottomBarWindow class]]) continue;
        UIViewController *controller = window.rootViewController;
        while (controller) {
            [controller setNeedsStatusBarAppearanceUpdate];
            controller = controller.presentedViewController;
        }
    }
}

@implementation RLBottomBarWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}

- (void)makeKeyWindow {}

- (void)becomeKeyWindow {}

@end

@interface RLBottomBarController : UIViewController
@property(nonatomic, strong) UILabel *statusLabel;
@end

@implementation RLBottomBarController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.userInteractionEnabled = NO;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 1;
    label.userInteractionEnabled = NO;
    [self.view addSubview:label];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [label.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [label.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4],
        [label.heightAnchor constraintEqualToConstant:20],
    ]];
    self.statusLabel = label;
}

- (BOOL)prefersStatusBarHidden {
    return RLBooksActive();
}

@end

static RLBottomBarWindow *gBottomBarWindow = nil;
static UILabel *gBottomBarLabel = nil;
static NSTimer *gBottomBarTimer = nil;
static SCNetworkReachabilityRef gBottomBarReachability = NULL;

static NSString *RLBottomBarTime(void) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"HH:mm";
    });
    return [formatter stringFromDate:[NSDate date]];
}

static NSString *RLBottomBarNetwork(void) {
    SCNetworkReachabilityFlags flags = 0;
    if (!gBottomBarReachability || !SCNetworkReachabilityGetFlags(gBottomBarReachability, &flags)) return @"—";
    BOOL reachable = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
    BOOL cellular = (flags & kSCNetworkReachabilityFlagsIsWWAN) != 0;
    return (reachable && !cellular) ? @"Wi-Fi" : @"—";
}

static void RLUpdateBottomBarText(void) {
    if (!gBottomBarLabel) return;
    float level = [UIDevice currentDevice].batteryLevel;
    NSString *battery = level < 0 ? @"—" : [NSString stringWithFormat:@"%ld%%", (long)lroundf(level * 100.f)];
    gBottomBarLabel.text = [NSString stringWithFormat:@"%@   •   %@   •   %@",
                            RLBottomBarTime(), RLBottomBarNetwork(), battery];
}

static void RLScheduleBottomBarTimer(void) {
    [gBottomBarTimer invalidate];
    gBottomBarTimer = nil;
    if (!RLBooksActive()) return;

    NSDate *now = [NSDate date];
    NSDate *next = [[NSCalendar currentCalendar] nextDateAfterDate:now
                                                        matchingUnit:NSCalendarUnitSecond
                                                               value:0
                                                             options:NSCalendarMatchNextTime];
    NSTimeInterval delay = 30;
    if (next) {
        delay = [next timeIntervalSinceDate:now];
        if (delay < 0.5) delay += 60;
    }
    gBottomBarTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(__unused NSTimer *timer) {
        RLUpdateBottomBarText();
        RLScheduleBottomBarTimer();
    }];
    [[NSRunLoop mainRunLoop] addTimer:gBottomBarTimer forMode:NSRunLoopCommonModes];
}

static UIWindowScene *RLForegroundScene(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive ||
            scene.activationState == UISceneActivationStateForegroundInactive) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static void RLUpdateBottomBarVisibility(void);

static void RLReachabilityChanged(__unused SCNetworkReachabilityRef target, __unused SCNetworkReachabilityFlags flags, __unused void *info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (RLBooksActive()) RLUpdateBottomBarText();
    });
}

static void RLStartBottomBarSignals(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSOperationQueue *main = [NSOperationQueue mainQueue];
        [center addObserverForName:UIDeviceBatteryLevelDidChangeNotification object:nil queue:main usingBlock:^(__unused NSNotification *note) {
            if (RLBooksActive()) RLUpdateBottomBarText();
        }];
        [center addObserverForName:UIDeviceBatteryStateDidChangeNotification object:nil queue:main usingBlock:^(__unused NSNotification *note) {
            if (RLBooksActive()) RLUpdateBottomBarText();
        }];
        [center addObserverForName:UISceneDidActivateNotification object:nil queue:main usingBlock:^(__unused NSNotification *note) {
            RLUpdateBottomBarVisibility();
        }];

        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        gBottomBarReachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&address);
        if (gBottomBarReachability) {
            SCNetworkReachabilityContext context = {0};
            SCNetworkReachabilitySetCallback(gBottomBarReachability, RLReachabilityChanged, &context);
            SCNetworkReachabilityScheduleWithRunLoop(gBottomBarReachability, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        }
    });
}

static void RLUpdateBottomBarVisibility(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RLUpdateBottomBarVisibility();
        });
        return;
    }
    RLStartBottomBarSignals();
    if (!RLBooksActive()) {
        gBottomBarWindow.hidden = YES;
        [gBottomBarTimer invalidate];
        gBottomBarTimer = nil;
        RLRefreshStatusBarAppearance();
        return;
    }

    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    RLScanStatusBarControllers();

    UIWindowScene *scene = RLForegroundScene();
    if (!scene) {
        RLRefreshStatusBarAppearance();
        return;
    }
    if (!gBottomBarWindow) {
        gBottomBarWindow = [[RLBottomBarWindow alloc] initWithWindowScene:scene];
        gBottomBarWindow.backgroundColor = [UIColor clearColor];
        gBottomBarWindow.userInteractionEnabled = NO;
        gBottomBarWindow.windowLevel = UIWindowLevelStatusBar + 1;
        RLBottomBarController *root = [RLBottomBarController new];
        gBottomBarWindow.rootViewController = root;
        gBottomBarLabel = root.statusLabel;
    } else if (gBottomBarWindow.windowScene != scene) {
        gBottomBarWindow.windowScene = scene;
    }
    gBottomBarWindow.hidden = NO;
    RLUpdateBottomBarText();
    RLScheduleBottomBarTimer();
    RLApplyRenderingModeToWindow(gBottomBarWindow);
    RLRefreshStatusBarAppearance();
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
    if (!window || [window isKindOfClass:[RLBottomBarWindow class]] || objc_getAssociatedObject(window, kRLGesturesInstalledKey)) return;
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

%hook UIViewController

- (instancetype)init {
    id result = %orig;
    if (result) RLHookStatusMethods(object_getClass(result));
    return result;
}

- (instancetype)initWithNibName:(NSString *)name bundle:(NSBundle *)bundle {
    id result = %orig;
    if (result) RLHookStatusMethods(object_getClass(result));
    return result;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    id result = %orig;
    if (result) RLHookStatusMethods(object_getClass(result));
    return result;
}

%end

%hook UIStatusBarManager

- (BOOL)isStatusBarHidden {
    if (RLBooksActive()) return YES;
    return %orig;
}

- (CGRect)statusBarFrame {
    if (RLBooksActive()) return CGRectZero;
    return %orig;
}

%end

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
            RLUpdateBottomBarVisibility();
        });

        RLScanStatusBarControllers();

        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIWindow *window in RLApplicationWindows()) {
                RLInstallExitGestures(window);
                RLApplyRenderingModeToWindow(window);
            }
            RLUpdateBottomBarVisibility();
        });
    }
}
