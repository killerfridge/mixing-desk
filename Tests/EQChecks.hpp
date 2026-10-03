// Included by EngineTests.cpp to share the real-time allocation guard.
double measuredEQ(desk::EQParameters parameters,double frequency) {
    desk::Equalizer eq;eq.prepare(48000,N,2);eq.configure(desk::prepareEQ(parameters),parameters,false);
    double energy=0;int count=0;float left[N],right[N];float* channels[]={left,right};
    for(int block=0;block<1125;++block) { // Two seconds settling, then one measuring.
        for(int f=0;f<N;++f){left[f]=.05f*std::sin(2*M_PI*frequency*(block*N+f)/48000);right[f]=0;}
        rendering=true;eq.process(channels,2,N);rendering=false;
        for(int f=0;f<N;++f){assert(std::isfinite(left[f]));close(right[f],0);if(block>=750){energy+=left[f]*left[f];++count;}}
    }
    return 20*std::log10(std::sqrt(energy/count)/(.05/std::sqrt(2.)));
}
void testEqualizer() {
    using namespace desk;
    EQParameters p;
    close(measuredEQ(p,1000),0,.001);
    p.midGain=12;close(measuredEQ(p,1000),12,.002);
    p.midGain=-18;p.midQ=10;close(measuredEQ(p,1000),-18,.005);
    p={};p.lowGain=12;close(measuredEQ(p,120),6,.01);close(measuredEQ(p,20),12,.03);
    p={};p.highGain=-12;close(measuredEQ(p,8000),-6,.01);
    p.lowGain=6;p.midGain=-7;p.midQ=.7;p.outputGain=-3;
    for(double frequency:{80.,1000.,8000.,18000.})close(measuredEQ(p,frequency),eqResponseDB(prepareEQ(p),frequency),.02);
    // Extreme shelf/bell parameters stay finite, including very narrow LF cuts.
    for(double frequency:{20.,20000.})for(double gain:{-18.,18.}) {
        p={};p.lowFrequency=p.midFrequency=p.highFrequency=frequency;p.midQ=10;p.lowGain=p.midGain=p.highGain=gain;
        close(measuredEQ(p,frequency),eqResponseDB(prepareEQ(p),frequency),.1);
    }
    Equalizer eq;eq.prepare(48000,N,2);p={};p.outputGain=12;eq.configure(prepareEQ(p),p,false);
    float left[N],right[N];float* audio[]={left,right};
    for(int i=0;i<N;++i)left[i]=right[i]=.1;
    rendering=true;eq.process(audio,2,N);rendering=false;
    assert(std::abs(left[0]-.1)<.002); // Parameter change begins with a short crossfade.
    eq.setBypassed(true);
    for(int k=0;k<8;++k){std::fill_n(left,N,.1);std::fill_n(right,N,.2);rendering=true;eq.process(audio,2,N);rendering=false;}
    for(int i=0;i<N;++i){close(left[i],.1);close(right[i],.2);}
    auto saved=eq.saveState();Equalizer restored;restored.restoreState(saved);assert(restored.saveState()==saved);assert(eq.latencyFrames()==0);
    auto bad=saved;bad[0]=42;bool rejected=false;try{restored.restoreState(bad);}catch(const std::invalid_argument&){rejected=true;}assert(rejected);
    // Rapid target changes cannot allocate, destabilize a filter, or lose the last target.
    for(int block=0;block<1000;++block) {
        p={};p.midGain=block%2?18:-18;p.midFrequency=block%2?20:20000;p.midQ=10;
        eq.configure(prepareEQ(p),p,false);
        std::fill_n(left,N,.01);std::fill_n(right,N,0);
        rendering=true;eq.process(audio,2,N);rendering=false;
        for(float sample:left)assert(std::isfinite(sample)&&std::abs(sample)<100);
    }
    {Rig r;r.fill(0,.1);r.config.strips[0].fader=.5;
        auto& strip=r.config.strips[0];strip.insertCount=1;strip.inserts[0].identity=100;strip.inserts[0].parameters.outputGain=20*std::log10(2.);
        r.config.routes[0]={false,true,0,0,-1,1};r.config.routes[1]={false,false,0,2,-1,1};r.publish();r.render(12);
        close(r.output[0][N-1],.2);close(r.output[2][N-1],.1);
        strip.inserts[0].bypassed=true;r.publish();r.render(12);close(r.output[0][N-1],.1);
        strip.inserts[0].bypassed=false;strip.insertCount=2;strip.inserts[1].identity=101;strip.inserts[1].parameters.outputGain=-20*std::log10(2.);r.publish();r.render(12);close(r.output[0][N-1],.1);
        strip.insertCount=0;r.publish();r.render(12);close(r.output[0][N-1],.1);
    }
    {Rig r;r.fill(0,.1);r.fill(1,.3);auto& bus=r.config.buses[2];bus.insertCount=1;bus.inserts[0].identity=200;bus.inserts[0].parameters.outputGain=20*std::log10(2.);
        bus.sendCount=1;bus.sends[0]={1,1,false};r.config.buses[1].excludedSource=r.config.strips[1].sourceIdentity;r.publish();r.render(12);
        close(r.output[4][N-1],.8*std::sqrt(.5));close(r.output[2][N-1],.3*std::sqrt(.5));
        r.config.strips[0].mute=true;r.publish();r.render(12);close(r.output[2][N-1],0);
    }
    {Rig r;for(auto& strip:r.config.strips){strip.sendCount=1;strip.sends[0]={2,1,false};}
        auto& bus=r.config.buses[2];bus.insertCount=1;bus.inserts[0].identity=201;bus.inserts[0].parameters.midGain=18;bus.inserts[0].parameters.midQ=10;bus.sendCount=1;bus.sends[0]={1,1,false};
        r.publish();r.render(12);r.input[0][0]=.2;r.render(1);r.input[0][0]=0;
        r.config.buses[1].excludedSource=r.config.strips[0].sourceIdentity;r.publish();r.render(1);
        bool tail=false;for(int f=0;f<N;++f){close(r.output[2][f],0);tail|=std::abs(r.output[4][f])>1e-6;}assert(tail);
        r.engine.reset();r.render(12);for(float v:r.output[4])close(v,0);
    }
    {Rig r;r.config.strips[0].insertCount=1;r.config.strips[0].inserts[0].identity=1;r.config.strips[0].inserts[0].parameters.midQ=0;std::string error;assert(!r.engine.publish(r.config,error));}
    std::cout<<"PASS: EQ measured frequency response, flat/bypass identity, stereo isolation, parameter smoothing, extreme settings, state round trip, ordered inserts, direct outputs, bus mix-minus and tail exclusion.\n";
}
