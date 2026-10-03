#import "../Sources/DeskAudio/AudioUnitHost.hpp"
#include <cassert>
#include <cmath>
#include <cstdio>

static NSMutableDictionary* fixture(NSString* component,bool mono=false) {
    return [@{@"monitoringMode":@"mixer",@"strips":@[@{@"source":@{@"kind":@"device",@"deviceUID":@"test",@"channels":mono?@[@0]:@[@0,@1]},@"solo":@NO,@"inserts":@[@{@"id":@"test-insert",@"format":@"au",@"identifier":component,@"bypassed":@NO}]}],@"buses":@[]} mutableCopy];
}
int main(int argc,char** argv) { @autoreleasepool {
    if(desk::runVST3ScanCommand())return 0;
    if(argc>1 && !strcmp(argv[1],"--list")) {
        for(NSDictionary* plugin in desk::audioUnitCatalog())printf("%s | %s | %s\n",[plugin[@"id"] UTF8String],[plugin[@"manufacturer"] UTF8String],[plugin[@"name"] UTF8String]);
        return 0;
    }
    NSString* identifier=argc>1 ? [NSString stringWithUTF8String:argv[1]] : @"61756678:68706173:6170706c";
    bool apple=[identifier isEqual:@"61756678:68706173:6170706c"];
    bool mono=argc>2&&!strcmp(argv[2],"--mono");
    auto session=fixture(identifier,mono);MDAudioUnitRack* rack=[MDAudioUnitRack new];
    [rack prepareSession:session retireAfter:1];
    NSDictionary* status=[rack status].firstObject;
    if([status[@"error"] length]) {fprintf(stderr,"LOAD FAILED: %s\n",[status[@"error"] UTF8String]);return 2;}
    auto* processor=[rack processor:@"test-insert"];assert(processor);
    if(apple)assert([status[@"monoInput"] boolValue]==mono);
    float left[128]{},right[128]{};float* audio[]={left,right};
    double wetEnergy=0;
    for(int block=0;block<750;++block) {
        for(int f=0;f<128;++f){left[f]=apple ? .1f : .05f*std::sin((block*128+f)*.04);right[f]=0;}
        processor->process(audio,2,128);
        for(int f=0;f<128;++f){assert(std::isfinite(left[f])&&std::isfinite(right[f]));if(block>500)wetEnergy+=left[f]*left[f];}
        if(apple && !mono && block>100)for(float sample:right)assert(sample==0);
        if(apple && mono && block>100)for(int f=0;f<128;++f)assert(left[f]==right[f]);
    }
    status=[rack status].firstObject;
    if([status[@"error"] length]){fprintf(stderr,"RENDER FAILED: %s\n",[status[@"error"] UTF8String]);return 3;}
    if(apple)assert(wetEnergy<1e-8);else if(wetEnergy<1e-9){fprintf(stderr,"No nonzero output; check plugin license.\n");return 4;}
    processor->setBypassed(true);
    for(int block=0;block<4;++block){for(int f=0;f<128;++f){left[f]=.1;right[f]=-.2;}processor->process(audio,2,128);}
    for(int f=0;f<128;++f){assert(std::abs(left[f]-.1f)<1e-6);assert(std::abs(right[f]+.2f)<1e-6);}
    auto state=[rack states][@"test-insert"];assert(state.length>0);
    // A queued mixer edit can still carry the previous serialized state while
    // the UI is receiving a new snapshot. It must not recreate/reset the unit.
    [rack prepareSession:session retireAfter:2];assert([rack processor:@"test-insert"]==processor);
    NSMutableDictionary* owner=[session[@"strips"][0] mutableCopy];NSMutableDictionary* slot=[owner[@"inserts"][0] mutableCopy];slot[@"state"]=[state base64EncodedStringWithOptions:0];owner[@"inserts"]=@[slot];session[@"strips"]=@[owner];
    [rack prepareSession:session retireAfter:2];assert([rack processor:@"test-insert"]==processor);
    MDAudioUnitRack* restored=[MDAudioUnitRack new];[restored prepareSession:session retireAfter:1];
    assert(![[restored status].firstObject[@"error"] length]);
    auto* loaded=[restored processor:@"test-insert"];assert(loaded);
    for(int block=0;block<10;++block){for(int f=0;f<128;++f){left[f]=.05f*std::sin(f*.04);right[f]=0;}loaded->process(audio,2,128);for(float sample:left)assert(std::isfinite(sample));}
    assert(![[restored status].firstObject[@"error"] length]);
    assert([restored states][@"test-insert"].length>0);
    [restored resetStopped];
    // Missing units retain an insert and produce silence; explicit bypass is dry.
    auto missing=fixture(@"61756678:7a7a7a7a:7a7a7a7a");[restored prepareSession:missing retireAfter:2];
    loaded=[restored processor:@"test-insert"];assert(loaded);assert([[restored status].firstObject[@"error"] length]);
    for(int f=0;f<128;++f){left[f]=.1;right[f]=.2;}loaded->process(audio,2,128);for(float v:left)assert(v==0);
    loaded->setBypassed(true);for(int b=0;b<3;++b){for(int f=0;f<128;++f){left[f]=.1;right[f]=.2;}loaded->process(audio,2,128);}assert(std::abs(left[127]-.1)<1e-6);
    [restored collectThrough:2];
    if(apple) {
        // Solo must not reset a call/stream plugin's delay or reverb history.
        auto audition=fixture(identifier);
        NSMutableDictionary* strip=[audition[@"strips"][0] mutableCopy];strip[@"inserts"]=@[];
        audition[@"strips"]=@[strip];
        audition[@"buses"]=@[
            @{@"kind":@"monitor",@"inserts":@[@{@"id":@"monitor-au",@"format":@"au",@"identifier":identifier}]},
            @{@"kind":@"call",@"inserts":@[@{@"id":@"call-au",@"format":@"au",@"identifier":identifier}]}];
        MDAudioUnitRack* busRack=[MDAudioUnitRack new];[busRack prepareSession:audition retireAfter:1];
        auto* monitor=[busRack processor:@"monitor-au"];auto* call=[busRack processor:@"call-au"];
        strip[@"solo"]=@YES;[busRack prepareSession:audition retireAfter:2];
        assert([busRack processor:@"monitor-au"]!=monitor);
        assert([busRack processor:@"call-au"]==call);
        [busRack collectThrough:2];
    }
    printf("PASS: %s (%s source): 48 kHz/128-frame rendering, finite nonzero/filter output, bypass, state restore, missing-plugin silence; reported latency %u frames.\n",[status[@"name"] UTF8String],mono?"mono":"stereo",processor->latencyFrames());
    return 0;
} }
