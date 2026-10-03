#import "PluginHost.hpp"
#import <objc/runtime.h>
#include <map>
#include <set>
#include <algorithm>

namespace {
char EditorLifetimeKey;
struct Record {
    std::shared_ptr<desk::HostedProcessor> processor;
    NSString* component=nil;
    NSString* format=nil;
    NSData* state=nil;
    NSString* context=nil;
    NSData* snapshot=nil;
};
}

@implementation MDPluginEditor {
    std::shared_ptr<desk::HostedProcessor> _processor;
}
- (instancetype)initWithProcessor:(std::shared_ptr<desk::HostedProcessor>)processor {if((self=[super init]))_processor=std::move(processor);return self;}
- (NSString*)name {return _processor->name;}
- (NSView*)makeView {
    NSAssert(NSThread.isMainThread,@"Plugin editors must be opened on the main thread");
    NSView* view=_processor->makeView();
    if(view){
        // Subviews can outlive their parent while AppKit drains tracking
        // and animation callbacks after window close.
        // Keep the processor alive through their teardown, as for AU views.
        NSMutableArray<NSView*>* pending=[NSMutableArray arrayWithObject:view];
        while(pending.count){NSView* child=pending.lastObject;[pending removeLastObject];
            objc_setAssociatedObject(child,&EditorLifetimeKey,self,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [pending addObjectsFromArray:child.subviews];
        }
    }
    return view;
}
@end

@implementation MDPluginRack {
    std::map<std::string,Record> _records;
    std::vector<std::pair<uint64_t,std::shared_ptr<desk::HostedProcessor>>> _retired;
}
 + (NSArray*)catalog {
    NSMutableArray* result=[desk::audioUnitCatalog() mutableCopy];
    [result addObjectsFromArray:desk::vst3Catalog()];
    return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b){return [[a[@"manufacturer"] stringByAppendingString:a[@"name"]] localizedCaseInsensitiveCompare:[b[@"manufacturer"] stringByAppendingString:b[@"name"]]];}];
}
- (void)prepareSession:(NSDictionary*)session retireAfter:(uint64_t)generation {
    std::set<std::string> active;
    for(NSString* kind in @[@"strips",@"buses"])for(NSDictionary* owner in session[kind]) {
        BOOL bus=[kind isEqual:@"buses"],mono=!bus && [owner[@"source"][@"channels"] count]==1;
        BOOL audition=bus && [owner[@"kind"] isEqual:@"monitor"];
        id context=bus ? @{@"excluded":owner[@"excludedStripID"] ?: @"",
            @"monitoring":audition ? (session[@"monitoringMode"] ?: @"") : @"",
            @"sources":[session[@"strips"] valueForKey:@"source"],
            @"solo":audition ? [session[@"strips"] valueForKey:@"solo"] : @[],
            @"roles":audition ? [session[@"strips"] valueForKey:@"role"] : @[]} : owner[@"source"];
        NSString* key=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:context options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding];
        for(NSDictionary* slot in owner[@"inserts"])if([@[@"au",@"vst3"] containsObject:slot[@"format"]]) {
            std::string identifier=[slot[@"id"] UTF8String];active.insert(identifier);
            NSData* state=[slot[@"state"] isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:slot[@"state"] options:0] : nil;
            auto found=_records.find(identifier);
            bool sameState=found!=_records.end() && ((state==nil&&found->second.state==nil)||[state isEqual:found->second.state]||[state isEqual:found->second.snapshot]);
            if(found!=_records.end() && [found->second.component isEqual:slot[@"identifier"]] && [found->second.format isEqual:slot[@"format"]] && [found->second.context isEqual:key] && sameState) {
                found->second.state=state;continue;
            }
            // Rebinding/changed exclusions clear tails but retain edits made in
            // the native editor since the last session snapshot.
            NSData* restore=state;
            if(found!=_records.end() && [found->second.component isEqual:slot[@"identifier"]] && [found->second.format isEqual:slot[@"format"]] && sameState)
                restore=found->second.processor->data() ?: state;
            auto processor=[slot[@"format"] isEqual:@"au"] ? desk::makeAudioUnit(slot[@"identifier"],restore,mono) : desk::makeVST3(slot[@"identifier"],restore,mono);
            if(found!=_records.end())_retired.emplace_back(generation,found->second.processor);
            _records[identifier]={processor,slot[@"identifier"],slot[@"format"],state,key};
        }
    }
    for(auto it=_records.begin();it!=_records.end();)if(!active.contains(it->first)){_retired.emplace_back(generation,it->second.processor);it=_records.erase(it);}else ++it;
}
- (desk::InsertProcessor*)processor:(NSString*)identifier {auto it=_records.find(identifier.UTF8String);return it==_records.end()?nullptr:it->second.processor.get();}
- (void)collectThrough:(uint64_t)generation {std::erase_if(_retired,[&](const auto& r){return r.first<=generation;});}
- (void)resetStopped {for(auto& [id,r]:_records)r.processor->resetStopped();}
- (void)retry:(NSString*)identifier {auto it=_records.find(identifier.UTF8String);if(it!=_records.end())it->second.context=NSUUID.UUID.UUIDString;}
- (NSArray*)status {
    NSMutableArray* result=[NSMutableArray array];
    for(const auto& [id,r]:_records) {
        r.processor->service();auto code=r.processor->renderError();NSString* error=r.processor->failure ?: (code ? [NSString stringWithFormat:@"Render failed (%d); wet output silenced.",code] : @"");
        [result addObject:@{@"id":[NSString stringWithUTF8String:id.c_str()],@"name":r.processor->name,@"latencyFrames":@(r.processor->latencyFrames()),@"error":error,@"monoInput":@(r.processor->monoInput())}];
    }return result;
}
- (NSDictionary*)states {
    NSMutableDictionary* result=[NSMutableDictionary dictionary];
    for(auto& [id,r]:_records)if(NSData* data=r.processor->data()) {r.snapshot=data;result[[NSString stringWithUTF8String:id.c_str()]]=data;}
    return result;
}
- (MDPluginEditor*)editor:(NSString*)identifier {auto it=_records.find(identifier.UTF8String);return it==_records.end()||!it->second.processor->available()?nil:[[MDPluginEditor alloc] initWithProcessor:it->second.processor];}
@end
