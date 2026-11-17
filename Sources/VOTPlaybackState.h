#pragma once
#include <stdbool.h>
typedef enum {
    VOTPlaybackOff,
    VOTPlaybackRequesting,
    VOTPlaybackLoading,
    VOTPlaybackBuffering,
    VOTPlaybackPreparing,
    VOTPlaybackPaused,
    VOTPlaybackPlaying
} VOTPlaybackState;
VOTPlaybackState VOTGetPlaybackState(bool enabled, bool hasAudio, bool itemReady, int timeControl, bool nativePaused, bool seeking, bool wantsPlay);
