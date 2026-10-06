#import "Dock.h"
#import <CoreFoundation/CoreFoundation.h>

static NSError *DockError(NSString *message) {
    return [NSError errorWithDomain:@"AutoSidecar.Dock" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
NSDictionary *ASDockDesiredValues(NSDictionary *profile) {
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    if (profile[@"size"]) values[@"tilesize"]=profile[@"size"];
    id magnification=profile[@"magnification"];
    if (magnification) {
        if (CFGetTypeID((__bridge CFTypeRef)magnification)==CFBooleanGetTypeID()) values[@"magnification"]=@NO;
        else { values[@"magnification"]=@YES; values[@"largesize"]=magnification; }
    }
    return values;
}
@implementation ASSystemDockBackend
- (NSDictionary *)read:(NSError **)error {
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    for (NSString *key in @[@"tilesize",@"largesize",@"magnification"]) {
        id value=CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,CFSTR("com.apple.dock")));
        if (![value isKindOfClass:NSNumber.class]) { if(error)*error=DockError(@"Dock preference unavailable; leaving Dock unchanged");return nil; }
        values[key]=[key isEqual:@"magnification"]?@([value boolValue]):value;
    }
    return values;
}
- (BOOL)executeKey:(NSString *)key normalizedValue:(NSString *)value error:(NSError **)error {
    NSString *property=[@{@"tilesize":@"dock size",@"largesize":@"magnification size",@"magnification":@"magnification"} objectForKey:key];
    if(!property){if(error)*error=DockError(@"Unknown Dock setting");return NO;}
    NSString *script=[NSString stringWithFormat:@"with timeout of 3 seconds\ntell application \"System Events\" to tell dock preferences to set %@ to %@\nend timeout",property,value];
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@"/usr/bin/osascript"];
    task.arguments=@[@"-e",script];task.standardOutput=NSFileHandle.fileHandleWithNullDevice;
    task.standardError=NSFileHandle.fileHandleWithNullDevice;
    if(![task launchAndReturnError:error])return NO;
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(task.running&&deadline.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:0.05];
    if(task.running){[task terminate];if(error)*error=DockError(@"Dock Automation timed out");return NO;}
    if(task.terminationStatus){if(error)*error=DockError(@"Dock Automation failed or permission was denied");return NO;}
    return YES;
}
- (BOOL)writeKey:(NSString *)key value:(NSNumber *)target error:(NSError **)error {
    double correction=0;
    for(int attempt=0;attempt<3;attempt++) {
        NSString *value=[key isEqual:@"magnification"]?([target boolValue]?@"true":@"false"):
            [NSString stringWithFormat:@"%.12f",fmin(1,fmax(0,([target doubleValue]-16+correction)/112.0))];
        if(![self executeKey:key normalizedValue:value error:error])return NO;
        // Read back actual preference values: normalized scripting values can round down a tile.
        for(int poll=0;poll<10;poll++) {
            NSDictionary *actual=[self read:error];if(!actual)return NO;
            if([actual[key] isEqual:target]) {
                // macOS can retain the old window reservation after changing Dock size.
                // Reassert the successful scripting value after readback, without another
                // size transition, so the Dock recomputes its usable-screen boundary.
                if([key isEqual:@"tilesize"]){
                    if(![self executeKey:key normalizedValue:value error:error])return NO;
                    NSDictionary *confirmed=[self read:error];
                    return [confirmed[key] isEqual:target];
                }
                return YES;
            }
            [NSThread sleepForTimeInterval:0.05];
        }
        NSDictionary *actual=[self read:error];if(!actual)return NO;
        if([key isEqual:@"magnification"])break;
        correction=[actual[key] doubleValue]<target.doubleValue?0.25:-0.25;
    }
    if(error)*error=DockError(@"Dock readback did not match the requested value; restoration record retained");return NO;
}
@end

@interface ASDockController ()
@property NSString *path;
@property id<ASDockBackend> backend;
@property NSMutableDictionary *record;
@property NSDictionary *lastDesired;
@property BOOL lastActive;
@property BOOL loadFailed;
@property BOOL recoveryBlocked;
@end
@implementation ASDockController
- (instancetype)initWithPath:(NSString *)path backend:(id<ASDockBackend>)backend {
    if((self=[super init])){
        _path=path;_backend=backend;
        if([NSFileManager.defaultManager fileExistsAtPath:path]) {
            NSData *data=[NSData dataWithContentsOfFile:path];
            id record=data?[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:NULL]:nil;
            BOOL valid=[record isKindOfClass:NSDictionary.class]&&[record[@"version"] isEqual:@1]&&
                [record[@"original"] isKindOfClass:NSDictionary.class]&&[record[@"owned"] isKindOfClass:NSDictionary.class]&&[record[@"blocked"] isKindOfClass:NSArray.class];
            NSSet *keys=[NSSet setWithArray:@[@"tilesize",@"largesize",@"magnification"]];
            if(valid)for(NSString *key in keys) {
                id value=record[@"original"][key];
                if(![value isKindOfClass:NSNumber.class]){valid=NO;break;}
                double n=[value doubleValue];
                if([key isEqual:@"magnification"]){if(n!=0&&n!=1)valid=NO;}
                else if(!isfinite(n)||n<16||n>128||floor(n)!=n)valid=NO;
            }
            if(valid)for(NSString *key in record[@"original"])if(![keys containsObject:key])valid=NO;
            if(valid)for(NSString *key in record[@"owned"]) {
                id entry=record[@"owned"][key];
                if(![keys containsObject:key]||![entry isKindOfClass:NSDictionary.class]||![entry[@"expected"] isKindOfClass:NSNumber.class]||![record[@"original"][key] isKindOfClass:NSNumber.class])valid=NO;
            }
            if(valid)_record=record;
            else {_loadFailed=YES;NSLog(@"Invalid Dock restoration record at %@; refusing Dock changes",path);}
        }
    }return self;
}
- (BOOL)save {
    NSError *error=nil;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:self.record format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    BOOL ok=data&&[NSFileManager.defaultManager createDirectoryAtPath:self.path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]&&[data writeToFile:self.path options:NSDataWritingAtomic error:&error];
    if(ok)ok=[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:self.path error:&error];
    if(!ok)NSLog(@"Cannot persist Dock restoration record: %@",error);
    return ok;
}
- (BOOL)removeRecord {
    if(!self.record)return !self.loadFailed;
    NSError *error=nil;
    if(![NSFileManager.defaultManager removeItemAtPath:self.path error:&error]&&[NSFileManager.defaultManager fileExistsAtPath:self.path]){NSLog(@"Cannot remove Dock restoration record: %@",error);return NO;}
    self.record=nil;return YES;
}
- (void)blockKey:(NSString *)key {
    if(![self.record[@"blocked"] containsObject:key])[self.record[@"blocked"] addObject:key];
    [self.record[@"owned"] removeObjectForKey:key];
    NSLog(@"Dock %@ changed outside AutoSidecar; preserving manual value",key);
}
- (BOOL)changeKey:(NSString *)key to:(NSNumber *)desired current:(NSNumber *)current {
    // Write-ahead intent allows recovery if the process exits between setting and readback.
    self.record[@"owned"][key]=[@{@"expected":current,@"intent":desired} mutableCopy];
    if(![self save])return NO;
    NSError *error=nil;
    BOOL ok=[self.backend writeKey:key value:desired error:&error];
    NSDictionary *actual=[self.backend read:NULL];
    if(actual[key])self.record[@"owned"][key]=[@{@"expected":actual[key]} mutableCopy];
    BOOL saved=[self save];
    if(!ok)NSLog(@"Optional Dock change failed: %@",error);
    return saved&&ok&&[actual[key] isEqual:desired];
}
- (BOOL)restoreKeysExcept:(NSDictionary *)desired refreshSize:(BOOL)refreshSize {
    BOOL ok=YES;
    for(NSString *key in [self.record[@"owned"] allKeys]) {
        if(desired[key])continue;
        NSError *error=nil;NSDictionary *actual=[self.backend read:&error];
        if(!actual){NSLog(@"Cannot read Dock for restoration: %@",error);return NO;}
        NSDictionary *entry=self.record[@"owned"][key];
        if(![actual[key] isEqual:entry[@"expected"]]&&![actual[key] isEqual:entry[@"intent"]]){[self blockKey:key];ok=[self save]&&ok;continue;}
        NSNumber *original=self.record[@"original"][key];
        BOOL refresh=refreshSize&&[key isEqual:@"tilesize"];
        if(([actual[key] isEqual:original]&&!refresh)||[self changeKey:key to:original current:actual[key]]) {
            [self.record[@"owned"] removeObjectForKey:key];ok=[self save]&&ok;
        }else ok=NO;
    }return ok;
}
- (BOOL)restoreKeysExcept:(NSDictionary *)desired {
    return [self restoreKeysExcept:desired refreshSize:NO];
}
- (BOOL)restore {
    if(self.loadFailed)return NO;
    if(!self.record)return YES; // No feature/history means no Dock reads, scripts or permission prompts.
    if(![self restoreKeysExcept:@{}])return NO;
    return [self removeRecord];
}
- (BOOL)recover { self.lastDesired=nil;self.lastActive=NO;BOOL ok=[self restore];self.recoveryBlocked=!ok;return ok; }
- (void)updateActive:(BOOL)active profile:(NSDictionary *)profile {
    [self updateActive:active profile:profile refreshSize:NO];
}
- (void)updateActive:(BOOL)active profile:(NSDictionary *)profile refreshSize:(BOOL)refreshSize {
    NSDictionary *desired=active?ASDockDesiredValues(profile?:@{}):@{};
    if(!refreshSize&&self.lastDesired&&self.lastActive==active&&[self.lastDesired isEqual:desired])return;
    self.lastDesired=desired;self.lastActive=active;
    if(self.loadFailed||self.recoveryBlocked)return;
    if(!active){[self restore];return;}
    if(!desired.count&&!self.record)return;
    if(!self.record) {
        NSError *error=nil;NSDictionary *original=[self.backend read:&error];
        if(!original){NSLog(@"Cannot snapshot Dock: %@",error);return;}
        self.record=[@{@"version":@1,@"original":original,@"owned":[NSMutableDictionary dictionary],@"blocked":[NSMutableArray array]} mutableCopy];
        if(![self save]){self.record=nil;return;}
    }
    if(![self restoreKeysExcept:desired refreshSize:refreshSize])return;
    for(NSString *key in [[desired allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if([self.record[@"blocked"] containsObject:key])continue;
        NSDictionary *actual=[self.backend read:NULL];if(!actual)return;
        NSDictionary *entry=self.record[@"owned"][key];
        NSNumber *expected=entry?entry[@"expected"]:self.record[@"original"][key];
        if(![actual[key] isEqual:expected]){[self blockKey:key];[self save];continue;}
        if(![actual[key] isEqual:desired[key]]||(refreshSize&&[key isEqual:@"tilesize"])){if(![self changeKey:key to:desired[key] current:actual[key]]){[self restoreKeysExcept:@{}];return;}}
        else {self.record[@"owned"][key]=[@{@"expected":actual[key]} mutableCopy];if(![self save])return;}
    }
}
@end
