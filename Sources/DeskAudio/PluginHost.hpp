#pragma once
#import "include/DeskAudio.h"
#include "InsertProcessor.hpp"
#include <memory>

// All rack operations belong to the serialized audio control queue. Editor
// creation belongs to the main thread. Only process/setBypassed run in IO.
NS_ASSUME_NONNULL_BEGIN
@interface MDPluginRack : NSObject
+ (NSArray<NSDictionary<NSString*,id>*>*)catalog;
- (void)prepareSession:(NSDictionary*)session retireAfter:(uint64_t)generation;
- (desk::InsertProcessor*)processor:(NSString*)identifier;
- (void)collectThrough:(uint64_t)generation;
- (void)resetStopped;
- (void)retry:(NSString*)identifier;
- (NSArray<NSDictionary<NSString*,id>*>*)status;
- (NSDictionary<NSString*,NSData*>*)states;
- (nullable MDPluginEditor*)editor:(NSString*)identifier;
@end

namespace desk {
class HostedProcessor : public InsertProcessor {
public:
    NSString* _Nullable failure=nil;
    NSString* name=@"Plugin";
    virtual bool available()const=0;
    virtual bool monoInput()const=0;
    virtual int32_t renderError()const=0;
    virtual void resetStopped()=0;
    virtual NSData* _Nullable data()const=0;
    virtual NSView* _Nullable makeView()=0;
    virtual void service() {} // Serialized control queue; never called by IO.
};
NSArray* audioUnitCatalog();
NSArray* vst3Catalog();
bool runVST3ScanCommand();
std::shared_ptr<HostedProcessor> makeAudioUnit(NSString*,NSData* _Nullable,bool);
std::shared_ptr<HostedProcessor> makeVST3(NSString*,NSData* _Nullable,bool);
}

NS_ASSUME_NONNULL_END
