#import <Foundation/Foundation.h>

NSString *ASDefaultConfigPath(void);
NSDictionary *ASDefaultDisplay(void);
NSUInteger ASDisplayModeDimension(NSUInteger pixels, BOOL hiDPI);
BOOL ASValidateConfig(id config, NSError **error);
NSDictionary *ASLoadConfig(NSString *path, NSError **error);
BOOL ASSaveConfig(NSDictionary *config, NSString *path, NSError **error);
NSInteger ASParseChoice(NSString *text, NSUInteger count);

BOOL ASValidatePreferences(NSDictionary *config, NSError **error);
NSDictionary *ASPreferences(NSDictionary *config);
NSMutableDictionary *ASPairingWithPreferences(NSDictionary *old, NSDictionary *pairing);
