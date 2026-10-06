#import "../src/Dock.h"
#import "../src/Config.h"
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);exit(1);}}while(0)
@interface FakeDock : NSObject <ASDockBackend>
@property NSMutableDictionary *values;
@property NSUInteger reads,writes;
@property BOOL denied;
@end
@implementation FakeDock
- (instancetype)init{if((self=[super init]))_values=[@{@"tilesize":@48,@"largesize":@80,@"magnification":@YES} mutableCopy];return self;}
- (NSDictionary *)read:(NSError **)error{(void)error;self.reads++;return [self.values copy];}
- (BOOL)writeKey:(NSString *)key value:(NSNumber *)value error:(NSError **)error{
 self.writes++;if(self.denied){if(error)*error=[NSError errorWithDomain:@"test.denied" code:1 userInfo:nil];return NO;}self.values[key]=value;return YES;
}
@end
@interface RoundingDock : ASSystemDockBackend
@property NSMutableDictionary *values;
@property NSUInteger calls;
@property NSString *previousSizeValue,*lastSizeValue;
@end
@implementation RoundingDock
- (instancetype)init{if((self=[super init]))_values=[@{@"tilesize":@48,@"largesize":@80,@"magnification":@YES} mutableCopy];return self;}
- (NSDictionary *)read:(NSError **)error{(void)error;return [self.values copy];}
- (BOOL)executeKey:(NSString *)key normalizedValue:(NSString *)value error:(NSError **)error{
 (void)error;self.calls++;
 if([key isEqual:@"tilesize"]){self.previousSizeValue=self.lastSizeValue;self.lastSizeValue=value;}
 if([key isEqual:@"magnification"])self.values[key]=@([value isEqual:@"true"]);
 else self.values[key]=@(MAX(16,MIN(128,(int)floor(16+value.doubleValue*112-0.0000001))));
 return YES;
}
@end
int main(void){@autoreleasepool{
 NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 NSString *path=[directory stringByAppendingPathComponent:@"dock-restoration.plist"];
 FakeDock *backend=[FakeDock new];
 ASDockController *controller=[[ASDockController alloc] initWithPath:path backend:backend];
 CHECK([controller recover]);[controller updateActive:NO profile:@{@"size":@20}];
 [controller updateActive:YES profile:nil];[controller updateActive:YES profile:@{}];CHECK([controller restore]);
 CHECK(backend.reads==0&&backend.writes==0); // Default never touches Dock or requests Automation.
 [controller updateActive:YES profile:nil refreshSize:YES];CHECK(backend.reads==0&&backend.writes==0);
 [controller updateActive:YES profile:@{@"size":@20}];
 CHECK([backend.values[@"tilesize"] isEqual:@20]);CHECK([backend.values[@"largesize"] isEqual:@80]);
 NSUInteger writes=backend.writes;[controller updateActive:YES profile:@{@"size":@20}];CHECK(backend.writes==writes);
 // Successful layout completion forces exactly one size write, even at the same value.
 [controller updateActive:YES profile:@{@"size":@20} refreshSize:YES];CHECK(backend.writes==writes+1);
 writes=backend.writes;[controller updateActive:YES profile:@{@"size":@20}];CHECK(backend.writes==writes);
 // Profile switch restores omitted size; false changes only magnification, not largesize.
 [controller updateActive:YES profile:@{@"magnification":@NO}];
 CHECK([backend.values[@"tilesize"] isEqual:@48]);CHECK([backend.values[@"magnification"] isEqual:@NO]);CHECK([backend.values[@"largesize"] isEqual:@80]);
 [controller updateActive:YES profile:@{@"size":@35,@"magnification":@40}];
 CHECK([backend.values[@"tilesize"] isEqual:@35]);CHECK([backend.values[@"largesize"] isEqual:@40]);CHECK([backend.values[@"magnification"] isEqual:@YES]);
 [controller updateActive:YES profile:@{}];CHECK([backend.values[@"tilesize"] isEqual:@48]);CHECK([backend.values[@"largesize"] isEqual:@80]);
 // Still the original session snapshot, never a previous profile's values.
 [controller updateActive:YES profile:@{@"size":@20}];[controller updateActive:NO profile:nil];CHECK([backend.values[@"tilesize"] isEqual:@48]);CHECK(![NSFileManager.defaultManager fileExistsAtPath:path]);
 // Preserve a manual change during management, even on a subsequent profile switch.
 [controller updateActive:YES profile:@{@"size":@20}];backend.values[@"tilesize"]=@55;
 [controller updateActive:YES profile:@{@"size":@35}];CHECK([backend.values[@"tilesize"] isEqual:@55]);
 [controller updateActive:NO profile:nil];CHECK([backend.values[@"tilesize"] isEqual:@55]);
 // Forced refresh must also preserve a manually changed size.
 [controller updateActive:YES profile:@{@"size":@20}];backend.values[@"tilesize"]=@56;
 writes=backend.writes;[controller updateActive:YES profile:@{@"size":@20} refreshSize:YES];
 CHECK(backend.writes==writes);CHECK([backend.values[@"tilesize"] isEqual:@56]);
 [controller updateActive:NO profile:nil];backend.values[@"tilesize"]=@55;
 // Returning to an unmanaged profile refreshes an owned size even if it equals the baseline.
 [controller updateActive:YES profile:@{@"size":@55}];writes=backend.writes;
 [controller updateActive:YES profile:@{} refreshSize:YES];CHECK(backend.writes==writes+1);
 CHECK([backend.values[@"tilesize"] isEqual:@55]);[controller updateActive:NO profile:nil];
 // Crash recovery: discard controller, then restore with a fresh instance and existing journal.
 [controller updateActive:YES profile:@{@"size":@22,@"magnification":@NO}];
 controller=[[ASDockController alloc] initWithPath:path backend:backend];CHECK([controller recover]);
 CHECK([backend.values[@"tilesize"] isEqual:@55]);CHECK([backend.values[@"magnification"] isEqual:@YES]);
 // Restore denied -> keep durable record; a new process must not adopt overrides as originals.
 [controller updateActive:YES profile:@{@"size":@22}];backend.denied=YES;CHECK(![controller restore]);
 CHECK([NSFileManager.defaultManager fileExistsAtPath:path]);
 controller=[[ASDockController alloc] initWithPath:path backend:backend];CHECK(![controller recover]);
 writes=backend.writes;[controller updateActive:YES profile:@{@"size":@35}];CHECK(backend.writes==writes);
 backend.denied=NO;CHECK([controller recover]);CHECK([backend.values[@"tilesize"] isEqual:@55]);
 // Denied application doesn't escape into Sidecar, and does not change live values.
 backend.denied=YES;[controller updateActive:YES profile:@{@"size":@20}];CHECK([backend.values[@"tilesize"] isEqual:@55]);backend.denied=NO;CHECK([controller restore]);
 // Simulate crash between the OS write and recording its readback (write-ahead intent).
 NSDictionary *pending=@{@"version":@1,@"original":@{@"tilesize":@55,@"largesize":@80,@"magnification":@YES},@"owned":@{@"tilesize":@{@"expected":@55,@"intent":@20}},@"blocked":@[]};
 [pending writeToFile:path atomically:YES];backend.values[@"tilesize"]=@20;
 controller=[[ASDockController alloc] initWithPath:path backend:backend];CHECK([controller recover]);CHECK([backend.values[@"tilesize"] isEqual:@55]);
 RoundingDock *rounding=[RoundingDock new];CHECK([rounding writeKey:@"tilesize" value:@48 error:NULL]);CHECK([rounding.values[@"tilesize"] isEqual:@48]);CHECK(rounding.calls>=2);
 CHECK([rounding.lastSizeValue isEqual:rounding.previousSizeValue]); // Final refresh repeats the exact successful value.
 CHECK([rounding writeKey:@"largesize" value:@80 error:NULL]);CHECK([rounding.values[@"largesize"] isEqual:@80]);
 // Optional preferences: strict boolean-vs-number handling and old version-1 defaults.
 NSMutableDictionary *config=[@{@"version":@1,@"usbSerial":@"USB",@"sidecarIdentifier":@"SID",@"display":ASDefaultDisplay()} mutableCopy];
 CHECK(ASValidateConfig(config,NULL));
 for(id invalid in @[@YES,@0,@15,@129,@20.5]){config[@"dock"]=@{@"ipadOnly":@{@"size":invalid}};CHECK(!ASValidateConfig(config,NULL));}
 for(id invalid in @[@YES,@0,@1,@15,@129,@20.5]){config[@"dock"]=@{@"ipadOnly":@{@"magnification":invalid}};CHECK(!ASValidateConfig(config,NULL));}
 config[@"dock"]=@{@"ipadOnly":@{@"size":@20,@"magnification":@40},@"withOtherDisplays":@{@"magnification":@NO}};
 config[@"withOtherDisplays"]=@"preserve";CHECK(ASValidateConfig(config,NULL));
 NSDictionary *newPair=@{@"version":@1,@"usbSerial":@"NEW-USB",@"sidecarIdentifier":@"NEW-SID",@"display":ASDefaultDisplay()};
 NSDictionary *merged=ASPairingWithPreferences(config,newPair);CHECK([merged[@"dock"] isEqual:config[@"dock"]]);CHECK([merged[@"usbSerial"] isEqual:@"NEW-USB"]);CHECK([merged[@"withOtherDisplays"] isEqual:@"preserve"]);
 config[@"dock"]=@{@"ipadOnly":@{@"magnifiedSize":@40}};CHECK(!ASValidateConfig(config,NULL));
 [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];
 puts("PASS: Dock default no-op, partial overrides, profile switches, original snapshot, manual changes, denied access, durable crash recovery, rounding verification, preference validation/preservation");
}}
