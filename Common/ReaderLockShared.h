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
static NSString * const RLRecoveryPath = @"/var/mobile/Library/Preferences/com.quan.readerlock.recovery.plist";

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
