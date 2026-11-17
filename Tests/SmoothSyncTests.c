#include "../Sources/VOTSync.h"
#include <assert.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>

static bool (*motion)(VOTMotionState *,double,double,float);
static double (*project)(const VOTMotionState *,double,float);
static VOTSyncDecision (*syncAudio)(VOTSyncState *,double,double,float,bool,bool,double,bool);

static void ContinuousPlayback(double cadence, float speed) {
    VOTMotionState clock = {0}; VOTSyncState sync = {0};
    double audio = 0, actualRate = 0, finishAt = 0, seekTarget = 0;
    bool pending = false, resumeAfterSeek = false;
    unsigned seeks = 0, interruptions = 0;
    double largestDrift = 0;
    for (unsigned tick = 0; tick < 800; tick++) {
        double now = tick*0.15;
        if (pending && now >= finishAt) {
            audio = seekTarget + (resumeAfterSeek ? (now-finishAt)*speed : 0);
            actualRate = resumeAfterSeek ? speed : 0; pending = false;
        } else if (!pending) audio += tick ? actualRate*0.15 : 0;
        double snapshot = 10+floor((now+1e-8)/cadence)*cadence*speed;
        bool moving = motion(&clock,snapshot,now,speed);
        double master = project(&clock,now,speed);
        VOTSyncDecision d = syncAudio(&sync,master,audio,speed,moving,true,now,clock.discontinuity);
        if (now > 3 && !d.play) interruptions++;
        if (!pending && d.seek) {
            seeks++; pending = true; finishAt = now+0.12;
            seekTarget = d.time; resumeAfterSeek = d.play; actualRate = 0;
        } else if (!pending) actualRate = d.play ? d.rate : 0;
        if (now > 4) largestDrift = fmax(largestDrift,fabs(master-audio)/speed);
    }
    printf("cadence %.2fs speed %.0fx: seeks=%u interruptions=%u maxDrift=%.3fs\n",cadence,speed,seeks,interruptions,largestDrift);
    assert(seeks <= 2); assert(interruptions == 0); assert(largestDrift < 0.5);
}
int main(void) {
    motion = dlsym(RTLD_DEFAULT,"VOTTrackMotion");
    project = dlsym(RTLD_DEFAULT,"VOTProjectedTime");
    syncAudio = dlsym(RTLD_DEFAULT,"VOTDecideSmoothSync");
    if (!motion || !project || !syncAudio) { puts("FAIL: continuous sync avoids restarting speech for small drift"); return 1; }
    for (unsigned i = 0; i < 3; i++) for (unsigned j = 0; j < 3; j++) ContinuousPlayback((double[]){0.25,0.5,1}[i], (float[]){1,2,4}[j]);
    VOTSyncState s = {0};
    VOTSyncDecision d = syncAudio(&s,10,10,1,true,true,0,false); assert(!d.seek);
    d = syncAudio(&s,10.6,10,1,true,true,0.15,false); assert(d.play && !d.seek && d.rate > 1 && d.rate <= 1.031);
    d = syncAudio(&s,10,10.6,1,true,true,0.3,false); assert(!d.seek && d.rate < 1 && d.rate >= 0.969);
    d = syncAudio(&s,15,10,1,true,true,0.45,false); assert(!d.seek);
    d = syncAudio(&s,10,10,1,true,true,0.6,false); assert(!d.seek);
    d = syncAudio(&s,40,10,1,true,true,0.75,true); assert(d.seek && d.time == 40);
    d = syncAudio(&s,40.15,10,1,true,true,0.9,false); assert(!d.seek);
    d = syncAudio(&s,40.3,10,1,true,true,1.05,false); assert(!d.seek);
    d = syncAudio(&s,40,40,1,false,true,1.2,false); assert(!d.play && !d.seek);
    d = syncAudio(&s,NAN,40,1,true,true,1.3,false); assert(!d.play && !d.seek);
    VOTMotionState clock = {0};
    assert(!motion(&clock,0,0,1)); assert(motion(&clock,1,1,1));
    assert(motion(&clock,1,1.8,1)); assert(fabs(project(&clock,1.8,1)-1.8) < 1e-8);
    assert(!motion(&clock,1,4,1));
    clock = (VOTMotionState){0};
    assert(!motion(&clock,5,0,1));
    assert(!motion(&clock,40,0.15,1) && clock.discontinuity);
    assert(!motion(&clock,40,0.3,1));
    VOTSyncState capped = {0};
    syncAudio(&capped,10,10,4,true,true,0,false);
    d = syncAudio(&capped,12,10,4,true,true,0.15,false); assert(!d.seek);
    d = syncAudio(&capped,16,14,4,true,true,1.2,false); assert(d.seek);
    puts("Smooth synchronization tests passed"); return 0;
}
