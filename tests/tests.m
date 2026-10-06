#import "../src/Config.h"
#import "../src/Policy.h"
#import <sys/stat.h>
#define CHECK(condition) do { if(!(condition)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#condition);exit(1);} } while(0)
int main(void) { @autoreleasepool {
    NSDictionary *good=@{@"version":@1,@"usbSerial":@"TEST-USB",@"sidecarIdentifier":@"TEST-SID",@"display":ASDefaultDisplay()};
    NSError *error=nil;
    CHECK(ASValidateConfig(good,&error));
    CHECK(ASDisplayModeDimension(2560,YES)==1280);
    CHECK(ASDisplayModeDimension(1680,YES)==840);
    CHECK(ASDisplayModeDimension(2560,NO)==2560);
    CHECK(ASDisplayModeDimension(1680,NO)==1680);
    NSMutableDictionary *resolution=[good mutableCopy];
    resolution[@"display"]=@{@"width":@2560,@"height":@1680,@"refreshRate":@60,@"hiDPI":@YES};
    CHECK(ASValidateConfig(resolution,NULL));
    resolution[@"display"]=@{@"width":@2561,@"height":@1680,@"refreshRate":@60,@"hiDPI":@YES};
    CHECK(!ASValidateConfig(resolution,NULL));
    resolution[@"display"]=@{@"width":@2560,@"height":@1681,@"refreshRate":@60,@"hiDPI":@YES};
    CHECK(!ASValidateConfig(resolution,NULL));
    resolution[@"display"]=@{@"width":@2561,@"height":@1681,@"refreshRate":@60,@"hiDPI":@NO};
    CHECK(ASValidateConfig(resolution,NULL));
    for(id bad in @[@{},@[],@{@"version":@2},@{@"version":@1,@"usbSerial":@1}])CHECK(!ASValidateConfig(bad,NULL));
    NSMutableDictionary *bad=[good mutableCopy];
    bad[@"display"]=@{@"width":@(-1),@"height":@1080,@"refreshRate":@60,@"hiDPI":@YES};
    CHECK(!ASValidateConfig(bad,NULL));
    CHECK(ASParseChoice(@" 2\n",3)==1);
    for(NSString *answer in @[@"",@"0",@"-1",@"4",@"2x",@"1.5",@"999999999999999999999999999"])CHECK(ASParseChoice(answer,3)==NSNotFound);
    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *file=[dir stringByAppendingPathComponent:@"config.plist"];
    CHECK(ASSaveConfig(good,file,&error));
    CHECK([ASLoadConfig(file,&error) isEqual:good]);
    CHECK(!ASSaveConfig(bad,file,&error));
    CHECK([ASLoadConfig(file,&error) isEqual:good]); // failed update preserves enrollment
    struct stat st;CHECK(stat(file.fileSystemRepresentation,&st)==0);CHECK((st.st_mode&0777)==0600);
    CHECK(ASAttemptIsCurrent(3,3,YES,YES));
    CHECK(!ASAttemptIsCurrent(2,3,YES,YES)); // cancelled USB bounce callback
    CHECK(!ASAttemptIsCurrent(3,3,NO,YES));
    CHECK(!ASAttemptIsCurrent(3,3,YES,NO));
    CHECK(ASMaxAttempts==5);CHECK(ASRetryDelay(1)+ASRetryDelay(2)+ASRetryDelay(3)+ASRetryDelay(4)==50);
    CHECK(!ASShouldReleaseHelper(YES,NO,NO,0)); // retain during recovery
    CHECK(!ASShouldReleaseHelper(NO,YES,NO,0)); // retain during outstanding worker
    CHECK(!ASShouldReleaseHelper(NO,NO,YES,0)); // preserve active headless / wireless session
    CHECK(ASShouldReleaseHelper(NO,NO,NO,0)); // failed recovery / session ended
    CHECK(ASShouldReleaseHelper(NO,NO,YES,1)); // physical monitor returned, even without USB
    [NSFileManager.defaultManager removeItemAtPath:dir error:NULL];
    puts("PASS: configuration, enrollment input, atomic replacement, permissions, stale events, retry policy, helper lifecycle");
} }
