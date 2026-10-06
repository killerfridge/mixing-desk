// Meaningful signal-path regressions, under the engine's render allocation guard.
void bounded(float value) { assert(std::isfinite(value)); assert(std::abs(value) <= ProtectionCeiling + 2e-6f); }
void testProtection() {
    {
        StereoProtection limiter; limiter.reset(true);
        for(int t=0;t<1200;++t) {
            float input=.3f*std::sin(t*.17f),l=input,r=-input*.5f;
            rendering=true;limiter.process(l,r);rendering=false;
            close(l,t<48?0:.3f*std::sin((t-48)*.17f),1e-7);
            close(r,-l*.5f,1e-7);
        }
    }
    {
        StereoProtection limiter;limiter.reset(true);
        // A sudden impulse schedules attenuation of quiet preceding samples.
        for(int t=0;t<180;++t) {
            float l=t==72?4:.1f,r=l*.25f;
            rendering=true;limiter.process(l,r);rendering=false;
            bounded(l);close(r,l*.25f);
            if(t==80)assert(l<.1f && l>.05f);
            if(t==120)close(l,ProtectionCeiling,2e-6);
        }
        for(int t=0;t<1000;++t) {
            float l=(t%53==0 ? -20.f : 2.f),r=l*.1f;
            rendering=true;limiter.process(l,r);rendering=false;
            bounded(l);bounded(r);
        }
        // The 100 ms release recovers toward unity without overshoot.
        float first=0,last=0;
        for(int t=0;t<48000;++t) {
            float l=.1f,r=.1f;
            rendering=true;limiter.process(l,r);rendering=false;
            bounded(l);if(t==100)first=l;if(t==47999)last=l;
        }
        assert(first<.09f && last>.0999f);
    }
    {
        StereoProtection limiter;limiter.reset(false);
        for(int t=0;t<300;++t) {
            float l=t==0?2:0,r=l;
            rendering=true;limiter.process(l,r);rendering=false;
            close(l,t==48?2:0);close(r,l);
        }
        limiter.reset(true);
        for(int t=0;t<1000;++t){float l=2,r=1;limiter.process(l,r);}
        float previous=ProtectionCeiling;
        limiter.enable(false);
        for(int t=0;t<240;++t) {
            float l=2,r=1;rendering=true;limiter.process(l,r);rendering=false;
            assert(l>=previous-1e-6 && l-previous<.006f);previous=l;close(r,l*.5f);
        }
        close(previous,2);limiter.enable(true);
        for(int t=0;t<240;++t){float l=2,r=1;limiter.process(l,r);assert(previous-l<.006f);previous=l;}
        bounded(previous);
    }
    {
        StereoProtection limiter;
        for(float input:{std::numeric_limits<float>::max(),-std::numeric_limits<float>::max(),std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN()}) {
            for(int t=0;t<200;++t){float l=input,r=-input;rendering=true;limiter.process(l,r);rendering=false;bounded(l);bounded(r);}
        }
    }
    // Exact 96-sample delay, across callbacks, is also retained with both stages bypassed.
    for(bool enabled:{true,false}) {
        Rig r;r.config.stripCount=1;r.config.routeCount=1;r.config.routes[0]={false,false,0,0,-1,1};
        r.config.strips[0].limiterEnabled=enabled;r.config.outputProtectionEnabled=enabled;
        r.publish();r.render();r.input[0][N-1]=.4;r.render(1);
        for(float v:r.output[0])close(v,0);
        r.fill(0,0);r.render(1);
        for(int t=0;t<N;++t)close(r.output[0][t],t==95?.4f:0.f);
    }
    {
        // Boundary impulses remain bounded, including peaks that arrive while
        // the preceding callback still has delayed audio to emit.
        Rig r;r.config.stripCount=1;r.config.routeCount=1;r.config.routes[0]={false,false,0,0,1,1};
        r.config.strips[0].mono=false;r.config.strips[0].right=1;r.publish();r.render();
        for(int block=0;block<12;++block) {
            r.fill(0,.1);r.fill(1,.025);r.input[0][0]=4;r.input[0][127]=-2;r.input[1][0]=1;r.input[1][127]=-.5;
            r.render(1);for(int t=0;t<N;++t){bounded(r.output[0][t]);bounded(r.output[1][t]);close(r.output[1][t],r.output[0][t]*.25f);}
        }
        assert(r.engine.stripMeter(0).reductionDB>10 && !r.engine.stripMeter(0).clip);
    }
    {
        // Summing and route gain can overload even when all strips are safe.
        Rig r;r.fill(0,.8);r.fill(1,.8);r.publish();r.render();
        close(r.output[0][127],ProtectionCeiling,2e-6);
        assert(r.engine.busMeter(0).clip && !r.engine.stripMeter(0).clip);
        r.config.routes[0].gain=4;r.publish();r.render();bounded(r.output[0][127]);
    }
    {
        // Overlapping stereo pairs link all three physical channels. Two mono
        // destinations on the same device remain independently protected.
        Rig r;r.config.stripCount=1;r.config.routeCount=4;
        r.config.strips[0].mono=false;r.config.strips[0].right=1;
        r.config.routes[0]={false,false,0,0,1,4};r.config.routes[1]={false,false,0,1,2,1};
        r.config.routes[2]={false,false,0,3,-1,8};r.config.routes[3]={false,false,0,4,-1,.5};
        for(int c=0;c<8;++c)r.config.outputIdentities[c]=100+c;
        std::string error;assert(r.config.validate(error));assert(r.config.protectionGroupCount==3);
        uint64_t linked=0;
        for(int g=0;g<3;++g)if(r.config.protectionGroups[g].firstChannel==0)linked=r.config.protectionGroups[g].identity;
        assert(linked);r.fill(0,.4);r.fill(1,.1);r.publish();r.render();
        close(r.output[0][127],ProtectionCeiling,2e-6);close(r.output[1][127],ProtectionCeiling*.5f);close(r.output[2][127],ProtectionCeiling*.0625f);
        close(r.output[3][127],ProtectionCeiling,2e-6);close(r.output[4][127],.2);
        auto reading=r.engine.outputMeterForGroup(linked);
        assert(reading.reductionDB>5);bounded(reading.peakL);bounded(reading.peakR);bounded(reading.rmsL);bounded(reading.rmsR);
    }
    {
        // The pre-fader limiter must not follow fader changes. Protected direct
        // and bus sends tap their appropriate independent paths, before pan.
        Rig r;r.config.stripCount=1;r.config.routeCount=4;r.config.outputProtectionEnabled=false;
        auto& s=r.config.strips[0];s.fader=.25;s.mono=false;s.right=1;
        s.sends[0].pre=true;r.config.routes[0]={false,true,0,0,1,1};r.config.routes[1]={false,false,0,2,3,1};
        r.config.routes[2]={true,false,0,4,5,1};r.config.routes[3]={true,false,1,6,7,1};
        r.fill(0,2);r.fill(1,.5);r.publish();r.render();
        close(r.output[0][127],ProtectionCeiling,2e-6);close(r.output[2][127],.5);
        close(r.output[4][127],ProtectionCeiling,2e-6);close(r.output[6][127],.5);
        s.fader=4;r.publish();r.render(8);
        close(r.output[0][127],ProtectionCeiling,2e-6);close(r.output[2][127],ProtectionCeiling,2e-6);
        close(r.output[1][127],ProtectionCeiling*.25f);close(r.output[3][127],ProtectionCeiling*.25f);
    }
    {
        SquareProcessor plugin;Rig r;r.config.stripCount=1;r.fill(0,2);
        auto& s=r.config.strips[0];s.insertCount=1;s.inserts[0].identity=98;s.inserts[0].external=&plugin;
        auto& b=r.config.buses[0];b.insertCount=1;b.inserts[0].identity=99;b.inserts[0].external=&plugin;b.gain=8;
        r.publish();r.render();assert(r.engine.stripMeter(0).reductionDB>12 && r.engine.busMeter(0).clip);
        for(float v:r.output[0])bounded(v);
    }
    {
        // An overloaded return remains excluded transitively; channel limiting
        // cannot couple the desired mic with an excluded source contribution.
        Rig r;r.fill(0,.2);r.fill(1,4);r.config.buses[1].excludedSource=r.config.strips[1].sourceIdentity;
        r.config.buses[2].sendCount=1;r.config.buses[2].sends[0]={1,1,false};r.config.strips[0].solo=true;
        r.publish();r.render();close(r.output[2][127],.4f*std::sqrt(.5f));close(r.output[0][127],.2f*std::sqrt(.5f));
        r.config.strips[0].solo=false;r.config.strips[1].solo=true;r.publish();r.render();close(r.output[2][127],.4f*std::sqrt(.5f));
    }
    {
        // Reassign source, route source, or physical channel identities while a
        // pulse is in the lookahead buffer: no old pulse may emerge on the path.
        for(int change=0;change<3;++change) {
            Rig r;r.config.routeCount=1;r.config.routes[0]={false,false,0,0,-1,1};r.publish();r.render();
            r.input[0][127]=.7;r.render(1);r.fill(0,0);
            if(change==0){r.config.strips[0].sourceIdentity=987;r.config.strips[0].left=2;}
            if(change==1)r.config.routes[0].source=1;
            if(change==2)r.config.outputIdentities[0]=998;
            r.publish();r.render(1);for(float v:r.output[0])close(v,0);
        }
    }
    {
        // A destination keeps its identity when aggregate offsets change, but
        // its delay storage must not play audio buffered at the old offset.
        Rig r;r.config.stripCount=1;r.config.routeCount=1;r.config.routes[0]={false,false,0,0,-1,1};r.config.outputIdentities[0]=991;
        r.publish();r.render();r.input[0][80]=.7;r.render(1);r.fill(0,0);
        r.config.routes[0].left=1;r.config.outputIdentities[0]=0;r.config.outputIdentities[1]=991;r.publish();r.render(1);
        for(float v:r.output[1])close(v,0);
    }
    {
        // Owner-keyed held peaks survive reordering, retain silence, and accept
        // reset requests before an intervening reorder/removal publication.
        Rig r;r.config.strips[0].limiterEnabled=false;r.config.strips[1].limiterEnabled=false;
        r.fill(0,2);r.fill(1,.25);r.publish();r.render();r.fill(0,0);r.fill(1,0);r.render();
        assert(r.engine.stripMeterForOwner(1).heldL==2 && r.engine.stripMeterForOwner(1).clip);
        r.engine.resetMeter(1,false);std::swap(r.config.strips[0],r.config.strips[1]);r.publish();r.render(1);
        assert(r.engine.stripMeterForOwner(1).heldL==0 && !r.engine.stripMeterForOwner(1).clip);
        assert(r.engine.stripMeterForOwner(2).heldL==.25);
        r.engine.resetMeter(1,false);r.config.strips[1].identity=999;r.publish();r.fill(0,.3);r.render(4);
        assert(r.engine.stripMeterForOwner(999).heldL>0);
        r.fill(0,0);r.render();
        auto held=r.engine.stripMeterForOwner(999).heldL;r.engine.reset();assert(r.engine.stripMeterForOwner(999).heldL==held);
        r.engine.resetMeter(999,false);r.engine.serviceMeterResetsStopped();assert(r.engine.stripMeterForOwner(999).heldL==0);
        r.engine.resetAllMeters();r.engine.serviceMeterResetsStopped();r.render(1);
        assert(r.engine.stripMeterForOwner(2).heldL==0 && r.engine.busMeterForOwner(21).heldL==0);
    }
    std::cout<<"PASS: anticipatory limiting, transparency, impulses, stereo linking, release, bypass/delay, finite bounds, block boundaries, summed outputs, overlapping physical groups, independent mono recordings, pre/post paths, plugins/mix-minus/solo, reassignment and stable meter reset.\n";
}
