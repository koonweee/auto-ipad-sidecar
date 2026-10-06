#import "Config.h"
#import <sys/stat.h>

NSString *ASDefaultConfigPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/AutoSidecar/config.plist"];
}
NSDictionary *ASDefaultDisplay(void) {
    return @{@"width": @1920, @"height": @1080, @"refreshRate": @60, @"hiDPI": @YES};
}
NSUInteger ASDisplayModeDimension(NSUInteger pixels, BOOL hiDPI) {
    return hiDPI ? pixels / 2 : pixels;
}
static BOOL Invalid(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"AutoSidecar.Config" code:1
                                       userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
static BOOL NonemptyString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0;
}
static BOOL IsBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static BOOL DockSize(id value) {
    if (![value isKindOfClass:NSNumber.class] || IsBoolean(value)) return NO;
    double n=[value doubleValue];return isfinite(n)&&n==floor(n)&&n>=16&&n<=128;
}
BOOL ASValidatePreferences(NSDictionary *config, NSError **error) {
    id mode=config[@"withOtherDisplays"];
    if(mode&&![@[@"extend",@"mirror",@"preserve"] containsObject:mode])return Invalid(error,@"withOtherDisplays must be extend, mirror, or preserve.");
    id dock=config[@"dock"];
    if(dock) {
        if(![dock isKindOfClass:NSDictionary.class])return Invalid(error,@"dock must be a dictionary.");
        for(NSString *profileName in dock) {
            if(![@[@"ipadOnly",@"withOtherDisplays"] containsObject:profileName])return Invalid(error,@"Unknown Dock profile; use ipadOnly or withOtherDisplays.");
            id profile=dock[profileName];
            if(![profile isKindOfClass:NSDictionary.class])return Invalid(error,@"Dock profiles must be dictionaries.");
            for(NSString *key in profile)if(![@[@"size",@"magnification"] containsObject:key])return Invalid(error,@"Unknown Dock setting; use size or magnification.");
            if(profile[@"size"]&&!DockSize(profile[@"size"]))return Invalid(error,@"Dock size must be an integer from 16 to 128 (not a boolean).");
            id mag=profile[@"magnification"];
            if(mag&&!(DockSize(mag)||(IsBoolean(mag)&&![mag boolValue])))return Invalid(error,@"Dock magnification must be an integer 16–128 or boolean false.");
        }
    }
    if(config[@"ipadOnlyDock"]||config[@"headlessEnabled"]||config[@"disconnectOnUnplug"]||config[@"connectOnStartup"])return Invalid(error,@"Unsupported preference key.");
    return YES;
}
NSDictionary *ASPreferences(NSDictionary *config) {
    NSMutableDictionary *prefs=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"display",@"withOtherDisplays",@"dock"])if(config[key])prefs[key]=config[key];
    return prefs;
}
NSMutableDictionary *ASPairingWithPreferences(NSDictionary *old, NSDictionary *pairing) {
    NSMutableDictionary *result=[pairing mutableCopy];[result addEntriesFromDictionary:ASPreferences(old?:@{})];return result;
}
BOOL ASValidateConfig(id config, NSError **error) {
    if (![config isKindOfClass:NSDictionary.class]) return Invalid(error, @"Configuration must be a dictionary.");
    if (![config[@"version"] isEqual:@1]) return Invalid(error, @"Unsupported configuration version; run setup again.");
    if (!NonemptyString(config[@"usbSerial"]) || !NonemptyString(config[@"sidecarIdentifier"]))
        return Invalid(error, @"Missing USB serial or Sidecar identifier; run setup.");
    id display = config[@"display"];
    if (![display isKindOfClass:NSDictionary.class]) return Invalid(error, @"Missing display configuration.");
    for (NSString *key in @[@"width", @"height", @"refreshRate", @"hiDPI"]) {
        if (![display[key] isKindOfClass:NSNumber.class]) return Invalid(error, @"Display settings must be numeric.");
    }
    double w = [display[@"width"] doubleValue], h = [display[@"height"] doubleValue];
    double hz = [display[@"refreshRate"] doubleValue];
    if (w < 640 || w > 7680 || h < 480 || h > 7680 || w != floor(w) || h != floor(h) || !isfinite(w) || !isfinite(h))
        return Invalid(error, @"Display dimensions must be whole pixels within supported bounds.");
    if (!isfinite(hz) || hz < 24 || hz > 120) return Invalid(error, @"Refresh rate must be 24–120 Hz.");
    if (![display[@"hiDPI"] isEqual:@0] && ![display[@"hiDPI"] isEqual:@1]) return Invalid(error, @"hiDPI must be true or false.");
    if ([display[@"hiDPI"] boolValue] && ((NSUInteger)w % 2 || (NSUInteger)h % 2))
        return Invalid(error, @"HiDPI backing width and height must be even numbers.");
    return ASValidatePreferences(config,error);
}
NSDictionary *ASLoadConfig(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;
    id config = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
    return ASValidateConfig(config, error) ? config : nil;
}
BOOL ASSaveConfig(NSDictionary *config, NSString *path, NSError **error) {
    if (!ASValidateConfig(config, error)) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:config format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    // Atomic replacement: cancellation or a failed test never destroys an existing pairing.
    if (![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    return [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:error];
}
NSInteger ASParseChoice(NSString *text, NSUInteger count) {
    NSScanner *scanner = [NSScanner scannerWithString:[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    NSInteger selection = 0;
    if (![scanner scanInteger:&selection] || !scanner.isAtEnd || selection < 1 || (NSUInteger)selection > count) return NSNotFound;
    return selection - 1;
}
