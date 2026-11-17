#include "VOTSync.h"
#include <math.h>
#include <string.h>

static bool Valid(double video, float rate) {
    return isfinite(video) && video >= 0 && isfinite(rate) && rate > 0 && rate <= 4;
}
static double MotionGrace(const VOTMotionState *s) {
    return fmin(2.5, fmax(0.75, s->cadence*2.5));
}
VOTSyncDecision VOTDecideSync(double videoTime, double audioTime, float rate, bool moving, bool allowed) {
    VOTSyncDecision d = {false,false,videoTime,rate};
    if (!Valid(videoTime,rate) || !allowed) return d;
    d.play = moving;
    if (!isfinite(audioTime)) { d.seek = true; return d; }
    double error = (videoTime-audioTime)/rate;
    d.seek = fabs(error) > 2.5;
    if (moving && !d.seek && fabs(error) > 0.2) {
        double correction = fmax(-0.03,fmin(0.03,error*0.05));
        d.rate = fminf(4,fmaxf(0.1,rate*(1+correction)));
    }
    return d;
}
bool VOTTrackMotion(VOTMotionState *s, double videoTime, double now, float rate) {
    if (!Valid(videoTime,rate) || !isfinite(now)) { memset(s,0,sizeof(*s)); return false; }
    if (!s->initialized) {
        *s = (VOTMotionState){.lastTime=videoTime,.lastSample=now,.lastProgress=-INFINITY,.initialized=true,
            .anchorTime=videoTime,.anchorHost=now,.cadence=0.25};
        return false;
    }
    s->discontinuity = false;
    double delta = videoTime-s->anchorTime, interval = now-s->anchorHost;
    if (now < s->lastSample) { memset(s,0,sizeof(*s)); return false; }
    if (fabs(delta) > 0.01) {
        s->discontinuity = delta < -0.25 || fabs(delta-interval*rate) > fmax(1.25,rate*0.75);
        if (delta > 0 && interval >= 0.03 && interval <= 2.5 && !s->discontinuity)
            s->cadence = isfinite(s->lastProgress) ? s->cadence*0.8+interval*0.2 : interval;
        s->anchorTime = videoTime; s->anchorHost = now;
        s->lastProgress = s->discontinuity ? -INFINITY : now;
    }
    s->lastTime = videoTime; s->lastSample = now;
    return now-s->lastProgress < MotionGrace(s);
}
double VOTProjectedTime(const VOTMotionState *s, double now, float rate) {
    if (!s->initialized || !Valid(s->lastTime,rate) || !isfinite(now)) return NAN;
    if (now-s->lastProgress >= MotionGrace(s)) return s->lastTime;
    return s->anchorTime+fmax(0,now-s->anchorHost)*rate;
}
VOTSyncDecision VOTDecideSmoothSync(VOTSyncState *s, double videoTime, double audioTime, float rate, bool moving, bool allowed, double now, bool force) {
    VOTSyncDecision d = VOTDecideSync(videoTime,audioTime,rate,moving,allowed);
    if (!Valid(videoTime,rate) || !isfinite(now) || !allowed) return d;
    double drift = isfinite(audioTime) ? fabs(videoTime-audioTime)/rate : INFINITY;
    if (!s->initialized) {
        s->initialized = true; s->lastSeekAt = -INFINITY; s->largeDriftSince = NAN;
        d.seek = force || drift > 0.2;
    } else if (force) d.seek = true;
    else if (!s->wasMoving && moving && drift > 0.35 && now-s->lastSeekAt > 0.25) d.seek = true;
    else {
        d.seek = false;
        bool saturated = rate >= 3.99 && videoTime > audioTime && drift > 0.2;
        if (moving && (drift > 2.5 || saturated)) {
            if (!isfinite(s->largeDriftSince)) s->largeDriftSince = now;
            if (now-s->largeDriftSince >= 0.8 && now-s->lastSeekAt >= 3) d.seek = true;
        } else s->largeDriftSince = NAN;
    }
    if (d.seek) { s->lastSeekAt = now; s->largeDriftSince = NAN; d.rate = rate; }
    s->wasMoving = moving;
    return d;
}
