#import <Foundation/Foundation.h>

typedef NS_ENUM(int, ASResult) {
    ASOK = 0, ASUsage = 1, ASUnavailable = 2, ASTargetMissing = 3,
    ASConnectionFailed = 4, ASTimedOut = 5, ASLayoutFailed = 8, ASUSBAbsent = 9
};
static const NSUInteger ASMaxAttempts = 5;
static const unsigned ASWorkerTimeout = 50;
static inline NSTimeInterval ASRetryDelay(NSUInteger completedAttempts) { return completedAttempts * 5; }
static inline BOOL ASShouldReleaseHelper(BOOL recovering, BOOL workerRunning, BOOL sidecarOnline, NSUInteger otherDisplays) {
    if (recovering || workerRunning) return NO;
    return otherDisplays > 0 || !sidecarOnline;
}
static inline BOOL ASAttemptIsCurrent(NSUInteger scheduled, NSUInteger current, BOOL attached, BOOL recovering) {
    return scheduled == current && attached && recovering;
}

typedef struct {
    NSUInteger generation;
    NSUInteger attempts;
    BOOL attached;
    BOOL retryLayout;
    BOOL recovering;
    BOOL suspended;
} ASRecoveryState;
static inline void ASResetRecovery(ASRecoveryState *state, BOOL attached, BOOL suspended) {
    state->generation++;
    state->attempts=0;
    state->attached=attached;
    state->retryLayout=NO;
    state->recovering=attached&&!suspended;
    state->suspended=suspended;
}
