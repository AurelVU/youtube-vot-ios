#pragma once
#include <stdbool.h>
typedef struct { bool play; bool seek; double time; float rate; } VOTSyncDecision;
VOTSyncDecision VOTDecideSync(double videoTime, double audioTime, float rate, bool moving, bool allowed);
typedef struct {
    double lastTime, lastSample, lastProgress;
    bool initialized;
    double anchorTime, anchorHost, cadence;
    bool discontinuity;
} VOTMotionState;
bool VOTTrackMotion(VOTMotionState *state, double videoTime, double now, float rate);
double VOTProjectedTime(const VOTMotionState *state, double now, float rate);
typedef struct {
    bool initialized, wasMoving;
    double lastSeekAt, largeDriftSince;
} VOTSyncState;
VOTSyncDecision VOTDecideSmoothSync(VOTSyncState *state, double videoTime, double audioTime, float rate, bool moving, bool allowed, double now, bool force);
