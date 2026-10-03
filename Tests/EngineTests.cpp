#include "../Sources/DeskAudio/Engine.hpp"
#include "../Driver/TimestampRing.hpp"
#include <cassert>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <thread>
#include <chrono>
#include <atomic>
#include <vector>

using namespace desk;
thread_local bool rendering=false;
std::atomic<size_t> allocations{0};
void* operator new(std::size_t size) { if(rendering)++allocations;if(void* p=std::malloc(size))return p;throw std::bad_alloc(); }
void* operator new[](std::size_t size) {return ::operator new(size);}
void operator delete(void* p) noexcept {std::free(p);}
void operator delete[](void* p) noexcept {std::free(p);}
constexpr int N=128;
struct Rig {
    // Keep large fixture configurations off the small macOS test stack,
    // particularly under ASan where every lexical fixture gets red zones.
    std::unique_ptr<Engine> engineStorage=std::make_unique<Engine>();
    std::unique_ptr<Configuration> configStorage=std::make_unique<Configuration>();
    Engine& engine=*engineStorage;Configuration& config=*configStorage;
    float input[4][N]{},output[8][N]{};
    const float* in[4]={input[0],input[1],input[2],input[3]};
    float* out[8]={output[0],output[1],output[2],output[3],output[4],output[5],output[6],output[7]};
    Rig() {
        config.stripCount=2;config.busCount=3;config.routeCount=3;
        for(int i=0;i<2;++i){auto& s=config.strips[i];s.identity=i+1;s.sourceIdentity=i+11;s.left=i;s.mono=true;s.sendCount=3;for(int b=0;b<3;++b)s.sends[b]={b,1,false};}
        for(int b=0;b<3;++b){config.buses[b].identity=b+21;config.routes[b]={true,false,b,b*2,b*2+1,1};}
        config.buses[0].monitor=true;
    }
    void publish() {std::string error;assert(engine.publish(config,error));}
    void render(int blocks=4) {for(int k=0;k<blocks;++k){rendering=true;engine.render(in,4,out,8,N);rendering=false;}}
    void fill(int channel,float value){std::fill_n(input[channel],N,value);}
};
void close(float actual,float expected,float tolerance=1e-4) {if(std::abs(actual-expected)>tolerance){std::cerr<<"Expected "<<expected<<", got "<<actual<<"\n";std::abort();}}
#include "EQChecks.hpp"
#include "HostedInsertChecks.hpp"
int main(int argc,char** argv) {
    testEqualizer();
    testHostedInserts();
    const float center=std::sqrt(.5f);
    {Rig r;r.fill(0,.2);r.publish();r.render();close(r.output[0][N-1],.2*center);close(r.output[1][N-1],.2*center);r.config.strips[0].pan=-1;r.publish();r.render();close(r.output[0][N-1],.2);close(r.output[1][N-1],0);}
    {Rig r;r.config.strips[0].mono=false;r.config.strips[0].right=1;r.config.strips[1].mute=true;r.fill(0,.2);r.fill(1,.4);r.publish();r.render();close(r.output[0][N-1],.2);close(r.output[1][N-1],.4);r.config.strips[0].pan=1;r.publish();r.render();close(r.output[0][N-1],0);close(r.output[1][N-1],.4);}
    {Rig r;r.fill(0,.2);r.config.strips[0].fader=.5;r.config.strips[0].sends[0].pre=true;r.publish();r.render();close(r.output[0][N-1],.2*center);close(r.output[2][N-1],.1*center);r.config.strips[0].mute=true;r.publish();r.render();close(r.output[0][N-1],0);close(r.output[2][N-1],0);}
    {Rig r;r.fill(0,.2);r.fill(1,.3);r.config.strips[0].solo=true;r.publish();r.render();close(r.output[0][N-1],.2*center);close(r.output[2][N-1],.5*center);r.config.strips[0].directGuitar=true;r.publish();r.render();close(r.output[0][N-1],0);close(r.output[2][N-1],.5*center);}
    {Rig r;r.fill(0,.2);r.fill(1,.3);r.config.strips[0].solo=true;r.config.buses[0].sends[0]={2,1,false};r.config.buses[0].sendCount=1;r.publish();r.render();close(r.output[4][N-1],1.0*center);}
    {Rig r;r.fill(0,.2);r.fill(1,.3);r.config.buses[1].excludedSource=r.config.strips[1].sourceIdentity;r.config.buses[2].sendCount=1;r.config.buses[2].sends[0]={1,1,false};r.publish();r.render();close(r.output[2][N-1],.4*center);}
    {Rig r;r.config.buses[0].sendCount=1;r.config.buses[0].sends[0]={1,1,false};r.config.buses[1].sendCount=1;r.config.buses[1].sends[0]={0,1,false};std::string error;assert(!r.engine.publish(r.config,error));}
    {Rig r;r.fill(0,.3);r.config.strips[0].trim=2;r.config.strips[0].fader=.5;r.config.strips[0].polarity=true;r.config.routes[0]={false,true,0,0,-1,1};r.config.routes[1]={false,false,0,2,-1,1};r.publish();r.render();close(r.output[0][N-1],-.6);close(r.output[2][N-1],-.3);}
    {Rig r;r.fill(0,.5);r.publish();r.render();float before=r.output[0][N-1];r.config.strips[0].fader=0;r.publish();r.render(1);assert(std::abs(r.output[0][0]-before)<.003);r.render();close(r.output[0][N-1],0);}
    {Rig r;r.fill(0,2);r.publish();r.render();assert(r.engine.stripMeter(0).clip);r.engine.clearClip();assert(!r.engine.stripMeter(0).clip);}
    {Rig r;r.fill(0,.2);r.config.strips[0].left=-1;r.publish();r.render();close(r.output[0][N-1],0);}
    {TimestampRing ring(2);float input[8]={1,2,3,4,5,6,7,8},output[8];ring.read(100,output,4);for(float v:output)close(v,0);ring.write(100,input,4);ring.read(100,output,4);for(int i=0;i<8;++i)close(output[i],input[i]);ring.read(200,output,4);for(float v:output)close(v,0);ring.write(100+16384,input,4);ring.read(100,output,4);for(float v:output)close(v,0);}
    {Rig r;r.fill(0,.2);r.publish();std::thread control([&]{for(int i=0;i<20000;++i){auto c=r.config;c.strips[0].fader=(i%10)/10.f;std::string error;assert(r.engine.publish(c,error));}});for(int i=0;i<20000;++i){r.render(1);for(float sample:r.output[0])assert(std::isfinite(sample));}control.join();}
    assert(allocations.load()==0);
    if(argc>1 && std::string(argv[1])=="--soak") {
        Engine engine;Configuration c;c.stripCount=16;c.busCount=4;c.routeCount=4;
        for(int i=0;i<16;++i){auto& s=c.strips[i];s.identity=i+1;s.sourceIdentity=i+1;s.left=0;s.right=1;s.mono=false;s.sendCount=4;for(int j=0;j<4;++j)s.sends[j]={j,.05f,false};}
        for(int j=0;j<4;++j){c.buses[j].identity=j+1;c.routes[j]={true,false,j,j*2,j*2+1,1};}
        std::string error;assert(engine.publish(c,error));float inData[2][N]{},outData[8][N]{};const float* in[]={inData[0],inData[1]};float* out[8];for(int i=0;i<8;++i)out[i]=outData[i];
        auto start=std::chrono::steady_clock::now();uint64_t frames=0;
        for(int block=0;block<48000*60*60/N;++block){for(int i=0;i<N;++i){inData[0][i]=.1f*std::sin((frames+i)*.01);inData[1][i]=.1f*std::cos((frames+i)*.01);}rendering=true;engine.render(in,2,out,8,N);rendering=false;for(int ch=0;ch<8;++ch)for(float sample:outData[ch])assert(std::isfinite(sample));frames+=N;}
        double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
        std::cout<<"Offline soak: "<<frames<<" frames (60 minutes of audio), "<<elapsed<<" wall seconds. This is not a hardware drift test.\n";
    }
    std::cout<<"PASS: gain, pan/balance, polarity, sends, solo, direct monitoring, transitive mix-minus, cycle rejection, direct outs, smoothing, meters, offline input, ring timing, concurrent publication; zero render allocations.\n";
}
