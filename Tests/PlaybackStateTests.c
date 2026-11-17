#include "../Sources/VOTPlaybackState.h"
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
int main(void) {
    VOTPlaybackState (*state)(bool,bool,bool,int,bool,bool,bool) = dlsym(RTLD_DEFAULT,"VOTGetPlaybackState");
    if (!state) { puts("FAIL: a received audio URL must not be presented as playing audio"); return 1; }
    assert(state(false,true,true,2,false,false,true) == VOTPlaybackOff);
    assert(state(true,false,false,0,false,false,false) == VOTPlaybackRequesting);
    assert(state(true,true,false,0,false,false,false) == VOTPlaybackLoading);
    assert(state(true,true,true,1,false,false,true) == VOTPlaybackBuffering);
    assert(state(true,true,true,0,false,false,true) == VOTPlaybackBuffering);
    assert(state(true,true,true,0,false,true,true) == VOTPlaybackPreparing);
    assert(state(true,true,true,0,true,false,false) == VOTPlaybackPaused);
    assert(state(true,true,true,2,true,false,false) == VOTPlaybackPaused);
    assert(state(true,true,true,2,false,false,false) == VOTPlaybackPreparing);
    assert(state(true,true,true,2,false,false,true) == VOTPlaybackPlaying);
    puts("Playback state tests passed"); return 0;
}
