#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MDPluginEditor : NSObject
@property(nonatomic, readonly) NSString* name;
- (nullable NSView*)makeView;
@end
@interface MDAudioController : NSObject
+ (NSArray<NSDictionary<NSString*, id>*>*)availablePlugins;
+ (BOOL)runPluginScannerCommand;
- (NSDictionary<NSString*,NSData*>*)pluginStates;
- (void)unloadPlugins;
- (void)reloadPlugin:(NSString*)insertID;
- (nullable MDPluginEditor*)pluginEditor:(NSString*)insertID;
+ (NSArray<NSNumber*>*)equalizerResponse:(NSDictionary<NSString*, NSNumber*>*)settings;
- (NSArray<NSDictionary<NSString*, id>*>*)devices;
- (NSArray<NSDictionary<NSString*, id>*>*)applications;
- (BOOL)startSession:(NSDictionary<NSString*, id>*)session error:(NSError**)error;
- (BOOL)updateSession:(NSDictionary<NSString*, id>*)session error:(NSError**)error;
- (void)stop;
- (NSDictionary<NSString*, id>*)status;
- (void)resetMeter:(NSString*)ownerID isBus:(BOOL)isBus;
- (void)resetAllMeters;
- (NSArray<NSDictionary<NSString*, id>*>*)virtualDevices;
// Read-only: state, installedBuild, loadedBuild, protocolVersion, and message.
- (NSDictionary<NSString*, id>*)driverStatus;
- (BOOL)createVirtualDevice:(NSString*)name channels:(NSInteger)channels error:(NSError**)error;
- (BOOL)renameVirtualDevice:(NSString*)uid name:(NSString*)name error:(NSError**)error;
- (BOOL)deleteVirtualDevice:(NSString*)uid error:(NSError**)error;
@end
NS_ASSUME_NONNULL_END
