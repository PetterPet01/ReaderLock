#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>
#import <string.h>
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

static const CGFloat kRLReaderBottomBand = 22.0;

@interface RLBottomBarWindow : UIWindow
@end

// UIKit walks childViewControllerForStatusBarHidden until a controller returns
// nil, then asks prefersStatusBarHidden there. Home and the open book already
// answer hidden. Returning nil from the tab bar stops that walk early, and the
// tab bar's own answer is visible, which is why 0.1.11 showed the clock on
// every screen. Leave the walk alone. Every UIViewController subclass answers
// hidden while Reader Lock is on: owners are replaced, and classes that never
// implemented the method get one, so Exchange cannot keep the native bar up.
// Appear methods that MapleRead owns still refresh that answer, because a
// Logos hook on UIViewController does not run when those overrides skip super.
// A miss is not remembered: a newer method list can be invisible to
// class_copyMethodList and still be the one objc_msgSend runs.
static const void *kRLOrigPrefersHidden = &kRLOrigPrefersHidden;
static const void *kRLOrigStatusAnimation = &kRLOrigStatusAnimation;
static const void *kRLOrigSetHidden = &kRLOrigSetHidden;
static const void *kRLOrigSetAlpha = &kRLOrigSetAlpha;
static const void *kRLOrigLayout = &kRLOrigLayout;
static const void *kRLOrigViewWillAppear = &kRLOrigViewWillAppear;
static const void *kRLOrigViewDidAppear = &kRLOrigViewDidAppear;
static void RLSuppressStatusBarView(UIView *view);
static void RLApplySystemStatusBarHidden(BOOL hidden);
static void RLQueueBottomBarRefresh(void);
static void RLHookStatusMethods(Class cls);

@interface RLBottomBarController : UIViewController
@property(nonatomic, strong) UILabel *statusLabel;
@end

static BOOL RLInheritsViewController(Class cls) {
    Class viewController = [UIViewController class];
    while (cls) {
        if (cls == viewController) return YES;
        cls = class_getSuperclass(cls);
    }
    return NO;
}

// MapleRead is compiled with a newer clang than the iOS 15 SDK headers. Its
// overrides are encoded "B16@0:8", not "B@:", so a string compare skips the
// class that actually owns the status bar and leaves a black strip on screen.
static BOOL RLIsNoArgGetter(Method method, char a, char b, char c, char d) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char ret[8] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    char type = ret[0];
    return type && (type == a || type == b || type == c || type == d);
}

static BOOL RLIsVoidMethod(Method method, unsigned args) {
    if (!method || method_getNumberOfArguments(method) != args) return NO;
    char ret[8] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    return ret[0] == 'v';
}

static BOOL RLClassOwnsInstanceMethod(Class cls, SEL sel) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    Class supercls = class_getSuperclass(cls);
    if (!supercls) return YES;
    return class_getInstanceMethod(supercls, sel) != method;
}

static void *RLOriginalIMP(id self, const void *key) {
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls)) {
        NSValue *saved = objc_getAssociatedObject(cls, key);
        if (saved) return saved.pointerValue;
    }
    return NULL;
}

static void RLNoteStatusBarKeptHidden(void) {
    static BOOL logged = NO;
    if (logged) return;
    logged = YES;
    NSLog(@"[ReaderLock] status bar kept hidden");
}

static BOOL RLForcedPrefersStatusBarHidden(id self, SEL cmd) {
    if (RLBooksActive()) {
        RLNoteStatusBarKeptHidden();
        return YES;
    }
    BOOL (*original)(id, SEL) = (BOOL (*)(id, SEL))RLOriginalIMP(self, kRLOrigPrefersHidden);
    return original ? original(self, cmd) : NO;
}

static NSInteger RLForcedStatusBarAnimation(id self, SEL cmd) {
    if (RLBooksActive()) return UIStatusBarAnimationNone;
    NSInteger (*original)(id, SEL) = (NSInteger (*)(id, SEL))RLOriginalIMP(self, kRLOrigStatusAnimation);
    return original ? original(self, cmd) : UIStatusBarAnimationNone;
}

static void RLForcedStatusBarViewHidden(id self, SEL cmd, BOOL hidden) {
    if (RLBooksActive()) hidden = YES;
    void (*original)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))RLOriginalIMP(self, kRLOrigSetHidden);
    if (original) original(self, cmd, hidden);
}

static void RLForcedStatusBarViewAlpha(id self, SEL cmd, CGFloat alpha) {
    if (RLBooksActive()) alpha = 0;
    void (*original)(id, SEL, CGFloat) = (void (*)(id, SEL, CGFloat))RLOriginalIMP(self, kRLOrigSetAlpha);
    if (original) original(self, cmd, alpha);
}

static void RLForcedStatusBarLayout(id self, SEL cmd) {
    void (*original)(id, SEL) = (void (*)(id, SEL))RLOriginalIMP(self, kRLOrigLayout);
    if (original) original(self, cmd);
    if (RLBooksActive()) RLSuppressStatusBarView(self);
}

static void RLInstallOwnedMethod(Class cls, SEL sel, IMP replacement, const void *key, BOOL (*accepts)(Method)) {
    if (!cls || !replacement || !RLClassOwnsInstanceMethod(cls, sel)) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || (accepts && !accepts(method))) return;
    IMP current = method_getImplementation(method);
    if (current == replacement) return;
    if (!objc_getAssociatedObject(cls, key)) {
        objc_setAssociatedObject(cls, key, [NSValue valueWithPointer:(void *)current], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    method_setImplementation(method, replacement);
}

static BOOL RLAcceptsHiddenGetter(Method method) {
    return RLIsNoArgGetter(method, 'B', 'c', 0, 0);
}

static BOOL RLAcceptsAnimationGetter(Method method) {
    return RLIsNoArgGetter(method, 'q', 'i', 'l', 'Q');
}

static BOOL RLAcceptsVoidSetter(Method method) {
    return RLIsVoidMethod(method, 3);
}

static BOOL RLAcceptsLayout(Method method) {
    return RLIsVoidMethod(method, 2);
}

static void RLForcedViewWillAppear(id self, SEL cmd, BOOL animated) {
    void (*original)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))RLOriginalIMP(self, kRLOrigViewWillAppear);
    if (original) original(self, cmd, animated);
    if (!RLBooksActive() || [self isKindOfClass:[RLBottomBarController class]]) return;
    RLHookStatusMethods(object_getClass(self));
    [(UIViewController *)self setNeedsStatusBarAppearanceUpdate];
    RLApplySystemStatusBarHidden(YES);
}

static void RLForcedViewDidAppear(id self, SEL cmd, BOOL animated) {
    void (*original)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))RLOriginalIMP(self, kRLOrigViewDidAppear);
    if (original) original(self, cmd, animated);
    if ([self isKindOfClass:[RLBottomBarController class]]) return;
    if (RLBooksActive()) {
        RLHookStatusMethods(object_getClass(self));
        [(UIViewController *)self setNeedsStatusBarAppearanceUpdate];
        RLApplySystemStatusBarHidden(YES);
    }
    RLQueueBottomBarRefresh();
}

static BOOL RLAcceptsAppear(Method method) {
    return RLIsVoidMethod(method, 3);
}

static void RLEnsurePrefersHidden(Class cls) {
    if (!cls) return;
    SEL sel = @selector(prefersStatusBarHidden);
    if (RLClassOwnsInstanceMethod(cls, sel)) {
        RLInstallOwnedMethod(cls, sel, (IMP)RLForcedPrefersStatusBarHidden, kRLOrigPrefersHidden, RLAcceptsHiddenGetter);
        return;
    }
    if (cls == [UIViewController class]) return;
    Method inherited = class_getInstanceMethod(cls, sel);
    IMP inheritedIMP = inherited ? method_getImplementation(inherited) : NULL;
    if (inheritedIMP && inheritedIMP != (IMP)RLForcedPrefersStatusBarHidden && !objc_getAssociatedObject(cls, kRLOrigPrefersHidden)) {
        objc_setAssociatedObject(cls, kRLOrigPrefersHidden, [NSValue valueWithPointer:(void *)inheritedIMP], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    class_addMethod(cls, sel, (IMP)RLForcedPrefersStatusBarHidden, "B16@0:8");
}

static void RLHookStatusMethods(Class cls) {
    static BOOL hookedRoot = NO;
    if (!hookedRoot) {
        hookedRoot = YES;
        RLInstallOwnedMethod([UIViewController class], @selector(prefersStatusBarHidden), (IMP)RLForcedPrefersStatusBarHidden, kRLOrigPrefersHidden, RLAcceptsHiddenGetter);
        RLInstallOwnedMethod([UIViewController class], @selector(preferredStatusBarUpdateAnimation), (IMP)RLForcedStatusBarAnimation, kRLOrigStatusAnimation, RLAcceptsAnimationGetter);
    }
    if (!cls || cls == [UIViewController class]) return;
    RLEnsurePrefersHidden(cls);
    RLInstallOwnedMethod(cls, @selector(preferredStatusBarUpdateAnimation), (IMP)RLForcedStatusBarAnimation, kRLOrigStatusAnimation, RLAcceptsAnimationGetter);
    RLInstallOwnedMethod(cls, @selector(viewWillAppear:), (IMP)RLForcedViewWillAppear, kRLOrigViewWillAppear, RLAcceptsAppear);
    RLInstallOwnedMethod(cls, @selector(viewDidAppear:), (IMP)RLForcedViewDidAppear, kRLOrigViewDidAppear, RLAcceptsAppear);
}

// Do not cache this in dispatch_once. The first call can run before UIKit has
// realized the status-bar classes, and a once-block would then remember an
// empty list for the rest of the process. The answer is stored on the class
// the first time that class is actually seen.
static char kRLStatusBarClassCacheKey;

static BOOL RLClassIsStatusBarClass(Class cls) {
    if (!cls) return NO;
    NSNumber *cached = objc_getAssociatedObject(cls, &kRLStatusBarClassCacheKey);
    if (cached) return cached.boolValue;
    BOOL match = NO;
    for (Class cursor = cls; cursor && cursor != [UIView class]; cursor = class_getSuperclass(cursor)) {
        const char *name = class_getName(cursor);
        if (!name) continue;
        if (strncmp(name, "UIStatusBar", 11) == 0 || strncmp(name, "_UIStatusBar", 12) == 0) {
            match = YES;
            break;
        }
    }
    objc_setAssociatedObject(cls, &kRLStatusBarClassCacheKey, @(match), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return match;
}

// Only a status-bar class that implements the method itself is replaced. One
// that inherits UIView's method is handled by the UIView hook, which refuses
// every other view. Hooking the inherited method here would attach to UIView
// and hide the whole screen.
static void RLHookStatusBarViewClass(Class cls) {
    if (!RLClassIsStatusBarClass(cls)) return;
    RLInstallOwnedMethod(cls, @selector(setHidden:), (IMP)RLForcedStatusBarViewHidden, kRLOrigSetHidden, RLAcceptsVoidSetter);
    RLInstallOwnedMethod(cls, @selector(setAlpha:), (IMP)RLForcedStatusBarViewAlpha, kRLOrigSetAlpha, RLAcceptsVoidSetter);
    RLInstallOwnedMethod(cls, @selector(layoutSubviews), (IMP)RLForcedStatusBarLayout, kRLOrigLayout, RLAcceptsLayout);
}

static void RLHookStatusBarViewSetters(void) {
    static const char *names[] = {
        "UIStatusBar",
        "UIStatusBarWindow",
        "_UIStatusBar",
        "UIStatusBar_Modern",
        "UIStatusBar_Base",
        "UIStatusBar_Placeholder",
        "UIStatusBarForegroundView",
        "UIStatusBarBackgroundView",
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        Class cls = objc_getClass(names[i]);
        if (cls) RLHookStatusBarViewClass(cls);
    }
}

static void RLScanStatusBarControllers(void) {
    RLHookStatusBarViewSetters();
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

static BOOL RLIsSystemStatusBarView(UIView *view) {
    return RLClassIsStatusBarClass(object_getClass(view));
}

static char kRLStatusBarSavedKey;

static void RLSetSystemStatusBarView(UIView *view, BOOL hidden) {
    if (RLIsSystemStatusBarView(view)) {
        if (hidden) {
            if (!objc_getAssociatedObject(view, &kRLStatusBarSavedKey)) {
                UIColor *color = view.backgroundColor;
                objc_setAssociatedObject(view, &kRLStatusBarSavedKey, @{
                    @"a": @(view.alpha),
                    @"h": @(view.hidden),
                    @"c": color ?: (id)[NSNull null],
                }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            view.backgroundColor = [UIColor clearColor];
            view.opaque = NO;
            view.alpha = 0;
            view.hidden = YES;
        } else {
            NSDictionary *saved = objc_getAssociatedObject(view, &kRLStatusBarSavedKey);
            if (saved) {
                view.alpha = [saved[@"a"] doubleValue];
                view.hidden = [saved[@"h"] boolValue];
                id color = saved[@"c"];
                view.backgroundColor = (color == [NSNull null]) ? nil : color;
                objc_setAssociatedObject(view, &kRLStatusBarSavedKey, nil, OBJC_ASSOCIATION_ASSIGN);
            }
        }
    }
    for (UIView *subview in view.subviews) RLSetSystemStatusBarView(subview, hidden);
}

static void RLApplySystemStatusBarHidden(BOOL hidden) {
    for (UIWindow *window in RLApplicationWindows()) {
        if ([window isKindOfClass:[RLBottomBarWindow class]]) continue;
        RLSetSystemStatusBarView(window, hidden);
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[UIApplication sharedApplication] setStatusBarHidden:hidden withAnimation:UIStatusBarAnimationNone];
#pragma clang diagnostic pop
}

static void RLSuppressStatusBarView(UIView *view) {
    if (!RLBooksActive() || !view) return;
    if (view.hidden && view.alpha == 0) return;
    static BOOL inside = NO;
    if (inside) return;
    inside = YES;
    view.alpha = 0;
    view.hidden = YES;
    inside = NO;
}

@implementation RLBottomBarWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}

- (void)makeKeyWindow {}

- (void)becomeKeyWindow {}

@end

@implementation RLBottomBarController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.opaque = NO;
    self.view.userInteractionEnabled = NO;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 1;
    label.userInteractionEnabled = NO;
    label.backgroundColor = [UIColor clearColor];
    label.opaque = NO;
    [self.view addSubview:label];
    self.statusLabel = label;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (self.view.window && !CGRectEqualToRect(self.view.frame, self.view.window.bounds)) {
        self.view.frame = self.view.window.bounds;
    }
    self.statusLabel.frame = CGRectInset(self.view.bounds, 8, 0);
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    UIWindow *window = self.view.window;
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        if (!window) return;
        CGRect bounds = window.windowScene ? window.windowScene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
        window.frame = CGRectMake(bounds.origin.x, CGRectGetMaxY(bounds) - kRLReaderBottomBand, bounds.size.width, kRLReaderBottomBand);
    }];
}

- (UIRectEdge)edgesForExtendedLayout {
    return UIRectEdgeAll;
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

static UIWindowScene *RLForegroundScene(void);

static CGRect RLBottomStripFrame(UIWindowScene *scene) {
    CGRect bounds = scene ? scene.coordinateSpace.bounds : CGRectZero;
    if (CGRectIsEmpty(bounds)) bounds = UIScreen.mainScreen.bounds;
    return CGRectMake(bounds.origin.x, CGRectGetMaxY(bounds) - kRLReaderBottomBand, bounds.size.width, kRLReaderBottomBand);
}

static void RLPlaceBottomBarWindow(void) {
    if (!gBottomBarWindow) return;
    CGRect frame = RLBottomStripFrame(gBottomBarWindow.windowScene ?: RLForegroundScene());
    if (!CGRectEqualToRect(gBottomBarWindow.frame, frame)) gBottomBarWindow.frame = frame;
}

static void RLUpdateBottomBarText(void) {
    if (!gBottomBarLabel) {
        UIViewController *root = gBottomBarWindow.rootViewController;
        [root loadViewIfNeeded];
        if ([root isKindOfClass:[RLBottomBarController class]]) {
            gBottomBarLabel = ((RLBottomBarController *)root).statusLabel;
        }
    }
    if (!gBottomBarLabel) return;
    RLPlaceBottomBarWindow();
    float level = [UIDevice currentDevice].batteryLevel;
    NSString *battery = level < 0 ? @"—" : [NSString stringWithFormat:@"%ld%%", (long)lroundf(level * 100.f)];
    gBottomBarLabel.textColor = [UIColor secondaryLabelColor];
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
static void RLInstallReaderChromeHooks(void);
static void RLApplyReaderChromeNow(void);
static void RLRestoreAllReaderChrome(void);
static BOOL RLReadingScreenIsVisible(void);

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
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:^(__unused NSNotification *note) {
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

static int gBottomBarAttachAttempts = 0;

static void RLScheduleBottomBarAttachRetry(void) {
    if (gBottomBarWindow || !RLBooksActive() || gBottomBarAttachAttempts >= 4) return;
    gBottomBarAttachAttempts++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RLUpdateBottomBarVisibility();
    });
}

static void RLConfigureBottomBarWindow(RLBottomBarWindow *window) {
    window.opaque = NO;
    window.backgroundColor = [UIColor clearColor];
    window.layer.opaque = NO;
    window.userInteractionEnabled = NO;
    window.clipsToBounds = YES;
    window.windowLevel = UIWindowLevelStatusBar + 1;
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
        gBottomBarAttachAttempts = 0;
        gBottomBarWindow.hidden = YES;
        [gBottomBarTimer invalidate];
        gBottomBarTimer = nil;
        RLApplySystemStatusBarHidden(NO);
        RLRefreshStatusBarAppearance();
        RLRestoreAllReaderChrome();
        return;
    }

    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    RLScanStatusBarControllers();
    RLRefreshStatusBarAppearance();
    RLApplySystemStatusBarHidden(YES);
    RLInstallReaderChromeHooks();
    RLApplyReaderChromeNow();

    // The time line is a window of its own, so it would sit on the library too.
    // MapleRead's open book is the only screen that should show it.
    if (!RLReadingScreenIsVisible()) {
        gBottomBarAttachAttempts = 0;
        if (gBottomBarWindow) gBottomBarWindow.hidden = YES;
        [gBottomBarTimer invalidate];
        gBottomBarTimer = nil;
        static BOOL loggedHide = NO;
        if (!loggedHide) {
            loggedHide = YES;
            NSLog(@"[ReaderLock] bottom line hidden off the book");
        }
        return;
    }

    BOOL hasScenes = NO;
    for (UIScene *existing in [UIApplication sharedApplication].connectedScenes) {
        if ([existing isKindOfClass:[UIWindowScene class]]) {
            hasScenes = YES;
            break;
        }
    }
    UIWindowScene *scene = RLForegroundScene();
    if (!scene && hasScenes) {
        RLScheduleBottomBarAttachRetry();
        return;
    }
    if (!gBottomBarWindow) {
        if (scene) {
            gBottomBarWindow = [[RLBottomBarWindow alloc] initWithWindowScene:scene];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            gBottomBarWindow = [[RLBottomBarWindow alloc] initWithFrame:RLBottomStripFrame(nil)];
#pragma clang diagnostic pop
        }
        gBottomBarWindow.hidden = YES;
        RLConfigureBottomBarWindow(gBottomBarWindow);
        gBottomBarWindow.frame = RLBottomStripFrame(scene);
        RLBottomBarController *root = [RLBottomBarController new];
        gBottomBarWindow.rootViewController = root;
        [root loadViewIfNeeded];
        gBottomBarLabel = root.statusLabel;
    } else if (scene && gBottomBarWindow.windowScene != scene) {
        gBottomBarWindow.windowScene = scene;
    }
    RLPlaceBottomBarWindow();
    gBottomBarAttachAttempts = 0;
    gBottomBarWindow.hidden = NO;
    RLUpdateBottomBarText();
    RLScheduleBottomBarTimer();
    RLApplyRenderingModeToWindow(gBottomBarWindow);
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        NSLog(@"[ReaderLock] bottom line %@ %@", NSStringFromCGRect(gBottomBarWindow.frame), gBottomBarLabel.text);
    }
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

#pragma mark - Reading-screen chrome

// The system status bar is already hidden on the library. An open book still
// keeps its own short top band, and its progress labels sit in the same strip
// as the bottom line. Collapse that band and keep those labels above the line.
// Both come back when Reader Lock turns off.

static char kRLForcedHeightKey;
static char kRLTopSavedKey;
static char kRLFooterShiftKey;
static char kRLSavedBottomInsetKey;
static NSHashTable *gCollapsedTopViews = nil;
static NSHashTable *gFooterShiftedViews = nil;
static NSHashTable *gInsetControllers = nil;
static NSMutableSet<NSString *> *gChromeClassNames = nil;
static NSMutableSet<NSString *> *gPlainClassNames = nil;
static NSMutableSet<NSString *> *gHookedChromeMethods = nil;
static NSInteger gChromeDepth = 0;
static NSMutableSet<NSString *> *gScannedChromeClasses = nil;

static void RLHookChromeSelectors(id object);

static BOOL RLObjectHasKey(id object, const char *key) {
    if (!object || !key) return NO;
    char underscored[96];
    snprintf(underscored, sizeof(underscored), "_%s", key);
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        if (class_getProperty(cls, key)) return YES;
        if (class_getInstanceVariable(cls, underscored)) return YES;
        if (class_getInstanceVariable(cls, key)) return YES;
    }
    return NO;
}

static id RLKVC(id object, const char *key) {
    if (!RLObjectHasKey(object, key)) return nil;
    @try {
        return [object valueForKey:[NSString stringWithUTF8String:key]];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL RLIsReaderChromeController(id object) {
    if (!object) return NO;
    NSString *name = NSStringFromClass(object_getClass(object));
    if (!gChromeClassNames) gChromeClassNames = [NSMutableSet set];
    if (!gPlainClassNames) gPlainClassNames = [NSMutableSet set];
    if ([gChromeClassNames containsObject:name]) return YES;
    if ([gPlainClassNames containsObject:name]) return NO;
    BOOL found = RLObjectHasKey(object, "blackStatusBarArea")
        || RLObjectHasKey(object, "blackStatusBar")
        || RLObjectHasKey(object, "pageLabel")
        || RLObjectHasKey(object, "progressLabel");
    [(found ? gChromeClassNames : gPlainClassNames) addObject:name];
    return found;
}

static BOOL RLBookMarkerInWindow(id controller) {
    const char *keys[] = {"blackStatusBar", "blackStatusBarArea", "pageLabel", "progressLabel"};
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        id view = RLKVC(controller, keys[i]);
        if ([view isKindOfClass:[UIView class]] && ((UIView *)view).window) return YES;
    }
    return NO;
}

static UIViewController *RLFrontmostController(UIViewController *vc) {
    for (NSInteger guard = 0; vc && guard < 12; guard++) {
        UIViewController *presented = vc.presentedViewController;
        if (presented && !presented.isBeingDismissed) {
            vc = presented;
            continue;
        }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *visible = ((UINavigationController *)vc).visibleViewController;
            if (!visible || visible == vc) break;
            vc = visible;
            continue;
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *selected = ((UITabBarController *)vc).selectedViewController;
            if (!selected || selected == vc) break;
            vc = selected;
            continue;
        }
        break;
    }
    return vc;
}

static UIViewController *RLKeyFrontController(void) {
    UIWindow *key = nil;
    UIWindow *fallback = nil;
    for (UIWindow *window in RLApplicationWindows()) {
        if ([window isKindOfClass:[RLBottomBarWindow class]]) continue;
        if (!fallback) fallback = window;
        if (window.isKeyWindow) {
            key = window;
            break;
        }
    }
    if (!key) key = fallback;
    return RLFrontmostController(key.rootViewController);
}

static BOOL RLIsOnFrontChain(UIViewController *target) {
    if (!target) return NO;
    for (UIViewController *vc = RLKeyFrontController(); vc; vc = vc.parentViewController) {
        if (vc == target) return YES;
    }
    return NO;
}

static BOOL RLReadingScreenIsVisible(void) {
    // Apple Books has no MapleRead book-screen marker. Keep its line on every
    // screen rather than guessing a class name and hiding it during a book.
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:RLBooksBundleIdentifier]) return YES;
    for (UIViewController *vc = RLKeyFrontController(); vc; vc = vc.parentViewController) {
        if (RLIsReaderChromeController(vc) && RLBookMarkerInWindow(vc)) return YES;
    }
    return NO;
}

static BOOL gBottomBarRefreshQueued = NO;

static void RLQueueBottomBarRefresh(void) {
    if (!RLBooksActive() || gBottomBarRefreshQueued) return;
    gBottomBarRefreshQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gBottomBarRefreshQueued = NO;
        RLUpdateBottomBarVisibility();
    });
}

static BOOL RLContainsControl(UIView *view, NSInteger depth) {
    if (!view || depth > 6) return NO;
    if ([view isKindOfClass:[UIControl class]]) return YES;
    for (UIView *subview in view.subviews) {
        if (RLContainsControl(subview, depth + 1)) return YES;
    }
    return NO;
}

static BOOL RLIsThinBand(UIView *view) {
    CGFloat height = view.bounds.size.height;
    if (height <= 0.5) return YES;
    if (height > 80) return NO;
    if (!view.window) return YES;
    CGRect inWindow = [view convertRect:view.bounds toView:nil];
    if (inWindow.size.height > 80) return NO;
    BOOL atTop = inWindow.origin.y <= 2;
    BOOL atBottom = CGRectGetMaxY(inWindow) >= CGRectGetHeight(view.window.bounds) - 2;
    return atTop || atBottom;
}

static void RLRestoreHeightConstraints(UIView *view) {
    if (!view) return;
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:view.constraints];
    if (view.superview) [constraints addObjectsFromArray:view.superview.constraints];
    for (NSLayoutConstraint *constraint in constraints) {
        NSNumber *original = objc_getAssociatedObject(constraint, &kRLForcedHeightKey);
        if (!original) continue;
        objc_setAssociatedObject(constraint, &kRLForcedHeightKey, nil, OBJC_ASSOCIATION_ASSIGN);
        constraint.constant = original.doubleValue;
    }
}

static void RLRestoreTopView(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) return;
    RLRestoreHeightConstraints(view);
    NSDictionary *saved = objc_getAssociatedObject(view, &kRLTopSavedKey);
    if (!saved) return;
    view.hidden = [saved[@"h"] boolValue];
    view.alpha = [saved[@"a"] doubleValue];
    view.userInteractionEnabled = [saved[@"i"] boolValue];
    id color = saved[@"c"];
    view.backgroundColor = (color == [NSNull null]) ? nil : color;
    if ([saved[@"z"] boolValue]) {
        NSValue *frameValue = saved[@"f"];
        if (frameValue) {
            CGRect frame = view.frame;
            frame.size.height = frameValue.CGRectValue.size.height;
            view.frame = frame;
        }
    }
    objc_setAssociatedObject(view, &kRLTopSavedKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static BOOL RLForceShortHeightConstraints(UIView *view) {
    BOOL changed = NO;
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:view.constraints];
    if (view.superview) [constraints addObjectsFromArray:view.superview.constraints];
    for (NSLayoutConstraint *constraint in constraints) {
        BOOL sizesView = (constraint.firstItem == view
                && constraint.firstAttribute == NSLayoutAttributeHeight
                && constraint.secondItem == nil)
            || (constraint.secondItem == view
                && constraint.secondAttribute == NSLayoutAttributeHeight
                && constraint.firstItem == nil);
        if (!sizesView || constraint.constant <= 0.5 || constraint.constant > 80) continue;
        if (!objc_getAssociatedObject(constraint, &kRLForcedHeightKey)) {
            objc_setAssociatedObject(constraint, &kRLForcedHeightKey, @(constraint.constant), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        constraint.constant = 0;
        changed = YES;
    }
    return changed;
}

static void RLCollapseTopView(UIView *view) {
    if (![view isKindOfClass:[UIView class]] || RLContainsControl(view, 0)) return;
    if (!RLIsThinBand(view)) {
        if (view.bounds.size.height > 80) RLRestoreTopView(view);
        return;
    }
    BOOL constrained = RLForceShortHeightConstraints(view);
    NSDictionary *saved = objc_getAssociatedObject(view, &kRLTopSavedKey);
    CGRect original = view.frame;
    if (!saved) {
        objc_setAssociatedObject(view, &kRLTopSavedKey, @{
            @"h": @(view.hidden),
            @"a": @(view.alpha),
            @"i": @(view.userInteractionEnabled),
            @"c": view.backgroundColor ?: (id)[NSNull null],
            @"f": [NSValue valueWithCGRect:original],
            @"z": @NO,
        }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gCollapsedTopViews) gCollapsedTopViews = [NSHashTable weakObjectsHashTable];
        [gCollapsedTopViews addObject:view];
        static BOOL logged = NO;
        if (!logged) {
            logged = YES;
            NSLog(@"[ReaderLock] collapsed reader top band %@ %@",
                  NSStringFromClass(object_getClass(view)), NSStringFromCGRect(original));
        }
    }
    view.hidden = YES;
    view.alpha = 0;
    view.userInteractionEnabled = NO;
    view.backgroundColor = [UIColor clearColor];
    if (!constrained && view.bounds.size.height > 0.5 && view.bounds.size.height <= 80) {
        CGRect frame = view.frame;
        frame.size.height = 0;
        if (!CGRectEqualToRect(view.frame, frame)) {
            view.frame = frame;
            NSMutableDictionary *update = [objc_getAssociatedObject(view, &kRLTopSavedKey) mutableCopy];
            update[@"z"] = @YES;
            objc_setAssociatedObject(view, &kRLTopSavedKey, update, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void RLCollapseReaderTopBand(id controller) {
    if (!RLBooksActive() || !controller) return;
    const char *keys[] = {
        "blackStatusBar",
        "blackStatusBarArea",
        "unsafeAreaBrightnessView",
        "unsafeAreaSepiaView",
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        id view = RLKVC(controller, keys[i]);
        if ([view isKindOfClass:[UIView class]]) RLCollapseTopView(view);
    }
}

static void RLRestoreBottomInset(UIViewController *vc) {
    NSNumber *saved = objc_getAssociatedObject(vc, &kRLSavedBottomInsetKey);
    if (!saved) return;
    UIEdgeInsets insets = vc.additionalSafeAreaInsets;
    insets.bottom = saved.doubleValue;
    vc.additionalSafeAreaInsets = insets;
    objc_setAssociatedObject(vc, &kRLSavedBottomInsetKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void RLApplyBottomInset(UIViewController *vc) {
    if ([vc isKindOfClass:[RLBottomBarController class]]) return;
    NSNumber *saved = objc_getAssociatedObject(vc, &kRLSavedBottomInsetKey);
    UIEdgeInsets insets = vc.additionalSafeAreaInsets;
    if (!saved) {
        saved = @(insets.bottom);
        objc_setAssociatedObject(vc, &kRLSavedBottomInsetKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gInsetControllers) gInsetControllers = [NSHashTable weakObjectsHashTable];
        [gInsetControllers addObject:vc];
    }
    CGFloat want = saved.doubleValue + kRLReaderBottomBand;
    if (fabs(insets.bottom - want) <= 0.5) return;
    insets.bottom = want;
    vc.additionalSafeAreaInsets = insets;
}

static void RLShiftFooterView(UIView *view, CGFloat stripTop) {
    if (![view isKindOfClass:[UIView class]] || !view.window || view.hidden || view.alpha < 0.01) return;
    if ([view.window isKindOfClass:[RLBottomBarWindow class]]) return;
    NSNumber *applied = objc_getAssociatedObject(view, &kRLFooterShiftKey);
    CGFloat already = applied ? applied.doubleValue : 0;
    if (already <= 0 && !CGAffineTransformIsIdentity(view.transform)) return;
    CGRect inWindow = [view convertRect:view.bounds toView:nil];
    CGFloat overlap = CGRectGetMaxY(inWindow) - stripTop;
    CGFloat shift = already;
    if (overlap > 0.5 && overlap < 120) shift = already + overlap;
    else if (overlap < -0.5 && already > 0) shift = MAX(0, already + overlap);
    else return;
    if (fabs(shift - already) < 0.5) return;
    view.transform = (shift <= 0.5) ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(0, -shift);
    if (shift <= 0.5) {
        objc_setAssociatedObject(view, &kRLFooterShiftKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    objc_setAssociatedObject(view, &kRLFooterShiftKey, @(shift), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gFooterShiftedViews) gFooterShiftedViews = [NSHashTable weakObjectsHashTable];
    [gFooterShiftedViews addObject:view];
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        NSLog(@"[ReaderLock] lifted reader footer %.0f", shift);
    }
}

static BOOL RLIsPageSurface(UIView *view) {
    NSString *name = NSStringFromClass(object_getClass(view));
    return [name containsString:@"WebView"] || [name containsString:@"PDFPage"] || [name isEqualToString:@"PDFView"];
}

static void RLLiftFooterTree(UIView *view, CGFloat stripTop, NSInteger depth) {
    if (!view || depth > 8 || RLIsPageSurface(view)) return;
    BOOL chrome = [view isKindOfClass:[UIToolbar class]]
        || [view isKindOfClass:[UISlider class]]
        || [view isKindOfClass:[UIProgressView class]]
        || [view isKindOfClass:[UISegmentedControl class]];
    if (chrome && view.bounds.size.height > 0.5 && view.bounds.size.height <= 80) {
        CGRect inWindow = [view convertRect:view.bounds toView:nil];
        if (CGRectGetMaxY(inWindow) > stripTop && CGRectGetMinY(inWindow) > stripTop - 100) {
            RLShiftFooterView(view, stripTop);
            return;
        }
    }
    for (UIView *subview in view.subviews) RLLiftFooterTree(subview, stripTop, depth + 1);
}

static void RLLiftNamedFooter(UIViewController *vc, CGFloat stripTop) {
    UIView *root = vc.isViewLoaded ? vc.view : nil;
    const char *keys[] = {"pageLabel", "progressLabel", "chapterLabel"};
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        id view = RLKVC(vc, keys[i]);
        if (![view isKindOfClass:[UIView class]]) continue;
        UIView *target = view;
        UIView *parent = target.superview;
        if (parent && parent != root && parent.bounds.size.height > 0.5 && parent.bounds.size.height <= 64) {
            target = parent;
        }
        if (target.bounds.size.height > 80) continue;
        RLShiftFooterView(target, stripTop);
    }
}

static void RLRestoreFooterTree(UIView *view, NSInteger depth) {
    if (!view || depth > 8) return;
    if (objc_getAssociatedObject(view, &kRLFooterShiftKey)) {
        view.transform = CGAffineTransformIdentity;
        objc_setAssociatedObject(view, &kRLFooterShiftKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    for (UIView *subview in view.subviews) RLRestoreFooterTree(subview, depth + 1);
}

static void RLApplyReaderChrome(id controller) {
    if (gChromeDepth > 4 || !RLBooksActive() || !RLIsReaderChromeController(controller)) return;
    RLHookChromeSelectors(controller);
    gChromeDepth++;
    RLCollapseReaderTopBand(controller);
    if ([controller isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = controller;
        RLApplyBottomInset(vc);
        if (vc.isViewLoaded && vc.view.window) {
            CGFloat stripTop = CGRectGetHeight(vc.view.window.bounds) - kRLReaderBottomBand;
            RLLiftNamedFooter(vc, stripTop);
            RLLiftFooterTree(vc.view, stripTop, 0);
        }
        if ((!gBottomBarWindow || gBottomBarWindow.hidden)
            && RLIsOnFrontChain(vc)
            && RLBookMarkerInWindow(vc)) {
            RLQueueBottomBarRefresh();
        }
    }
    gChromeDepth--;
}

static void RLRestoreReaderChrome(id controller) {
    if (!RLIsReaderChromeController(controller)) return;
    const char *keys[] = {
        "blackStatusBar",
        "blackStatusBarArea",
        "unsafeAreaBrightnessView",
        "unsafeAreaSepiaView",
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        id view = RLKVC(controller, keys[i]);
        if ([view isKindOfClass:[UIView class]]) RLRestoreTopView(view);
    }
    if (![controller isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = controller;
    RLRestoreBottomInset(vc);
    if (vc.isViewLoaded) RLRestoreFooterTree(vc.view, 0);
}

static void RLWalkControllers(UIViewController *vc, NSMutableSet *seen, NSInteger depth, BOOL apply) {
    if (!vc || depth > 12 || [seen containsObject:vc]) return;
    [seen addObject:vc];
    if (apply) RLApplyReaderChrome(vc);
    else RLRestoreReaderChrome(vc);
    for (UIViewController *child in vc.childViewControllers) RLWalkControllers(child, seen, depth + 1, apply);
    RLWalkControllers(vc.presentedViewController, seen, depth + 1, apply);
}

static void RLApplyReaderChromeNow(void) {
    if (![NSThread isMainThread]) return;
    BOOL apply = RLBooksActive();
    for (UIWindow *window in RLApplicationWindows()) {
        if ([window isKindOfClass:[RLBottomBarWindow class]]) continue;
        RLWalkControllers(window.rootViewController, [NSMutableSet set], 0, apply);
    }
}

static void RLRestoreAllReaderChrome(void) {
    for (UIView *view in [gCollapsedTopViews allObjects]) RLRestoreTopView(view);
    [gCollapsedTopViews removeAllObjects];
    for (UIView *view in [gFooterShiftedViews allObjects]) {
        view.transform = CGAffineTransformIdentity;
        objc_setAssociatedObject(view, &kRLFooterShiftKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    [gFooterShiftedViews removeAllObjects];
    for (UIViewController *vc in [gInsetControllers allObjects]) RLRestoreBottomInset(vc);
    [gInsetControllers removeAllObjects];
    RLApplyReaderChromeNow();
}

static void RLHookChromeMethod(Class cls, SEL sel) {
    if (!cls || !sel) return;
    NSString *token = [NSString stringWithFormat:@"%@ %s", NSStringFromClass(cls), sel_getName(sel)];
    if (!gHookedChromeMethods) gHookedChromeMethods = [NSMutableSet set];
    if ([gHookedChromeMethods containsObject:token]) return;

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

    char ret[8] = {0};
    method_getReturnType(found, ret, sizeof(ret));
    if (ret[0] != 'v') {
        [gHookedChromeMethods addObject:token];
        return;
    }
    unsigned int args = method_getNumberOfArguments(found);
    if (args == 2) {
        void (*original)(id, SEL) = (void (*)(id, SEL))method_getImplementation(found);
        IMP replacement = imp_implementationWithBlock(^void(id self) {
            original(self, sel);
            if (RLBooksActive()) RLCollapseReaderTopBand(self);
        });
        method_setImplementation(found, replacement);
        [gHookedChromeMethods addObject:token];
        return;
    }
    if (args == 3) {
        void (*original)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(found);
        IMP replacement = imp_implementationWithBlock(^void(id self, id value) {
            original(self, sel, value);
            if (RLBooksActive()) RLCollapseReaderTopBand(self);
        });
        method_setImplementation(found, replacement);
        [gHookedChromeMethods addObject:token];
    }
}

static void RLHookChromeSelectorsOnClass(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    if (!gScannedChromeClasses) gScannedChromeClasses = [NSMutableSet set];
    if ([gScannedChromeClasses containsObject:name]) return;
    [gScannedChromeClasses addObject:name];

    const char *names[] = {
        "addBlackStatusBarAreaToViewIfNeeded:",
        "updateStatusBarAreaColor",
        "setBlackStatusBar:",
        "setBlackStatusBarArea:",
        "setUnsafeAreaBrightnessView:",
        "setUnsafeAreaSepiaView:",
    };
    for (size_t s = 0; s < sizeof(names) / sizeof(names[0]); s++) {
        RLHookChromeMethod(cls, sel_registerName(names[s]));
    }
}

static void RLHookChromeSelectors(id object) {
    Class stop = [UIViewController class];
    for (Class cls = object_getClass(object); cls && cls != stop; cls = class_getSuperclass(cls)) {
        RLHookChromeSelectorsOnClass(cls);
    }
}

static void RLInstallReaderChromeHooks(void) {
    int capacity = objc_getClassList(NULL, 0);
    if (capacity <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)capacity);
    if (!classes) return;
    int reported = objc_getClassList(classes, capacity);
    int limit = reported < capacity ? reported : capacity;
    for (int i = 0; i < limit; i++) RLHookChromeSelectorsOnClass(classes[i]);
    free(classes);
}

static CGRect (*gRLOrigStatusBarFrame)(id, SEL) = NULL;
static BOOL (*gRLOrigStatusBarHidden)(id, SEL) = NULL;
static void (*gRLOrigSetStatusBarHidden)(id, SEL, BOOL) = NULL;
static void (*gRLOrigSetStatusBarHiddenAnimated)(id, SEL, BOOL, NSInteger) = NULL;

static CGRect RLReplacementStatusBarFrame(id self, SEL cmd) {
    if (RLBooksActive()) return CGRectZero;
    return gRLOrigStatusBarFrame ? gRLOrigStatusBarFrame(self, cmd) : CGRectZero;
}

static BOOL RLReplacementStatusBarHidden(id self, SEL cmd) {
    if (RLBooksActive()) return YES;
    return gRLOrigStatusBarHidden ? gRLOrigStatusBarHidden(self, cmd) : YES;
}

static void RLReplacementSetStatusBarHidden(id self, SEL cmd, BOOL hidden) {
    if (RLBooksActive()) hidden = YES;
    if (gRLOrigSetStatusBarHidden) gRLOrigSetStatusBarHidden(self, cmd, hidden);
}

static void RLReplacementSetStatusBarHiddenAnimated(id self, SEL cmd, BOOL hidden, NSInteger animation) {
    if (RLBooksActive()) hidden = YES;
    if (gRLOrigSetStatusBarHiddenAnimated) gRLOrigSetStatusBarHiddenAnimated(self, cmd, hidden, animation);
}

static void RLHookApplicationStatusBar(void) {
    static BOOL hooked = NO;
    if (hooked) return;
    hooked = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    Method frame = class_getInstanceMethod([UIApplication class], @selector(statusBarFrame));
    Method hidden = class_getInstanceMethod([UIApplication class], @selector(isStatusBarHidden));
    Method setHidden = class_getInstanceMethod([UIApplication class], @selector(setStatusBarHidden:));
    Method setHiddenAnimated = class_getInstanceMethod([UIApplication class], @selector(setStatusBarHidden:withAnimation:));
#pragma clang diagnostic pop
    if (frame && RLIsNoArgGetter(frame, '{', 0, 0, 0)) {
        gRLOrigStatusBarFrame = (CGRect (*)(id, SEL))method_getImplementation(frame);
        method_setImplementation(frame, (IMP)RLReplacementStatusBarFrame);
    }
    if (hidden && RLIsNoArgGetter(hidden, 'B', 'c', 0, 0)) {
        gRLOrigStatusBarHidden = (BOOL (*)(id, SEL))method_getImplementation(hidden);
        method_setImplementation(hidden, (IMP)RLReplacementStatusBarHidden);
    }
    if (setHidden && RLIsVoidMethod(setHidden, 3)) {
        gRLOrigSetStatusBarHidden = (void (*)(id, SEL, BOOL))method_getImplementation(setHidden);
        method_setImplementation(setHidden, (IMP)RLReplacementSetStatusBarHidden);
    }
    if (setHiddenAnimated && RLIsVoidMethod(setHiddenAnimated, 4)) {
        gRLOrigSetStatusBarHiddenAnimated = (void (*)(id, SEL, BOOL, NSInteger))method_getImplementation(setHiddenAnimated);
        method_setImplementation(setHiddenAnimated, (IMP)RLReplacementSetStatusBarHiddenAnimated);
    }
}

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

- (void)viewDidLayoutSubviews {
    %orig;
    if (RLBooksActive()) RLApplyReaderChrome(self);
    else RLRestoreReaderChrome(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if ([self isKindOfClass:[RLBottomBarController class]]) return;
    if (RLBooksActive()) {
        RLHookStatusMethods(object_getClass(self));
        [self setNeedsStatusBarAppearanceUpdate];
        RLApplySystemStatusBarHidden(YES);
    }
    RLQueueBottomBarRefresh();
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if ([self isKindOfClass:[RLBottomBarController class]]) return;
    RLQueueBottomBarRefresh();
}

%end

%hook NSLayoutConstraint

- (void)setConstant:(CGFloat)constant {
    if (RLBooksActive() && constant != 0 && objc_getAssociatedObject(self, &kRLForcedHeightKey)) constant = 0;
    %orig(constant);
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

@interface UIStatusBar : UIView
@end

@interface _UIStatusBar : UIView
@end

%hook UIStatusBar

- (void)layoutSubviews {
    %orig;
    RLSuppressStatusBarView(self);
}

- (void)didMoveToWindow {
    %orig;
    RLSuppressStatusBarView(self);
}

%end

%hook _UIStatusBar

- (void)layoutSubviews {
    %orig;
    RLSuppressStatusBarView(self);
}

- (void)didMoveToWindow {
    %orig;
    RLSuppressStatusBarView(self);
}

%end

%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (!RLBooksActive()) return;
    Class cls = object_getClass(self);
    if (!RLClassIsStatusBarClass(cls)) return;
    RLHookStatusBarViewClass(cls);
    RLSuppressStatusBarView(self);
}

- (void)setHidden:(BOOL)hidden {
    if (RLBooksActive() && RLClassIsStatusBarClass(object_getClass(self))) hidden = YES;
    %orig(hidden);
}

- (void)setAlpha:(CGFloat)alpha {
    if (RLBooksActive() && RLClassIsStatusBarClass(object_getClass(self))) alpha = 0;
    %orig(alpha);
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
        RLHookApplicationStatusBar();
        RLInstallReaderChromeHooks();
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
