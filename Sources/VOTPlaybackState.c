#include "VOTPlaybackState.h"
VOTPlaybackState VOTGetPlaybackState(bool enabled, bool hasAudio, bool itemReady, int timeControl, bool nativePaused, bool seeking, bool wantsPlay) {
    if (!enabled) return VOTPlaybackOff;
    if (!hasAudio) return VOTPlaybackRequesting;
    if (!itemReady) return VOTPlaybackLoading;
    if (nativePaused) return VOTPlaybackPaused;
    if (seeking) return VOTPlaybackPreparing;
    if (timeControl == 2 && wantsPlay) return VOTPlaybackPlaying;
    if (timeControl == 1 || wantsPlay) return VOTPlaybackBuffering;
    return VOTPlaybackPreparing;
}
