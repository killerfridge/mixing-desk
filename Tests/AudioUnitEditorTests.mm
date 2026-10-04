#import "../Sources/DeskAudio/PluginHost.hpp"
#import <AppKit/AppKit.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <functional>
#include <thread>
#include <unistd.h>

// Opt-in integration test: runs the installed AU in a disposable native window.
// Invoke controls through their in-process accessibility actions, not global
// mouse/keyboard events. The user's desk and audio devices are never opened.
static void require(bool ok,const char* message){if(!ok){fprintf(stderr,"FAIL: %s\n",message);_exit(1);}}
static NSArray* children(id object){return [object respondsToSelector:@selector(accessibilityChildren)]?([object accessibilityChildren] ?: @[]):@[];}
static NSString* role(id object){return [object respondsToSelector:@selector(accessibilityRole)]?[object accessibilityRole]:@"";}
static NSString* title(id object){return [object respondsToSelector:@selector(accessibilityTitle)]?([object accessibilityTitle] ?: @""):@"";}
static NSString* value(id object){return [object respondsToSelector:@selector(accessibilityValue)]?([[object accessibilityValue] description] ?: @""):@"";}
static void collect(id object,NSString* target,NSMutableArray* found){if([role(object) isEqual:target])[found addObject:object];for(id child in children(object))collect(child,target,found);}
static NSArray* withRole(id root,NSString* target){NSMutableArray* found=[NSMutableArray array];collect(root,target,found);return found;}
static void later(std::function<void()> action){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.25*NSEC_PER_SEC),dispatch_get_main_queue(),^{action();});}
static void press(id control){require(control&&[(id<NSAccessibility>)control accessibilityPerformPress],"Control rejected its press action");}
static NSArray* menuItems(){NSMutableArray* items=[NSMutableArray array];for(NSWindow* window in NSApp.windows)if(window.visible)collect(window.contentView,NSAccessibilityMenuItemRole,items);return items;}

struct Checks {
    dispatch_queue_t control=dispatch_queue_create("test.au.editor.control",DISPATCH_QUEUE_SERIAL);
    MDPluginRack* rack=nil;
    MDPluginEditor* editor=nil;
    NSView* view=nil;
    NSWindow* window=nil;
    NSMutableDictionary* session;
    NSData* initial=nil;
    NSData* saved=nil;
    NSString* quality=nil;
    NSMutableArray<NSString*>* selectedControls=[NSMutableArray array];
    CGFloat scaledWidth=0;
    std::atomic<bool>& finished;
    Checks(NSString* identifier,std::atomic<bool>& done):finished(done){
        session=[@{@"monitoringMode":@"mixer",@"strips":@[@{@"source":@{@"kind":@"device",@"deviceUID":@"test",@"channels":@[@0]},@"solo":@NO,@"inserts":@[@{@"id":@"editor-test",@"format":@"au",@"identifier":identifier}]}],@"buses":@[]} mutableCopy];
    }
    void onControl(std::function<void()> work,std::function<void()> next){dispatch_async(control,^{@autoreleasepool{work();}dispatch_async(dispatch_get_main_queue(),^{next();});});}
    void load(){onControl([this]{
        rack=[MDPluginRack new];[rack prepareSession:session retireAfter:1];
        NSString* error=[rack status].firstObject[@"error"];
        if(error.length){fprintf(stderr,"LOAD: %s\n",error.UTF8String);require(false,"Audio Unit load failed");}
        initial=[rack states][@"editor-test"];editor=[rack editor:@"editor-test"];
    },[this]{open();later([this]{preset();});});}
    void open(){
        view=[editor makeView];require(view,"Missing native editor");
        window=[[NSWindow alloc] initWithContentRect:NSMakeRect(80,120,view.frame.size.width,view.frame.size.height) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed=NO;window.title=@"Mixing Desk · AU editor regression";
        auto scroll=[NSScrollView new];scroll.hasVerticalScroller=YES;scroll.hasHorizontalScroller=YES;scroll.autohidesScrollers=YES;scroll.documentView=view;window.contentView=scroll;
        [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    }
    void close(){[window close];window.contentView=nil;window=nil;view=nil;editor=nil;}
    void choose(id combo,std::function<void(NSString*)> next){
        press(combo);later([combo,next]{
            auto items=menuItems();require(items.count>1,"Dropdown did not expose its choices");
            NSString* chosen=title(items[1]);press(items[1]);
            later([combo,chosen,next]{
                require(menuItems().count==0,"Menu failed to dismiss after selection");
                require([value(combo) hasPrefix:chosen],"Dropdown selection did not apply");
                next(chosen);
            });
        });
    }
    void preset(){
        auto combos=withRole(view,NSAccessibilityPopUpButtonRole);require(combos.count>0,"Missing preset dropdown");
        choose(combos[0],[this](NSString* selected){printf("PASS: preset selection %s\n",selected.UTF8String);settings();});
    }
    void settings(){
        id settings=nil;for(id button in withRole(view,NSAccessibilityButtonRole))if([title(button) isEqual:@"SETTINGS"])settings=button;
        require(settings,"Missing Settings button");CGFloat original=view.frame.size.width;press(settings);
        later([this,original]{
            id scale=nil;for(id item in menuItems())if([title(item) isEqual:@"75%"])scale=item;
            require(scale,"Missing scale menu item");press(scale);
            later([this,original]{
                require(menuItems().count==0,"Settings menu failed to dismiss");
                scaledWidth=view.frame.size.width;require(std::abs(scaledWidth-original*.75)<2,"Scale selection did not apply");
                printf("PASS: Settings scale selection\n");
                id expand=nil;for(id button in withRole(view,NSAccessibilityButtonRole))if([title(button) containsString:@"MORE CONTROLS"])expand=button;
                require(expand,"Missing advanced controls button");press(expand);
                later([this]{otherControls(withRole(view,NSAccessibilityPopUpButtonRole),1);});
            });
        });
    }
    void otherControls(NSArray* combos,NSUInteger index){
        if(index+1>=combos.count){qualityMenu();return;}
        choose(combos[index],[this,combos,index](NSString* selected){
            [selectedControls addObject:selected];printf("PASS: control dropdown selection %s\n",selected.UTF8String);
            otherControls(combos,index+1);
        });
    }
    void qualityMenu(){
        auto combos=withRole(view,NSAccessibilityPopUpButtonRole);require(combos.count>1,"Missing quality dropdown");
        choose(combos.lastObject,[this](NSString* selected){quality=selected;later([this]{
            require([value(withRole(view,NSAccessibilityPopUpButtonRole).lastObject) hasPrefix:quality],"Timer reverted the quality selection");
            printf("PASS: quality selection %s\n",quality.UTF8String);
            onControl([this]{saved=[rack states][@"editor-test"];require(saved.length&&![saved isEqual:initial],"Selected settings were not captured");},[this]{restore();});
        });});
    }
    void restore(){
        close();
        onControl([this]{
            [rack prepareSession:@{@"strips":@[],@"buses":@[]} retireAfter:2];[rack collectThrough:2];rack=nil;
            NSMutableDictionary* strip=[session[@"strips"][0] mutableCopy];NSMutableDictionary* slot=[strip[@"inserts"][0] mutableCopy];slot[@"state"]=[saved base64EncodedStringWithOptions:0];strip[@"inserts"]=@[slot];session[@"strips"]=@[strip];
            rack=[MDPluginRack new];[rack prepareSession:session retireAfter:1];require(![[rack status].firstObject[@"error"] length],"Saved settings failed to restore");editor=[rack editor:@"editor-test"];
        },[this]{open();later([this]{
            require(std::abs(view.frame.size.width-scaledWidth)<2,"Saved UI scale did not restore");
            auto combos=withRole(view,NSAccessibilityPopUpButtonRole);
            require(combos.count==selectedControls.count+2,"Restored editor has different controls");
            for(NSUInteger i=0;i<selectedControls.count;++i)require([value(combos[i+1]) hasPrefix:selectedControls[i]],"Saved control selection did not restore");
            require([value(combos.lastObject) hasPrefix:quality],"Saved quality did not restore");
            printf("PASS: editor reopen, saved selections, and control-queue lifecycle\n");close();
            onControl([this]{[rack prepareSession:@{@"strips":@[],@"buses":@[]} retireAfter:2];[rack collectThrough:2];rack=nil;},[this]{finished=true;[NSApp stop:nil];[NSEvent startPeriodicEventsAfterDelay:0 withPeriod:.1];});
        });});
    }
};
int main(int argc,char** argv){@autoreleasepool{
    require(argc==2,"Pass an installed Studio Tools AU identifier");setvbuf(stdout,nullptr,_IONBF,0);
    auto finished=std::make_shared<std::atomic<bool>>(false);
    std::thread([finished]{std::this_thread::sleep_for(std::chrono::seconds(20));if(!finished->load()){fprintf(stderr,"FAIL: AU editor timed out; UI callback may be stuck on the wrong message thread\n");_exit(124);}}).detach();
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
    Checks checks([NSString stringWithUTF8String:argv[1]],*finished);checks.load();[NSApp run];[NSEvent stopPeriodicEvents];
    require(finished->load(),"Editor test did not complete");return 0;
}}
