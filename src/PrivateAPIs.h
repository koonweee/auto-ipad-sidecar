#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Undocumented macOS interfaces. Keep declarations isolated and check availability.
// API references (attribution and upstream licensing details in README.md):
// https://github.com/Fuzzy-Team/virtual-monitor-helper/blob/main/CGVirtualDisplayPrivate.h
// https://github.com/Ocasio-J/SidecarLauncher
@interface VDDescriptor : NSObject
@property(retain) NSString *name;
@property unsigned int maxPixelsWide,maxPixelsHigh,vendorID,productID,serialNum;
@property CGSize sizeInMillimeters;
@property(retain) dispatch_queue_t queue;
@end
@interface VDMode : NSObject
- (id)initWithWidth:(NSUInteger)w height:(NSUInteger)h refreshRate:(double)r;
@end
@interface VDSettings : NSObject
@property unsigned int hiDPI;
@property(retain) NSArray *modes;
@end
@interface VD : NSObject
- (id)initWithDescriptor:(id)d;
- (BOOL)applySettings:(id)s;
@property(readonly) CGDirectDisplayID displayID;
@end

@interface NSObject (SC)
+ (id)sharedManager;
- (NSArray *)devices;
- (NSArray *)connectedDevices;
- (id)identifier;
- (id)name;
- (id)model;
- (id)configForDevice:(id)d;
- (id)displayID;
- (void)connectToDevice:(id)d completion:(void (^)(NSError *))c;
- (void)disconnectFromDevice:(id)d completion:(void (^)(NSError *))c;
@end
