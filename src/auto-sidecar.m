#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <IOKit/IOKitLib.h>
#import <signal.h>
#import "PrivateAPIs.h"
#import "Config.h"
#import "Policy.h"
#import "Dock.h"
#import "../bin/InstallScripts.h"
static NSDictionary *configuration;
static NSString *configurationPath;
static void CheckDockSession(void);
static void ReloadPreferences(void);
static void InitializePreferences(void);
static NSString *RuntimeConfigPath(void) {
    return [configurationPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"runtime-config.plist"];
}
static NSString *DockRecordPath(void) {
    return [configurationPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"dock-restoration.plist"];
}
static BOOL usbMatch(io_service_t s) {
    CFTypeRef sn=IORegistryEntryCreateCFProperty(s,CFSTR("USB Serial Number"),kCFAllocatorDefault,0);
    CFTypeRef v=IORegistryEntryCreateCFProperty(s,CFSTR("idVendor"),kCFAllocatorDefault,0);
    BOOL yes=sn&&v&&[(__bridge id)sn isEqual:configuration[@"usbSerial"]]&&[(__bridge id)v intValue]==1452;
    if (sn)CFRelease(sn);
    if (v)CFRelease(v);
    return yes;
}

static BOOL usbPresent(void) {
    io_iterator_t it=0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&it))return NO;
    BOOL yes=NO;
    io_service_t s;
    while ((s=IOIteratorNext(it))) {
        if (usbMatch(s))yes=YES;
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return yes;
}

static NSString *executable;
static NSTask *worker;
static ASRecoveryState recovery;
static NSUInteger displayChangeGeneration;
static BOOL displayChangePending;
static BOOL dockRefreshPending;
// The headless fallback ("unkn"/"virt") is not an actual monitor.
static BOOL isHelper(CGDirectDisplayID d) {
    return CGDisplayVendorNumber(d)==0xF0F0&&CGDisplayModelNumber(d)==0xA501;
}

static BOOL isFallback(CGDirectDisplayID d) {
    return CGDisplayVendorNumber(d)==0x756e6b6e && CGDisplayModelNumber(d)==0x76697274;
}

static BOOL isSidecar(CGDirectDisplayID d) {
    return CGDisplayVendorNumber(d)==0x6161706c && CGDisplayModelNumber(d)==0x69506164;
}

static NSArray<NSNumber *> *otherDisplayIDs(void) {
    CGDirectDisplayID displays[64];
    uint32_t count=0;
    if (CGGetOnlineDisplayList(64,displays,&count)!=kCGErrorSuccess)return nil;
    NSMutableArray *result=[NSMutableArray array];
    for (uint32_t i=0;i<count;i++) if (!isHelper(displays[i])&&!isFallback(displays[i])&&!isSidecar(displays[i]))[result addObject:@(displays[i])];
    return [result sortedArrayUsingSelector:@selector(compare:)];
}

static unsigned otherDisplayCount(void) {
    NSArray *ids=otherDisplayIDs();
    return ids?(unsigned)ids.count:UINT_MAX;
}

static VD *virtualDisplay;
static NSDictionary *activeHelperSettings;
static NSArray<NSNumber *> *previousOtherDisplays;
static void cleanupHelper(void);
static BOOL prepareDesktop(void) {
    unsigned count=otherDisplayCount();
    if (count==UINT_MAX) {
        NSLog(@"Cannot enumerate displays");
        return NO;
    }
    if (count>0) {
        if (virtualDisplay) {
            NSLog(@"Real display available; releasing headless helper");
            virtualDisplay=nil;
        }
        return YES;
    }
    if (virtualDisplay&&![activeHelperSettings isEqual:configuration[@"display"]]) {
        CGDirectDisplayID displays[64];uint32_t n=0;BOOL active=NO;
        if(CGGetOnlineDisplayList(64,displays,&n)==kCGErrorSuccess){
            for(uint32_t i=0;i<n;i++)if(isSidecar(displays[i]))active=YES;
            if(!active)virtualDisplay=nil;
        }
    }
    if (virtualDisplay)return YES;
    VDDescriptor *d=[NSClassFromString(@"CGVirtualDisplayDescriptor") new];
    if (!d) {
        NSLog(@"Virtual display API unavailable");
        return NO;
    }
    NSDictionary *display=configuration[@"display"];
    d.name=@"AutoSidecar Headless";
    d.maxPixelsWide=[display[@"width"] unsignedIntValue];
    d.maxPixelsHigh=[display[@"height"] unsignedIntValue];
    d.vendorID=0xF0F0;
    d.productID=0xA501;
    d.serialNum=1;
    d.sizeInMillimeters=CGSizeMake(d.maxPixelsWide/220.0*25.4,d.maxPixelsHigh/220.0*25.4);
    d.queue=dispatch_get_main_queue();
    virtualDisplay=[[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:d];
    VDSettings *settings=[NSClassFromString(@"CGVirtualDisplaySettings") new];
    settings.hiDPI=[display[@"hiDPI"] boolValue];
    // Config dimensions are backing pixels; HiDPI mode dimensions are logical.
    id mode=[[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:ASDisplayModeDimension(d.maxPixelsWide,settings.hiDPI)
        height:ASDisplayModeDimension(d.maxPixelsHigh,settings.hiDPI)
        refreshRate:[display[@"refreshRate"] doubleValue]];
    if (!virtualDisplay||!mode) {
        NSLog(@"Failed to create headless display");
        virtualDisplay=nil;
        return NO;
    }
    settings.modes=@[mode];
    if (![virtualDisplay applySettings:settings]) {
        NSLog(@"Failed to configure headless display");
        virtualDisplay=nil;
        return NO;
    }
    activeHelperSettings=[configuration[@"display"] copy];
    NSLog(@"Created headless desktop display %u",virtualDisplay.displayID);
    return YES;
}
// Display removal notifications also arrive when Sidecar ends over Wi-Fi.
// Do not leave a ghost desktop after failed recovery or an ended session.
static void cleanupHelper(void) {
    if(recovery.suspended)return;
    CheckDockSession();
    if (!virtualDisplay)return;
    CGDirectDisplayID displays[64];
    uint32_t count=0;
    if (CGGetOnlineDisplayList(64,displays,&count)!=kCGErrorSuccess)return;
    BOOL sidecarOnline=NO;
    for (uint32_t i=0;i<count;i++)if (isSidecar(displays[i]))sidecarOnline=YES;
    unsigned others=otherDisplayCount();
    if (others!=UINT_MAX&&ASShouldReleaseHelper(recovery.recovering,worker.running,sidecarOnline,others)) {
        NSLog(@"Releasing unused headless desktop");
        virtualDisplay=nil;
    }
}

static void endRecovery(BOOL success) {
    recovery.recovering=NO;
    dockRefreshPending=success;
    CheckDockSession();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^ {
        cleanupHelper();
    });
}

static void scheduleAttempt(NSUInteger epoch, double delay);
static void attempt(NSUInteger epoch) {
    if (!ASAttemptIsCurrent(epoch,recovery.generation,recovery.attached,recovery.recovering)||!usbPresent())return;
    if (worker.running) {
        scheduleAttempt(epoch,2);
        return;
    }
    if (recovery.attempts>=ASMaxAttempts) {
        NSLog(@"Retry limit reached");
        endRecovery(NO);
        return;
    }
    recovery.attempts++;
    if (!prepareDesktop()) {
        scheduleAttempt(epoch,10);
        return;
    }
    NSLog(@"USB connection attempt %lu",(unsigned long)recovery.attempts);
    worker=[NSTask new];
    worker.executableURL=[NSURL fileURLWithPath:executable];
    worker.arguments=@[recovery.retryLayout?@"finish":@"ensure",@"--config",RuntimeConfigPath()];
    worker.terminationHandler=^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(),^ {
            if (epoch!=recovery.generation) {
                cleanupHelper();return;
            }
            if (task.terminationStatus==ASOK) {
                endRecovery(YES);NSLog(@"Recovery handled; waiting for the next USB attachment or Mac wake");return;
            }
            recovery.retryLayout=(task.terminationStatus==ASLayoutFailed);
            if (recovery.attempts>=ASMaxAttempts) {
                NSLog(@"Retry limit reached; unlock iPad and replug USB to try again");endRecovery(NO);return;
            }
            scheduleAttempt(epoch,ASRetryDelay(recovery.attempts));
        });
    };
    NSError *error=nil;
    if (![worker launchAndReturnError:&error]) {
        NSLog(@"Cannot launch worker: %@",error);
        scheduleAttempt(epoch,10);
    }
}

static void scheduleAttempt(NSUInteger epoch,double delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^ {
        attempt(epoch);
    });
}

static void suspendRecovery(void) {
    ASResetRecovery(&recovery,recovery.attached,YES);
    displayChangeGeneration++;
    displayChangePending=NO;
    dockRefreshPending=NO;
    if(worker.running)[worker terminate];
}

static void macWillSleep(void) {
    suspendRecovery();
    NSLog(@"Mac sleeping; cancelling pending recovery");
}

static void macDidWake(void) {
    // USB and display callbacks may arrive before enumeration settles. Pause
    // them during this delay, then re-read USB even if no attach event arrives.
    suspendRecovery();
    NSUInteger epoch=recovery.generation;
    NSLog(@"Mac woke; waiting 5 seconds for USB and Sidecar services");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(epoch!=recovery.generation)return;
        ASResetRecovery(&recovery,usbPresent(),NO);
        previousOtherDisplays=otherDisplayIDs();
        if(recovery.attached){
            NSLog(@"Enrolled USB iPad present after wake; restarting recovery");
            scheduleAttempt(recovery.generation,0);
        }else{
            NSLog(@"Enrolled USB iPad absent after wake; waiting for attachment");
            cleanupHelper();
        }
    });
}

static void usbChanged(__unused void *ctx,io_iterator_t it) {
    io_service_t s;
    BOOL relevant=NO;
    while ((s=IOIteratorNext(it))) {
        if (usbMatch(s))relevant=YES;
        IOObjectRelease(s);
    }
    if (!relevant)return;
    BOOL now=usbPresent();
    if(recovery.suspended){recovery.attached=now;return;}
    if (now==recovery.attached)return;
    ASResetRecovery(&recovery,now,NO);
    dockRefreshPending=NO;
    NSLog(@"USB %@",recovery.attached?@"attached; waiting 3 seconds for enumeration":@"detached; resetting attachment state");
    if (!recovery.attached) {
        if (worker.running)[worker terminate];
        endRecovery(NO);
    }
    // Keep an active headless desktop until the watcher stops or a real display arrives.
    // This permits an existing Sidecar session to continue over Wi-Fi after unplugging.
    if (recovery.attached)scheduleAttempt(recovery.generation,3);
}

static void displayChanged(__unused CGDirectDisplayID display,CGDisplayChangeSummaryFlags flags,__unused void *ctx) {
    if (flags&kCGDisplayBeginConfigurationFlag)return;
    dispatch_async(dispatch_get_main_queue(),^ {
        if(recovery.suspended)return;
        NSUInteger ticket=++displayChangeGeneration;
        displayChangePending=YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^ {
            if (ticket!=displayChangeGeneration||recovery.suspended)return;
            displayChangePending=NO;
            NSArray *ids=otherDisplayIDs();if (!ids||[ids isEqual:previousOtherDisplays]){cleanupHelper();return;}
            previousOtherDisplays=ids;
            unsigned count=(unsigned)ids.count;
            if (!recovery.attached||!usbPresent()){cleanupHelper();return;}
            recovery.generation++;recovery.attempts=0;recovery.retryLayout=YES;recovery.recovering=YES;
            dockRefreshPending=NO;
            cleanupHelper();
            NSLog(@"Other display count changed to %u; adapting layout",count);
            scheduleAttempt(recovery.generation,1);
        });
    });
}

static int watchUSB(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    InitializePreferences();
    NSNotificationCenter *workspaceCenter=NSWorkspace.sharedWorkspace.notificationCenter;
    id sleepObserver=[workspaceCenter addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){macWillSleep();}];
    id wakeObserver=[workspaceCenter addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){macDidWake();}];
    previousOtherDisplays=otherDisplayIDs();
    CGError registration=CGDisplayRegisterReconfigurationCallback(displayChanged,NULL);
    NSLog(@"Display callback registration result=%d",registration);
    if (registration!=kCGErrorSuccess)return 13;
    IONotificationPortRef port=IONotificationPortCreate(kIOMainPortDefault);
    if (!port)return 10;
    IONotificationPortSetDispatchQueue(port,dispatch_get_main_queue());
    io_iterator_t a=0,b=0;
    if (IOServiceAddMatchingNotification(port,kIOFirstMatchNotification,IOServiceMatching("IOUSBHostDevice"),usbChanged,NULL,&a))return 11;
    usbChanged(NULL,a);
    if (IOServiceAddMatchingNotification(port,kIOTerminatedNotification,IOServiceMatching("IOUSBHostDevice"),usbChanged,NULL,&b))return 12;
    usbChanged(NULL,b);
    NSLog(@"Watching exact iPad USB identity; initial=%@",recovery.attached?@"attached":@"absent");
    [NSApp run];
    [workspaceCenter removeObserver:sleepObserver];
    [workspaceCenter removeObserver:wakeObserver];
    return ASOK;
}

static id DiscoveryManager(void);

static int RunCommand(NSString *action) {
    if ([action isEqual:@"watch"])return watchUSB();
    if ([action isEqual:@"usb"]) {
        printf("%s\n",usbPresent()?"attached":"absent");
        return usbPresent()?0:1;
    }
    if (![@[@"status",@"connect",@"disconnect",@"ensure",@"apply",@"finish",@"reconcile"] containsObject:action]) {
        fprintf(stderr,"Usage: auto-sidecar status|usb|connect|disconnect|ensure|apply|watch\n");
        return ASUsage;
    }
    // Hard process deadline also bounds a stalled private framework call.
    alarm(ASWorkerTimeout);
    if (([action isEqual:@"ensure"]||[action isEqual:@"finish"])&&!usbPresent())return ASUSBAbsent;
    id m=DiscoveryManager();
    if (!m)return ASUnavailable;
    NSString *cmd=[action isEqual:@"reconcile"]?@"apply":action;
    NSArray *devices=[m devices];
    id target=nil;
    for (id d in devices) {
        printf("DEVICE name=%s model=%s identifier=%s connected=%d configDisplay=%s\n",[[d name] UTF8String],[[d model] UTF8String],[[[d identifier] description] UTF8String],[[m connectedDevices] containsObject:d],[[[[m configForDevice:d] valueForKey:@"displayID"] description] UTF8String]);
        if ([[[d identifier] description] isEqual:configuration[@"sidecarIdentifier"]])target=d;
    }
    if([action isEqual:@"reconcile"]&&(!target||![[m connectedDevices] containsObject:target]))return ASOK;
    BOOL finishing=[cmd isEqual:@"finish"];
    if (finishing)cmd=@"apply";
    BOOL ensure=[cmd isEqual:@"ensure"];
    if (ensure&&target&&[[m connectedDevices] containsObject:target]&&CGDisplayIsOnline([[[m configForDevice:target] valueForKey:@"displayID"] unsignedIntValue])) {
        NSLog(@"Already connected to intended iPad; leaving session unchanged");
        return ASOK;
    }
    if (ensure||[cmd isEqual:@"connect"]||[cmd isEqual:@"disconnect"]) {
        if (!target) {
            NSLog(@"Configured iPad is not available; wake it, or run setup to choose another device");
            return ASTargetMissing;
        }
        __block BOOL done=NO;
        __block int result=0;
        void(^cb)(NSError*)=^(NSError*e) {
            dispatch_async(dispatch_get_main_queue(),^ {
                NSLog(@"completion=%@",e);result=e?ASConnectionFailed:ASOK;done=YES;
            });
        };
        if (ensure||[cmd isEqual:@"connect"])[m connectToDevice:target completion:cb];
        else [m disconnectFromDevice:target completion:cb];
        NSDate *end=[NSDate dateWithTimeIntervalSinceNow:30];
        while (!done&&[end timeIntervalSinceNow]>0)[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
        if (!done||result)return done?result:ASTimedOut;
        if ([cmd isEqual:@"disconnect"])return ASOK;
        NSDate *ready=[NSDate dateWithTimeIntervalSinceNow:12];
        while ([ready timeIntervalSinceNow]>0) {
            if (ensure&&!usbPresent())return ASUSBAbsent;
            NSNumber *sid=[[m configForDevice:target] valueForKey:@"displayID"];
            if ([[m connectedDevices] containsObject:target]&&sid&&CGDisplayIsOnline(sid.unsignedIntValue))break;
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.25]];
        }
        cmd=@"apply";
    }
    CGDirectDisplayID ds[64];
    uint32_t n=0;
    if (CGGetOnlineDisplayList(64,ds,&n)!=kCGErrorSuccess)return ASLayoutFailed;
    for (uint32_t i=0;i<n;i++)printf("DISPLAY id=%u vendor=%u model=%u main=%d mirror=%u\n",ds[i],CGDisplayVendorNumber(ds[i]),CGDisplayModelNumber(ds[i]),CGDisplayIsMain(ds[i]),CGDisplayMirrorsDisplay(ds[i]));
    if ([cmd isEqual:@"apply"]) {
        if (!target||![[m connectedDevices] containsObject:target]) {
            NSLog(@"No active Sidecar session after connection; retry connection");
            return ASConnectionFailed;
        }
        NSNumber *sid=[[m configForDevice:target] valueForKey:@"displayID"];
        if (!sid||!sid.unsignedIntValue)return ASLayoutFailed;
        CGDirectDisplayID side=sid.unsignedIntValue;
        BOOL found=NO;
        unsigned other=0;
        CGDirectDisplayID helper=0;
        for (uint32_t i=0;i<n;i++) {
            if (ds[i]==side) {
                found=YES;
                continue;
            }
            if (isHelper(ds[i])) {
                helper=ds[i];
                continue;
            }
            if (isFallback(ds[i])||isSidecar(ds[i]))continue;
            other++;
        }
        if (!found)return ASLayoutFailed;
        if ((ensure||finishing)&&!usbPresent())return ASUSBAbsent;
        NSString *mode=configuration[@"withOtherDisplays"]?:@"extend";
        if(other&&[mode isEqual:@"preserve"]){NSLog(@"Preserving macOS-restored layout");return ASOK;}
        CGDirectDisplayID master=other&&[mode isEqual:@"mirror"]?CGMainDisplayID():(!other?helper:0);
        if(master==side){NSLog(@"Cannot mirror the iPad to itself; select another main display");return ASLayoutFailed;}
        BOOL alreadyCorrect=CGDisplayMirrorsDisplay(side)==master&&(master||other||CGDisplayIsMain(side));
        if (alreadyCorrect) {
            NSLog(@"Verified existing iPad %@; preserving arrangement",other?([mode isEqual:@"mirror"]?@"mirrored desktop":@"extended desktop"):@"headless desktop");
            return ASOK;
        }
        CGDisplayConfigRef cfg=NULL;
        CGError e=CGBeginDisplayConfiguration(&cfg);
        if (!e)e=CGConfigureDisplayMirrorOfDisplay(cfg,side,master);
        // Preserve macOS's remembered arrangement when other displays exist.
        if (!e&&!other&&!helper)e=CGConfigureDisplayOrigin(cfg,side,0,0);
        if (!e)e=CGCompleteDisplayConfiguration(cfg,kCGConfigureForSession);
        else if (cfg)CGCancelDisplayConfiguration(cfg);
        if (e) {
            NSLog(@"Display configuration failed: %d",e);
            return ASLayoutFailed;
        }
        NSDate *end=[NSDate dateWithTimeIntervalSinceNow:3];
        while ([end timeIntervalSinceNow]>0) {
            if (CGDisplayIsOnline(side)&&CGDisplayMirrorsDisplay(side)==master&&(master||other||CGDisplayIsMain(side))) {
                NSLog(@"Verified iPad %@ (other displays=%u)",other?([mode isEqual:@"mirror"]?@"mirrors main display":@"extends desktop"):(helper?@"mirrors headless desktop":@"is main display"),other);
                return ASOK;
            }
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
        }
        NSLog(@"Display configuration verification failed");
        return ASLayoutFailed;
    }
    return ASOK;
}

static NSArray<NSDictionary *> *USBDevices(void) {
    io_iterator_t iterator=0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&iterator))return @[];
    NSMutableArray *devices=[NSMutableArray array];
    io_service_t service;
    while ((service=IOIteratorNext(iterator))) {
        CFMutableDictionaryRef properties=NULL;
        if (IORegistryEntryCreateCFProperties(service,&properties,kCFAllocatorDefault,0)==KERN_SUCCESS) {
            NSDictionary *p=CFBridgingRelease(properties);
            NSString *name=p[@"USB Product Name"], *serial=p[@"USB Serial Number"];
            if ([p[@"idVendor"] intValue]==1452 && [name isKindOfClass:NSString.class] &&
            [name rangeOfString:@"iPad" options:NSCaseInsensitiveSearch].location!=NSNotFound && serial.length)
            [devices addObject:@{
                @"name":name,@"serial":serial
            }
            ];
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return [devices sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        return [a[@"serial"] compare:b[@"serial"]];
    }
    ];
}

static id DiscoveryManager(void) {
    if (!dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore",RTLD_NOW))return nil;
    Class managerClass=NSClassFromString(@"SidecarDisplayManager");
    if (![managerClass respondsToSelector:@selector(sharedManager)]) {
        NSLog(@"Sidecar API unavailable on this macOS version");
        return nil;
    }
    id m=[managerClass sharedManager];
    for (NSString *selector in @[@"devices",@"connectedDevices",@"configForDevice:",@"connectToDevice:completion:",@"disconnectFromDevice:completion:"])
    if (![m respondsToSelector:NSSelectorFromString(selector)]) {
        NSLog(@"Unsupported Sidecar API: %@",selector);
        return nil;
    }
    return m;
}


static dispatch_queue_t dockQueue;
static ASDockController *dockController;
static NSTask *sessionProbe;
static BOOL sessionProbeAgain;
static NSUInteger preferenceGeneration;
static dispatch_source_t terminateSource, interruptSource, reloadSource;
static NSNumber *dockSessionID;
static BOOL dockStopping;

static BOOL WriteState(NSDictionary *state, NSString *name) {
    NSString *path=[configurationPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    return data&&[data writeToFile:path options:NSDataWritingAtomic error:NULL];
}
static int SessionSnapshot(void) {
    alarm(ASWorkerTimeout);
    id manager=DiscoveryManager();if(!manager)return ASUnavailable;
    CGDirectDisplayID side=0;
    for(id target in [manager connectedDevices])if([[[target identifier] description] isEqual:configuration[@"sidecarIdentifier"]])
        side=[[[manager configForDevice:target] valueForKey:@"displayID"] unsignedIntValue];
    NSArray *others=otherDisplayIDs();
    BOOL active=side&&CGDisplayIsOnline(side)&&others!=nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"active":@(active),@"side":@(side),@"otherCount":@(others.count)} options:0 error:NULL];
    if(data)fwrite(data.bytes,1,data.length,stdout);
    return data?ASOK:ASUnavailable;
}
static void CheckDockSession(void) {
    if(!dockQueue||dockStopping||recovery.suspended)return;
    if(recovery.recovering||worker.running||displayChangePending)return;
    if(sessionProbe.running){sessionProbeAgain=YES;return;}
    // No configured profiles and no historical record -> no Dock reads or Automation access.
    NSDictionary *dock=configuration[@"dock"];
    if(![dock[@"ipadOnly"] count]&&![dock[@"withOtherDisplays"] count]&&![NSFileManager.defaultManager fileExistsAtPath:DockRecordPath()])return;
    NSUInteger version=preferenceGeneration;
    NSUInteger epoch=recovery.generation,displayEpoch=displayChangeGeneration;
    NSDictionary *profiles=[dock copy];
    NSTask *probe=[NSTask new];sessionProbe=probe;
    probe.executableURL=[NSURL fileURLWithPath:executable];
    probe.arguments=@[@"session-snapshot",@"--config",RuntimeConfigPath()];
    NSPipe *output=[NSPipe pipe];probe.standardOutput=output;
    probe.terminationHandler=^(NSTask *task){
        NSData *data=[output.fileHandleForReading readDataToEndOfFile];
        NSDictionary *snapshot=task.terminationStatus==0?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
        dispatch_async(dispatch_get_main_queue(),^{
            if(!dockStopping&&!recovery.suspended&&version==preferenceGeneration&&epoch==recovery.generation&&displayEpoch==displayChangeGeneration&&!recovery.recovering&&!worker.running&&!displayChangePending&&snapshot){
                BOOL active=[snapshot[@"active"] boolValue];
                NSDictionary *profile=profiles[[snapshot[@"otherCount"] unsignedIntegerValue]?@"withOtherDisplays":@"ipadOnly"];
                dispatch_async(dockQueue,^{
                    // Recheck on the main queue after earlier Dock work finishes.
                    // A new USB/display transition invalidates queued work before it writes.
                    __block BOOL current=NO,refresh=NO;
                    dispatch_sync(dispatch_get_main_queue(),^{
                        current=!dockStopping&&!recovery.suspended&&version==preferenceGeneration&&epoch==recovery.generation&&displayEpoch==displayChangeGeneration&&!recovery.recovering&&!worker.running&&!displayChangePending;
                        if(current){refresh=dockRefreshPending;dockRefreshPending=NO;}
                    });
                    if(!current)return;
                    if(active&&dockSessionID&&![dockSessionID isEqual:snapshot[@"side"]])[dockController updateActive:NO profile:nil];
                    dockSessionID=active?snapshot[@"side"]:nil;
                    if(refresh&&active)NSLog(@"Applying Dock profile after verified layout recovery");
                    [dockController updateActive:active profile:profile refreshSize:refresh&&active];
                });
            }
            if(sessionProbeAgain){sessionProbeAgain=NO;CheckDockSession();}
        });
    };
    NSError *error=nil;if(![probe launchAndReturnError:&error])NSLog(@"Optional Dock session verification failed: %@",error);
}
static void ReconcileLayout(void) {
    if(recovery.suspended||worker.running||recovery.recovering||displayChangePending){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ReconcileLayout();});return;}
    // Apply only to an existing session. Never start/restart Sidecar just to reload preferences.
    NSTask *task=[NSTask new];worker=task;
    task.executableURL=[NSURL fileURLWithPath:executable];
    task.arguments=@[@"reconcile",@"--config",RuntimeConfigPath()];
    NSUInteger epoch=recovery.generation,version=preferenceGeneration;
    task.terminationHandler=^(NSTask *done){dispatch_async(dispatch_get_main_queue(),^{
        NSLog(@"Preference layout reconciliation %@",done.terminationStatus==0?@"completed":@"failed; session left running");
        if(done.terminationStatus==ASOK&&epoch==recovery.generation&&version==preferenceGeneration)dockRefreshPending=YES;
        CheckDockSession();
    });};
    NSError *error=nil;if(![task launchAndReturnError:&error])NSLog(@"Could not reconcile layout: %@",error);
}
static void ReloadPreferences(void) {
    NSString *directory=configurationPath.stringByDeletingLastPathComponent;
    NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:@"reload-request.plist"]];
    NSError *error=nil;NSDictionary *next=ASLoadConfig(configurationPath,&error);
    BOOL pairingMatches=next&&[next[@"usbSerial"] isEqual:configuration[@"usbSerial"]]&&[next[@"sidecarIdentifier"] isEqual:configuration[@"sidecarIdentifier"]];
    if(!next||!pairingMatches){
        NSString *message=next?@"Pairing changed; use setup and install to activate enrollment":error.localizedDescription;
        NSLog(@"Preferences not reloaded: %@",message);
        if(request[@"id"])WriteState(@{@"id":request[@"id"],@"ok":@NO,@"message":message},@"reload-result.plist");
        return;
    }
    if(!ASSaveConfig(next,RuntimeConfigPath(),&error)){
        NSLog(@"Cannot stage validated runtime preferences: %@",error);
        if(request[@"id"])WriteState(@{@"id":request[@"id"],@"ok":@NO,@"message":error.localizedDescription},@"reload-result.plist");return;
    }
    BOOL pending=virtualDisplay?![next[@"display"] isEqual:activeHelperSettings]:![next[@"display"] isEqual:configuration[@"display"]];
    configuration=next;preferenceGeneration++;
    ReconcileLayout();
    NSString *message=pending?@"Preferences loaded; active-session reconciliation requested. Headless display changes are pending until the next connection.":@"Preferences loaded; active-session reconciliation requested (see logs for results).";
    NSLog(@"%@",message);
    if(request[@"id"])WriteState(@{@"id":request[@"id"],@"ok":@YES,@"message":message},@"reload-result.plist");
}
static void InitializePreferences(void) {
    NSError *error=nil;
    if(!ASSaveConfig(configuration,RuntimeConfigPath(),&error)){NSLog(@"Cannot stage runtime config: %@",error);exit(ASUsage);}
    dockQueue=dispatch_queue_create("AutoSidecar.Dock",DISPATCH_QUEUE_SERIAL);
    dockController=[[ASDockController alloc] initWithPath:DockRecordPath() backend:[ASSystemDockBackend new]];
    dispatch_async(dockQueue,^{[dockController recover];});
    signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);signal(SIGHUP,SIG_IGN);
    terminateSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    interruptSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGINT,0,dispatch_get_main_queue());
    reloadSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGHUP,0,dispatch_get_main_queue());
    dispatch_block_t stop=^{
        dockStopping=YES;
        recovery.recovering=NO;recovery.generation++;
        if(worker.running)[worker terminate];if(sessionProbe.running)[sessionProbe terminate];
        dispatch_async(dockQueue,^{BOOL restored=[dockController restore];dispatch_async(dispatch_get_main_queue(),^{
            NSLog(@"Dock restoration on stop %@",restored?@"complete":@"incomplete; durable record retained");exit(0);
        });});
    };
    dispatch_source_set_event_handler(terminateSource,stop);dispatch_resume(terminateSource);
    dispatch_source_set_event_handler(interruptSource,stop);dispatch_resume(interruptSource);
    dispatch_source_set_event_handler(reloadSource,^{ReloadPreferences();});dispatch_resume(reloadSource);
    CheckDockSession();
}

static NSString *ReadAnswer(NSString *prompt) {
    printf("%s",prompt.UTF8String);
    fflush(stdout);
    char *line=NULL;
    size_t size=0;
    ssize_t count=getline(&line,&size,stdin);
    NSString *answer=count<0?nil:[[NSString alloc] initWithBytes:line length:(NSUInteger)count encoding:NSUTF8StringEncoding];
    free(line);
    return [answer stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSInteger Choose(NSUInteger count,NSString *prompt) {
    while (YES) {
        NSString *answer=ReadAnswer(prompt);
        if (!answer || [answer.lowercaseString isEqual:@"q"])return NSNotFound;
        NSInteger index=ASParseChoice(answer,count);
        if (index!=NSNotFound)return index;
        puts("Enter one of the listed numbers, or q to cancel.");
    }
}

static int Setup(void) {
    puts("AutoSidecar setup — one iPad per configuration.\nConnect your intended iPad by USB and keep it awake.\nNothing is saved until you confirm a successful connection.");
    NSArray *usb=USBDevices();
    if (!usb.count) {
        fprintf(stderr,"No USB iPad found. Connect a data-capable cable, then run setup again.\n");
        return ASUSBAbsent;
    }
    for (NSUInteger i=0;i<usb.count;i++)printf("USB %lu. %s — %s\n",(unsigned long)i+1,[usb[i][@"name"] UTF8String],[usb[i][@"serial"] UTF8String]);
    NSInteger usbIndex=usb.count==1?0:Choose(usb.count,@"Choose USB iPad (q cancels): ");
    if (usbIndex==NSNotFound)return ASUsage;
    if (usb.count==1)puts("Selected the only USB iPad.");
    id manager=DiscoveryManager();
    if (!manager) {
        fprintf(stderr,"Sidecar API unavailable on this macOS version.\n");
        return ASUnavailable;
    }
    NSArray *targets=[manager devices];
    if (!targets.count) {
        fprintf(stderr,"No Sidecar targets available. Wake/unlock the iPad, check Sidecar prerequisites, then retry.\n");
        return ASTargetMissing;
    }
    for (NSUInteger i=0;i<targets.count;i++)printf("Sidecar %lu. %s (%s)\n",(unsigned long)i+1,[[targets[i] name] UTF8String],[[targets[i] model] UTF8String]);
    NSInteger targetIndex=Choose(targets.count,@"Choose the matching Sidecar target (q cancels): ");
    if (targetIndex==NSNotFound)return ASUsage;
    id target=targets[(NSUInteger)targetIndex];
    NSMutableDictionary *candidate=[@{
        @"version":@1,@"usbSerial":usb[(NSUInteger)usbIndex][@"serial"],
        @"sidecarIdentifier":[[target identifier] description],@"name":[target name],@"display":ASDefaultDisplay()
    }
    mutableCopy];
    NSError *existingError=nil;
    NSDictionary *existing=nil;
    if([NSFileManager.defaultManager fileExistsAtPath:configurationPath]) {
        existing=ASLoadConfig(configurationPath,&existingError);
        if(!existing){NSLog(@"Existing preferences are invalid; fix them before re-enrollment: %@",existingError);return ASUsage;}
        candidate=ASPairingWithPreferences(existing,candidate);
    }
    configuration=candidate;
    if (!usbPresent()) {
        fprintf(stderr,"Selected USB iPad was unplugged. Nothing saved.\n");
        return ASUSBAbsent;
    }
    NSString *answer=ReadAnswer(@"Test this Sidecar connection now? [y/N]: ");
    if (![answer.lowercaseString isEqual:@"y"]&&! [answer.lowercaseString isEqual:@"yes"])return ASUsage;
    // A helper is only needed when enrolling without any other actual display.
    if (!prepareDesktop())return ASUnavailable;
    int result=RunCommand(@"ensure");
    alarm(0);
    if (result!=ASOK) {
        fprintf(stderr,"Connection test failed (%d). Existing configuration was not changed.\n",result);
        return result;
    }
    answer=ReadAnswer(@"Is the Mac desktop visible on the intended USB-connected iPad? [y/N]: ");
    if (![answer.lowercaseString isEqual:@"y"]&&! [answer.lowercaseString isEqual:@"yes"]) {
        puts("Not saved. Run setup again to choose the correct device.");
        return ASUsage;
    }
    if (!usbPresent()) {
        fprintf(stderr,"USB iPad is no longer present. Nothing saved.\n");
        return ASUSBAbsent;
    }
    CGDirectDisplayID side=[[[manager configForDevice:target] valueForKey:@"displayID"] unsignedIntValue];
    if (!existing&&side&&CGDisplayIsOnline(side)&&!virtualDisplay) {
        CGDisplayModeRef currentMode=CGDisplayCopyDisplayMode(side);
        size_t width=currentMode?CGDisplayModeGetPixelWidth(currentMode):0;
        size_t height=currentMode?CGDisplayModeGetPixelHeight(currentMode):0;
        if(currentMode)CGDisplayModeRelease(currentMode);
        if (width>=640&&height>=480&&width<=7680&&height<=7680&&width%2==0&&height%2==0)
        candidate[@"display"]=@{
            @"width":@(width),@"height":@(height),@"refreshRate":@60,@"hiDPI":@YES
        };
    }
    NSError *error=nil;
    if (!ASSaveConfig(candidate,configurationPath,&error)) {
        NSLog(@"Cannot save configuration: %@",error);
        return ASUsage;
    }
    printf("Saved pairing to %s\nRun auto-sidecar install (or rerun it to update) to start the watcher with this pairing.\n",configurationPath.UTF8String);
    if (virtualDisplay)puts("The temporary setup display closes on exit. Installation recreates it for headless use.");
    return ASOK;
}


static int Launchctl(NSArray *arguments) {
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@"/bin/launchctl"];task.arguments=arguments;
    task.standardOutput=NSFileHandle.fileHandleWithNullDevice;task.standardError=NSFileHandle.fileHandleWithNullDevice;
    if(![task launchAndReturnError:NULL])return ASUnavailable;[task waitUntilExit];return task.terminationStatus;
}
static int RequestReload(BOOL saved) {
    NSError *error=nil;if(!ASLoadConfig(configurationPath,&error)){NSLog(@"Invalid configuration: %@",error.localizedDescription);return ASUsage;}
    if(![configurationPath isEqual:ASDefaultConfigPath()]){puts("Saved custom configuration; reload its watcher separately.");return saved?ASOK:ASUsage;}
    NSString *job=[NSString stringWithFormat:@"gui/%u/local.auto-sidecar",getuid()];
    if(Launchctl(@[@"print",job])){puts(saved?"Preferences saved. Watcher is not running; they will apply when it starts.":"Watcher is not running; nothing reloaded.");return saved?ASOK:ASUnavailable;}
    NSString *identifier=NSUUID.UUID.UUIDString;
    if(!WriteState(@{@"id":identifier},@"reload-request.plist")){fprintf(stderr,"Could not write reload request.\n");return ASUsage;}
    if(Launchctl(@[@"kill",@"SIGHUP",job])){fprintf(stderr,"Preferences saved, but the reload signal failed.\n");return ASUnavailable;}
    NSString *replyPath=[configurationPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"reload-result.plist"];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:6];
    while(deadline.timeIntervalSinceNow>0){
        NSDictionary *reply=[NSDictionary dictionaryWithContentsOfFile:replyPath];
        if([reply[@"id"] isEqual:identifier]){printf("%s\n",[reply[@"message"] UTF8String]);return [reply[@"ok"] boolValue]?ASOK:ASUsage;}
        [NSThread sleepForTimeInterval:0.1];
    }
    fprintf(stderr,"Preferences saved, but the watcher did not acknowledge reload. Check logs; activation is unconfirmed.\n");return ASTimedOut;
}
static void ShowPreferences(NSDictionary *config) {
    NSMutableDictionary *shown=[ASPreferences(config) mutableCopy];
    if(!shown[@"withOtherDisplays"])shown[@"withOtherDisplays"]=@"extend";
    NSData *data=[NSJSONSerialization dataWithJSONObject:shown options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
    printf("%s\n",[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);
    if(![shown[@"dock"] count])puts("Dock management: off (no overrides).");
}
static BOOL EditDockProfile(NSMutableDictionary *config, NSString *name) {
    NSMutableDictionary *dock=[config[@"dock"] mutableCopy]?:[NSMutableDictionary dictionary];
    NSMutableDictionary *profile=[dock[name] mutableCopy]?:[NSMutableDictionary dictionary];
    for(NSString *key in @[@"size",@"magnification"]){
        NSString *prompt=[NSString stringWithFormat:@"%@ %@ (current %@): enter 16–128%@, 'unchanged' to remove override, or Enter to keep: ",name,key,profile[key]?:@"unmanaged",[key isEqual:@"magnification"]?@", or false to disable":@""];
        while(YES){
            NSString *answer=ReadAnswer(prompt);if(!answer)return NO;
            if(!answer.length)break;
            if([answer.lowercaseString isEqual:@"unchanged"]){[profile removeObjectForKey:key];break;}
            if([key isEqual:@"magnification"]&&[answer.lowercaseString isEqual:@"false"]){profile[key]=@NO;break;}
            NSInteger parsed=ASParseChoice(answer,128);
            if(parsed!=NSNotFound&&parsed+1>=16){profile[key]=@(parsed+1);break;}
            puts("Invalid value. Use an integer 16–128, unchanged, or false for magnification.");
        }
    }
    if(profile.count)dock[name]=profile;else[dock removeObjectForKey:name];
    if(dock.count)config[@"dock"]=dock;else[config removeObjectForKey:@"dock"];
    return YES;
}
static int Configure(void) {
    NSError *error=nil;NSDictionary *current=ASLoadConfig(configurationPath,&error);
    if(!current){NSLog(@"Run setup first, or fix invalid configuration: %@",error.localizedDescription);return ASUsage;}
    NSMutableDictionary *edited=[current mutableCopy];
    puts("Current preferences:");ShowPreferences(current);
    while(YES){
        puts("1. Display behavior with other displays\n2. Headless resolution/scaling\n3. iPad-only Dock profile\n4. Dock profile with other displays\n5. Review and save\n6. Cancel");
        NSInteger choice=Choose(6,@"Choose: ");if(choice==NSNotFound||choice==5)return ASUsage;
        if(choice==0){
            NSInteger mode=Choose(3,@"1. Extend  2. Mirror current main display  3. Preserve macOS layout: ");
            if(mode==NSNotFound)return ASUsage;edited[@"withOtherDisplays"]=@[@"extend",@"mirror",@"preserve"][(NSUInteger)mode];
        }else if(choice==1){
            NSMutableDictionary *display=[edited[@"display"] mutableCopy];
            puts("Width and height are backing pixels. With HiDPI, the logical desktop is half each dimension.");
            for(NSString *key in @[@"width",@"height",@"refreshRate",@"hiDPI"]){
                NSString *answer=ReadAnswer([NSString stringWithFormat:@"%@ (current %@), Enter to keep%@: ",key,display[key],[key isEqual:@"hiDPI"]?@", true/false":@""]);
                if(!answer)return ASUsage;if(!answer.length)continue;
                if([key isEqual:@"hiDPI"]){
                    if(![@[@"true",@"false"] containsObject:answer.lowercaseString]){puts("Use true or false; unchanged.");continue;}
                    display[key]=@([answer.lowercaseString isEqual:@"true"]);
                }else{
                    NSScanner *scanner=[NSScanner scannerWithString:answer];double number;
                    if(![scanner scanDouble:&number]||!scanner.isAtEnd){puts("Invalid number; unchanged.");continue;}display[key]=@(number);
                }
            }
            NSMutableDictionary *test=[edited mutableCopy];test[@"display"]=display;
            if(ASValidateConfig(test,&error))edited=test;else NSLog(@"Display edit rejected: %@",error.localizedDescription);
        }else if(choice==2||choice==3){if(!EditDockProfile(edited,choice==2?@"ipadOnly":@"withOtherDisplays"))return ASUsage;
        }else{
            puts("Proposed preferences:");ShowPreferences(edited);
            if(!ASValidateConfig(edited,&error)){NSLog(@"Invalid preferences: %@",error.localizedDescription);continue;}
            NSString *answer=ReadAnswer(@"Save these preferences? [y/N]: ");
            if(![answer.lowercaseString isEqual:@"y"]&&![answer.lowercaseString isEqual:@"yes"])return ASUsage;
            if(!ASSaveConfig(edited,configurationPath,&error)){NSLog(@"Could not save: %@",error.localizedDescription);return ASUsage;}
            if(![edited[@"display"] isEqual:current[@"display"]])puts("Headless resolution/scaling changes are deferred until the next connection; the active helper is retained.");
            return RequestReload(YES);
        }
    }
}

static int WriteLaunchAgent(NSString *binary, NSString *output, NSString *logs) {
    NSDictionary *plist=@{
        @"Label":@"local.auto-sidecar",@"ProgramArguments":@[binary,@"watch"],@"RunAtLoad":@YES,
        @"KeepAlive":@{
            @"SuccessfulExit":@NO
        }
        ,@"ThrottleInterval":@30,@"LimitLoadToSessionType":@"Aqua",
        @"ProcessType":@"Background",@"ExitTimeOut":@45,@"StandardOutPath":[logs stringByAppendingPathComponent:@"stdout.log"],
        @"StandardErrorPath":[logs stringByAppendingPathComponent:@"events.log"]
    };
    NSError *error=nil;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    if (!data||![data writeToFile:output options:NSDataWritingAtomic error:&error]) {
        NSLog(@"Cannot write LaunchAgent: %@",error);
        return ASUsage;
    }
    return ASOK;
}

// Embed the helpers so install/uninstall also work from a standalone binary.
// Pass paths as arguments, never interpolate them into shell program text.
static int LifecycleCommand(BOOL installing, BOOL purge) {
    const unsigned char *bytes = installing ? scripts_install_sh : scripts_uninstall_sh;
    unsigned int length = installing ? scripts_install_sh_len : scripts_uninstall_sh_len;
    NSString *script = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"];
    NSMutableArray *arguments = [NSMutableArray arrayWithArray:@[@"-c", script, @"auto-sidecar"]];
    if (installing) [arguments addObject:executable];
    else if (purge) [arguments addObject:@"--purge"];
    task.arguments = arguments;
    task.standardInput = NSFileHandle.fileHandleWithStandardInput;
    task.standardOutput = NSFileHandle.fileHandleWithStandardOutput;
    task.standardError = NSFileHandle.fileHandleWithStandardError;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { NSLog(@"Cannot run lifecycle command: %@", error); return ASUnavailable; }
    [task waitUntilExit];
    return task.terminationStatus;
}

int main(int argc,const char **argv) {
    @autoreleasepool {
        executable=[[[NSBundle mainBundle] executablePath] stringByStandardizingPath];
        configurationPath=ASDefaultConfigPath();
        NSMutableArray *args=[NSMutableArray array];
        for (int i=1;i<argc;i++) {
            if (strcmp(argv[i],"--config")==0) {
                if (++i>=argc) {
                    fprintf(stderr,"--config requires a path\n");
                    return ASUsage;
                }
                configurationPath=[@(argv[i]) stringByExpandingTildeInPath];
                if (!configurationPath.isAbsolutePath)configurationPath=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:configurationPath];
            }
            else [args addObject:@(argv[i])];
        }
        NSString *action=args.count?args[0]:@"status";
        if ([action isEqual:@"help"]||[action isEqual:@"--help"]) {
            puts("auto-sidecar setup|configure|config show|config validate|reload|install|uninstall [--purge]|devices|doctor|status|usb|connect|disconnect|apply|watch\nConfiguration commands accept --config PATH; install/uninstall use the default user configuration.");
            return ASOK;
        }
        if ([action isEqual:@"write-launchagent"]&&args.count==4)return WriteLaunchAgent(args[1],args[2],args[3]);
        if ([action isEqual:@"install"] || [action isEqual:@"uninstall"]) {
            BOOL installing = [action isEqual:@"install"];
            BOOL purge = !installing && args.count == 2 && [args[1] isEqual:@"--purge"];
            if (![configurationPath isEqual:ASDefaultConfigPath()] || (args.count != 1 && !purge)) {
                fprintf(stderr, "Usage: auto-sidecar install | uninstall [--purge] (default configuration only)\n");
                return ASUsage;
            }
            if (installing && ![NSFileManager.defaultManager fileExistsAtPath:configurationPath]) {
                int result = Setup();
                if (result != ASOK) return result;
            }
            return LifecycleCommand(installing, purge);
        }
        if ([action isEqual:@"config"]&&args.count==2&&[@[@"show",@"validate"] containsObject:args[1]]) {
            NSError *error=nil;NSDictionary *config=ASLoadConfig(configurationPath,&error);
            if(!config){NSLog(@"Invalid configuration: %@",error.localizedDescription);return ASUsage;}
            if([args[1] isEqual:@"show"])ShowPreferences(config);else puts("Configuration valid.");
            return ASOK;
        }
        if (args.count>1) {
            fprintf(stderr,"Unexpected arguments; use --help.\n");
            return ASUsage;
        }
        if ([action isEqual:@"devices"]) {
            for (NSDictionary *d in USBDevices())printf("USB: %s — %s\n",[d[@"name"] UTF8String],[d[@"serial"] UTF8String]);
            id manager=DiscoveryManager();
            if (!manager)return ASUnavailable;
            for (id d in [manager devices])printf("Sidecar: %s — %s\n",[[d name] UTF8String],[[[d identifier] description] UTF8String]);
            return ASOK;
        }
        if ([action isEqual:@"setup"])return Setup();
        if ([action isEqual:@"configure"])return Configure();
        if ([action isEqual:@"reload"])return RequestReload(NO);
        if ([action isEqual:@"dock-restore"]) {
            ASDockController *controller=[[ASDockController alloc] initWithPath:DockRecordPath() backend:[ASSystemDockBackend new]];
            return [controller restore]?ASOK:ASUnavailable;
        }
        NSError *error=nil;
        configuration=ASLoadConfig(configurationPath,&error);
        if (!configuration) {
            NSLog(@"Cannot load %@: %@. Run auto-sidecar setup.",configurationPath,error.localizedDescription);
            return ASUsage;
        }
        if ([action isEqual:@"doctor"]) {
            printf("Configuration valid: %s\nUSB: %s\n",configurationPath.UTF8String,usbPresent()?"attached":"absent");
            return RunCommand(@"status");
        }
        if([action isEqual:@"session-snapshot"])return SessionSnapshot();
        return RunCommand(action);
    }
}
