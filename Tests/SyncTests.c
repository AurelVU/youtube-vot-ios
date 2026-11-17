#include <assert.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdbool.h>
#include "../Sources/VOTSync.h"
int main(void) {
    VOTSyncDecision (*decide)(double,double,float,bool,bool) = dlsym(RTLD_DEFAULT,"VOTDecideSync");
    if (!decide) { puts("FAIL: audio synchronization policy is available"); return 1; }
    VOTSyncDecision d = decide(20, 20.1, 1.5, true, true);
    assert(d.play && !d.seek && d.rate == 1.5f);
    d = decide(80, 20, 1, true, true); assert(d.seek && d.play && d.time == 80);
    d = decide(20, 20, 1, false, true); assert(!d.play);
    d = decide(20, 20, 1, true, false); assert(!d.play);
    d = decide(NAN, 20, 1, true, true); assert(!d.play && !d.seek);
    d = decide(20, 20, NAN, true, true); assert(!d.play);
    d = decide(-1, 20, 1, true, true); assert(!d.play);
    d = decide(20, NAN, 1, true, true); assert(d.play && d.seek);
    d = decide(20, 20.2, 2, true, true); assert(d.play && !d.seek && d.rate == 2);
    d = decide(20.45, 20, 3, true, true); assert(d.play && !d.seek && d.rate == 3);
    d = decide(20.6, 20, 4, true, true); assert(d.play && !d.seek && d.rate == 4);
    d = decide(20, 20, 0, true, true); assert(!d.play);
    bool (*motion)(VOTMotionState *,double,double,float) = dlsym(RTLD_DEFAULT,"VOTTrackMotion");
    if (!motion) { puts("FAIL: sparse native playback updates do not interrupt audio"); return 1; }
    VOTMotionState state = {0};
    assert(!motion(&state,0,10,1));
    assert(motion(&state,0.15,10.15,1));
    assert(motion(&state,0.15,10.30,1));
    assert(motion(&state,0.45,10.45,1));
    assert(motion(&state,0.45,10.6,1));
    assert(!motion(&state,0.45,11.2,1));
    assert(motion(&state,0.6,11.35,1));
    state = (VOTMotionState){0};
    assert(!motion(&state,0.6,11.5,1));
    assert(!motion(&state,0.6,11.65,1));
    assert(motion(&state,0.75,11.8,1));
    assert(!motion(&state,60,12,1) && state.discontinuity);
    assert(motion(&state,60.15,12.15,1));
    puts("Sync tests passed"); return 0;
}
