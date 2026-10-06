#import <Foundation/Foundation.h>

// Raw values: tilesize/largesize in pixels, magnification as a boolean.
@protocol ASDockBackend <NSObject>
- (NSDictionary *)read:(NSError **)error;
- (BOOL)writeKey:(NSString *)key value:(NSNumber *)value error:(NSError **)error;
@end
@interface ASSystemDockBackend : NSObject <ASDockBackend>
// Isolated transport boundary, overridable by tests without touching the real Dock.
- (BOOL)executeKey:(NSString *)key normalizedValue:(NSString *)value error:(NSError **)error;
@end
@interface ASDockController : NSObject
- (instancetype)initWithPath:(NSString *)path backend:(id<ASDockBackend>)backend;
- (BOOL)recover;
- (void)updateActive:(BOOL)active profile:(NSDictionary *)profile;
- (void)updateActive:(BOOL)active profile:(NSDictionary *)profile refreshSize:(BOOL)refreshSize;
- (BOOL)restore;
@end
NSDictionary *ASDockDesiredValues(NSDictionary *profile);
