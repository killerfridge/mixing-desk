#import "../Sources/DeskAudio/PluginHost.hpp"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <thread>
#include <atomic>

static NSMutableDictionary* fixture(NSString* id,bool mono=false) {
    return [@{@"monitoringMode":@"mixer",@"strips":@[@{@"source":@{@"kind":@"device",@"deviceUID":@"test",@"channels":mono?@[@0]:@[@0,@1]},@"solo":@NO,@"inserts":@[@{@"id":@"test",@"format":@"vst3",@"identifier":id,@"bypassed":@NO}]}],@"buses":@[]} mutableCopy];
}
static void setState(NSMutableDictionary* session,NSData* state){NSMutableDictionary* strip=[session[@"strips"][0] mutableCopy];NSMutableDictionary* slot=[strip[@"inserts"][0] mutableCopy];slot[@"state"]=[state base64EncodedStringWithOptions:0];strip[@"inserts"]=@[slot];session[@"strips"]=@[strip];}
static void healthy(MDPluginRack* rack){NSString* error=[rack status].firstObject[@"error"];if(error.length){fprintf(stderr,"Plugin error: %s\n",error.UTF8String);abort();}}
static float render(desk::InsertProcessor* p,int frames=128){float l[4096],r[4096];float* buffers[]={l,r};for(int i=0;i<frames;++i){l[i]=.2f;r[i]=-.4f;}p->process(buffers,2,frames);for(int i=0;i<frames;++i){assert(std::isfinite(l[i])&&std::isfinite(r[i]));}return l[frames-1];}
static NSSlider* slider(NSView* view,NSInteger id){for(NSView* child in view.subviews)if([child isKindOfClass:NSSlider.class]&&child.tag==id)return (NSSlider*)child;return nil;}
static void change(NSView* view,NSInteger id,double value){auto control=slider(view,id);assert(control);control.doubleValue=value;[control sendAction:control.action to:control.target];}
static int runChecks(int argc,char** argv){@autoreleasepool{
    if(desk::runVST3ScanCommand())return 0;
    [NSApplication sharedApplication];
    if(argc>1&&!strcmp(argv[1],"--list")){for(NSDictionary* item in desk::vst3Catalog())printf("%s | %s | %s\n",[item[@"id"] UTF8String],[item[@"manufacturer"] UTF8String],[item[@"name"] UTF8String]);return 0;}
    bool test=argc==1;NSString* id=test?@"102030405060708090A0B0C0D0E0F001":[NSString stringWithUTF8String:argv[1]];
    if(test){auto catalog=desk::vst3Catalog();assert(catalog.count==2);for(NSDictionary* item in catalog)assert([item[@"format"] isEqual:@"vst3"]);}
    auto session=fixture(id);MDPluginRack* rack=[MDPluginRack new];[rack prepareSession:session retireAfter:1];healthy(rack);
    auto p=[rack processor:@"test"];assert(p);double energy=0;
    for(int i=0;i<750;++i){float value=render(p);energy+=value*value;}
    healthy(rack);assert(energy>1e-9);if(test){assert(std::abs(render(p)-.1f)<1e-6);assert(p->latencyFrames()==7);}
    p->setBypassed(true);for(int i=0;i<4;++i)render(p);assert(std::abs(render(p)-.2f)<1e-6);p->setBypassed(false);
    for(int frames:{32,64,128,512,1024,4096})render(p,frames);healthy(rack);
    if(!test)fprintf(stderr,"CHECK: audio rendering and bypass passed; opening editor.\n");
    bool withEditor=argc<3||strcmp(argv[2],"--no-editor");
    MDPluginEditor* editor=withEditor?[rack editor:@"test"]:nil;
    NSView* view=withEditor?[editor makeView]:nil;
    NSWindow* window=nil;
    if(withEditor){assert(view);window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,640,480) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];window.releasedWhenClosed=NO;window.contentView=view;if(!test)fprintf(stderr,"CHECK: editor attached; pumping events.\n");[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];}
    if(test){
        change(view,0,.25);for(int i=0;i<4;++i)render(p);assert(std::abs(render(p)-.05f)<1e-6);
        change(view,1,1);healthy(rack);assert(p->latencyFrames()==19);
        change(view,0,.375); // Save before the next render: pending UI changes persist.
    }
    if(!test)fprintf(stderr,"CHECK: editor events passed; capturing state.\n");
    NSData* state=[rack states][@"test"];assert(state.length>0);
    [rack prepareSession:session retireAfter:2];assert([rack processor:@"test"]==p);
    setState(session,state);[rack prepareSession:session retireAfter:2];assert([rack processor:@"test"]==p);
    MDPluginRack* restored=[MDPluginRack new];[restored prepareSession:session retireAfter:1];healthy(restored);
    auto loaded=[restored processor:@"test"];for(int i=0;i<8;++i)render(loaded);healthy(restored);
    if(test)assert(std::abs(render(loaded)-.075f)<1e-6);
    [restored resetStopped];healthy(restored);if(!test)fprintf(stderr,"CHECK: state restore passed.\n");
    if(test){
        // State snapshots can run concurrently with IO processing.
        std::atomic<bool> running{true};std::thread io([&]{while(running)render(loaded);});
        for(int i=0;i<40;++i){assert([restored states][@"test"].length>0);healthy(restored);}
        running=false;io.join();
        auto mono=fixture(@"102030405060708090A0B0C0D0E0F002",true);MDPluginRack* monoRack=[MDPluginRack new];[monoRack prepareSession:mono retireAfter:1];healthy(monoRack);auto monoP=[monoRack processor:@"test"];for(int i=0;i<4;++i)render(monoP);assert(std::abs(render(monoP)-.1f)<1e-6);assert([[monoRack status].firstObject[@"monoInput"] boolValue]);
        MDPluginRack* stereoRack=[MDPluginRack new];[stereoRack prepareSession:fixture(@"102030405060708090A0B0C0D0E0F002") retireAfter:1];assert([[stereoRack status].firstObject[@"error"] length]);
        auto invalid=fixture(id);setState(invalid,[NSData dataWithBytes:"bad" length:3]);MDPluginRack* bad=[MDPluginRack new];[bad prepareSession:invalid retireAfter:1];assert([[bad status].firstObject[@"error"] length]);assert(render([bad processor:@"test"])==0);
    }
    [restored prepareSession:fixture(@"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF") retireAfter:2];loaded=[restored processor:@"test"];assert([[restored status].firstObject[@"error"] length]);assert(render(loaded)==0);loaded->setBypassed(true);for(int i=0;i<4;++i)render(loaded);assert(std::abs(render(loaded)-.2f)<1e-6);[restored collectThrough:2];
    // Removing an insert cannot free its processor while an editor still owns it.
    [rack prepareSession:@{@"strips":@[],@"buses":@[]} retireAfter:3];[rack collectThrough:3];
    if(test)change(view,0,.5);
    if(!test)fprintf(stderr,"CHECK: closing editor and removing instance.\n");
    [window close];window.contentView=nil;window=nil;view=nil;editor=nil;
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    if(test){
        // Match the app: rack work comes from a serial control queue while
        // all VST3 lifecycle/editor operations must enter the main thread.
        auto done=std::make_shared<std::atomic<bool>>(false);
        dispatch_async(dispatch_queue_create("test.plugin.control",DISPATCH_QUEUE_SERIAL),^{
            @autoreleasepool {
                MDPluginRack* queued=[MDPluginRack new];[queued prepareSession:fixture(id) retireAfter:1];healthy(queued);
                assert([queued states][@"test"].length>0);[queued resetStopped];
                [queued prepareSession:@{@"strips":@[],@"buses":@[]} retireAfter:2];[queued collectThrough:2];
            }
            done->store(true);
        });
        NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
        while(!done->load()&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        assert(done->load());
    }
    printf("PASS: VST3 %s: discovery, rendering at 32–4096 frames, bypass, parameter editor, state, missing-plugin silence and editor lifetime%s.\n",id.UTF8String,test?", parameter transfer, pending edits, latency changes, mono negotiation, instrument filtering and concurrent snapshots":"");
    fflush(stdout);return 0;
}}

int main(int argc,char** argv){
    int result;
    @autoreleasepool {result=runChecks(argc,argv);}
    // Match the app's quit path: all racks/editors have been released before
    // the main queue drains final plugin-interface retirement callbacks.
    @autoreleasepool {[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];}
    return result;
}
