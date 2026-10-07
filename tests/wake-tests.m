// Exercise the actual observer wiring and delayed callbacks with an isolated
// notification center. The fake enrollment cannot connect to a real iPad.
#define main ASCommandMain
#import "../src/auto-sidecar.m"
#undef main
#define CHECK(condition) do { if(!(condition)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#condition);exit(1);} } while(0)
static void RunFor(NSTimeInterval seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(end.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
int main(void) { @autoreleasepool {
    configuration=@{@"usbSerial":@"AutoSidecar-TEST-NOT-A-REAL-USB-SERIAL"};
    NSNotificationCenter *center=[NSNotificationCenter new];
    NSArray *observers=ObservePowerEvents(center);
    recovery=(ASRecoveryState){.generation=1,.attached=YES,.recovering=YES,.attempts=5,.retryLayout=YES};
    [center postNotificationName:NSWorkspaceWillSleepNotification object:nil];
    CHECK(recovery.suspended&&!recovery.recovering&&recovery.generation>1);
    [center postNotificationName:NSWorkspaceDidWakeNotification object:nil];
    NSUInteger systemWake=recovery.generation;
    [center postNotificationName:NSWorkspaceScreensDidWakeNotification object:nil];
    CHECK(recovery.generation>systemWake&&recovery.suspended);
    // A new sleep must cancel both queued wakes, even after their timers fire.
    [center postNotificationName:NSWorkspaceWillSleepNotification object:nil];
    NSUInteger sleeping=recovery.generation;
    RunFor(5.3);
    CHECK(recovery.generation==sleeping&&recovery.suspended);
    // Display-only wake reaches recovery without NSWorkspaceDidWakeNotification.
    [center postNotificationName:NSWorkspaceScreensDidWakeNotification object:nil];
    NSUInteger firstScreenWake=recovery.generation;
    [center postNotificationName:NSWorkspaceScreensDidWakeNotification object:nil];
    NSUInteger screenWake=recovery.generation;
    CHECK(screenWake>firstScreenWake);
    RunFor(5.3);
    // Both notifications must produce exactly one completed settling callback.
    CHECK(recovery.generation==screenWake+1&&!recovery.suspended);
    CHECK(!recovery.attached&&!recovery.recovering); // USB absent -> no worker
    CHECK(recovery.attempts==0&&!recovery.retryLayout&&!worker);
    for(id observer in observers)[center removeObserver:observer];
    NSUInteger finished=recovery.generation;
    [center postNotificationName:NSWorkspaceScreensDidWakeNotification object:nil];
    CHECK(recovery.generation==finished);
    puts("PASS: system/screen wake observers, overlapping notifications, sleep cancels delayed wake, display-only recovery, absent USB");
} }
