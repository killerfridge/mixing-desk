class SquareProcessor final: public InsertProcessor {
    bool bypass=false;
public:
    bool noise=false;
    void prepare(double,uint32_t,uint32_t)override{}
    void reset()noexcept override{}
    void process(float* const* audio,uint32_t channels,uint32_t frames)noexcept override {if(!bypass)for(uint32_t c=0;c<channels;++c)for(uint32_t f=0;f<frames;++f)audio[c][f]=noise?1:audio[c][f]*audio[c][f];}
    void setBypassed(bool b)noexcept override{bypass=b;}
    uint32_t latencyFrames()const noexcept override{return 0;}
    std::vector<uint8_t> saveState()const override{return {};}
    void restoreState(const std::vector<uint8_t>&)override{}
};
void testHostedInserts() {
    SquareProcessor plugin;
    {Rig r;r.fill(0,.2);r.config.strips[0].inserts[0].identity=99;r.config.strips[0].inserts[0].external=&plugin;r.config.strips[0].insertCount=1;r.publish();r.render();close(r.output[0][N-1],.04*std::sqrt(.5f));
     auto generation=r.engine.publishedGeneration();assert(r.engine.completedGeneration()==generation);
     r.config.strips[0].inserts[0].bypassed=true;r.publish();assert(r.engine.completedGeneration()<r.engine.publishedGeneration());r.render();close(r.output[0][N-1],.2*std::sqrt(.5f));}
    {Rig r;r.fill(0,.2);r.fill(1,.3);auto& bus=r.config.buses[1];bus.insertCount=1;bus.inserts[0].identity=98;bus.inserts[0].external=&plugin;bus.gain=.5;
     r.publish();r.render();close(r.output[2][N-1],.25*.5*.5); // Square of the whole sum, followed by master.
     bus.excludedSource=r.config.strips[1].sourceIdentity;r.config.buses[2].sendCount=1;r.config.buses[2].sends[0]={1,1,false};r.publish();r.render();close(r.output[2][N-1],.16*.5*.5); // Indirect return excluded before nonlinear processing.
     bus.sendCount=1;bus.sends[0]={0,1,false};std::string error;assert(!r.engine.publish(r.config,error));}
    {Rig r;r.fill(0,.2);r.fill(1,.3);auto& bus=r.config.buses[0];bus.insertCount=1;bus.inserts[0].identity=97;bus.inserts[0].external=&plugin;r.config.strips[0].solo=true;r.publish();r.render();close(r.output[0][N-1],.04*.5);bus.mute=true;r.publish();r.render();close(r.output[0][N-1],0);}
    {Engine engine;Configuration config;std::string error;assert(engine.publish(config,error));assert(engine.completedGeneration()==0);engine.activateStopped();assert(engine.completedGeneration()==engine.publishedGeneration());}
    {Rig r;plugin.noise=true;r.config.strips[0].left=-1;r.config.strips[0].insertCount=1;r.config.strips[0].inserts[0].identity=91;r.config.strips[0].inserts[0].external=&plugin;r.publish();r.render();close(r.output[0][N-1],0);plugin.noise=false;}
    std::cout<<"PASS: hosted channel inserts, nonlinear bus summing, bus master/mute, transitive mix-minus, audition, unsafe bus-route rejection and render lifetime acknowledgement.\n";
}
