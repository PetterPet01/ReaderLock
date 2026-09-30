#pragma once

#import <Foundation/Foundation.h>
#import <notify.h>

typedef NS_ENUM(uint64_t, RLReaderState) {
    RLReaderStateOff     = 0,
    RLReaderStateMono    = 1,
    RLReaderStateColor   = 2,
    RLReaderStateArming  = 3,
    RLReaderStateExiting = 4,
};

static const char * const RLStateNotification       = "com.quan.readerlock.state";
static const char * const RLCommandMonoNotification = "com.quan.readerlock.command.mono";
static const char * const RLCommandColorNotification= "com.quan.readerlock.command.color";
static const char * const RLCommandExitNotification = "com.quan.readerlock.command.exit";
static const char * const RLAuthBeginNotification   = "com.quan.readerlock.auth.begin";
static const char * const RLAuthEndNotification     = "com.quan.readerlock.auth.end";

static NSString * const RLBooksBundleIdentifier = @"com.apple.iBooks";
static NSString * const RLMapleReadBundleIdentifier = @"com.maplepop.bmsea";
static NSString * const RLRecoveryPath = @"/var/mobile/Library/Preferences/com.quan.readerlock.recovery.plist";
static NSString * const RLPreferencePath = @"/var/mobile/Library/Preferences/com.quan.readerlock.plist";

typedef NS_ENUM(NSInteger, RLReaderApp) {
    RLReaderAppBooks = 0,
    RLReaderAppMaple = 1,
};

// Missing preference means MapleRead. The Control Center switch writes "books" or "maple".
static inline RLReaderApp RLPreferredReader(void) {
    id value = [NSDictionary dictionaryWithContentsOfFile:RLPreferencePath][@"reader"];
    if ([value isKindOfClass:[NSString class]] && [value isEqualToString:@"books"]) return RLReaderAppBooks;
    return RLReaderAppMaple;
}

static inline NSString *RLBundleIdentifierForReader(RLReaderApp app) {
    return app == RLReaderAppBooks ? RLBooksBundleIdentifier : RLMapleReadBundleIdentifier;
}

static inline NSString *RLSelectedReaderBundleIdentifier(void) {
    return RLBundleIdentifierForReader(RLPreferredReader());
}

static inline BOOL RLWritePreferredReader(RLReaderApp app) {
    NSMutableDictionary *prefs = [[NSDictionary dictionaryWithContentsOfFile:RLPreferencePath] mutableCopy];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[@"reader"] = (app == RLReaderAppBooks) ? @"books" : @"maple";
    return [prefs writeToFile:RLPreferencePath atomically:YES];
}

static inline BOOL RLStateIsActive(RLReaderState state) {
    return state == RLReaderStateMono || state == RLReaderStateColor;
}

static inline RLReaderState RLReadDarwinState(void) {
    int token = 0;
    uint64_t state = RLReaderStateOff;
    if (notify_register_check(RLStateNotification, &token) == NOTIFY_STATUS_OK) {
        notify_get_state(token, &state);
        notify_cancel(token);
    }
    return (RLReaderState)state;
}

static inline void RLPostCommand(const char *name) {
    notify_post(name);
}
