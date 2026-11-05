#import "../../YTKACE.h"
#include "../../Runtime/MediaPolicy.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"
#import "../Downloads/YTKACEDownloadPlayerController.h"
#import "../SponsorBlock/SponsorHooks.h"
#import "ShortsPlayback.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

BOOL YTKACEManualPiPRequested = NO;
static YTKACEMedia::PlaybackActivity YTKACEPlaybackActivity;
static NSObject *YTKACEPlaybackActivityLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

void YTKACENotifyPlaybackTick(void) {
    @synchronized (YTKACEPlaybackActivityLock()) { YTKACEPlaybackActivity.play(CACurrentMediaTime()); }
}

void YTKACENotifyPlaybackPaused(void) {
    @synchronized (YTKACEPlaybackActivityLock()) { YTKACEPlaybackActivity.pause(CACurrentMediaTime()); }
}

void YTKACENotifyVideoTime(double time) {
    @synchronized (YTKACEPlaybackActivityLock()) { YTKACEPlaybackActivity.observe(time, CACurrentMediaTime()); }
}

static NSString *const YTKACEShortsPiPKey = @"YTKACE.Preference.Shorts.PiPDisabled";

static IMP YTKACEShortsOrigAllowed;
static IMP YTKACEShortsOrigEligible;
static IMP YTKACEShortsOrigCanEnable;
static IMP YTKACEOrigPiPGetAuto;
static IMP YTKACEOrigPiPGetAutoLegacy;
static IMP YTKACEOrigPiPStart;
static IMP YTKACEOrigDidPressPause;
static IMP YTKACEOrigDidPressPlay;

BOOL YTKACEIsPlaybackPaused(id sender) {
    if (YTKACEManualPiPRequested) return NO;

    // Direct AVPlayer check if sender exposes a playerLayer with AVPlayer
    if ([sender isKindOfClass:AVPictureInPictureController.class]) {
        AVPictureInPictureController *pip = (AVPictureInPictureController *)sender;
        if ([pip respondsToSelector:@selector(playerLayer)]) {
            AVPlayerLayer *pl = pip.playerLayer;
            if (pl != nil && [pl isKindOfClass:AVPlayerLayer.class] && pl.player != nil) {
                return pl.player.timeControlStatus == AVPlayerTimeControlStatusPaused;
            }
        }
    }

    @synchronized (YTKACEPlaybackActivityLock()) {
        return YTKACEPlaybackActivity.paused(CACurrentMediaTime());
    }
}

static id YTKACEShortsPiPOwner(id controller) {
    if (controller == nil) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(controller), "_delegate");
    if (ivar == NULL) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (type == NULL || type[0] != '@') return nil;
    return object_getIvar(controller, ivar);
}

static BOOL YTKACELibraryOwnsPiP(void) {
    YTKACEDownloadPlaybackSession *session = YTKACEDownloadPlaybackSession.existingSession;
    return session.currentURL != nil && session.player.rate != 0.0f;
}

static BOOL YTKACEControllerIsReel(id controller) {
    id current = YTKACEShortsPiPOwner(controller);
    if (current == nil) current = controller;
    SEL parentSel = NSSelectorFromString(@"parentResponder");
    for (NSUInteger depth = 0; current != nil && depth < 10; depth++) {
        NSString *name = NSStringFromClass([current class]);
        if ([name containsString:@"Reel"] || [name containsString:@"Shorts"] ||
            YTKACEPlayerIsShorts(current)) {
            return YES;
        }
        if (![current respondsToSelector:parentSel]) break;
        current = ((id (*)(id, SEL))objc_msgSend)(current, parentSel);
    }
    return NO;
}

static BOOL YTKACEShortsBlocksPiP(id controller) {
    if (YTKACELibraryOwnsPiP()) return YES;
    if (YTKACEFeatureEnabled(YTKACEShortsPiPKey) && YTKACEControllerIsReel(controller)) {
        return YES;
    }
    return NO;
}

static BOOL YTKACEShortsAllowed(id self, SEL _cmd) {
    if (YTKACEShortsBlocksPiP(self)) return NO;
    if (YTKACEControllerIsReel(self)) {
        return YTKACEShortsOrigAllowed != NULL
            ? ((BOOL (*)(id, SEL))YTKACEShortsOrigAllowed)(self, _cmd)
            : NO;
    }
    return YTKACEShortsOrigAllowed != NULL
        ? ((BOOL (*)(id, SEL))YTKACEShortsOrigAllowed)(self, _cmd)
        : YES;
}

static BOOL YTKACEShortsEligible(id self, SEL _cmd) {
    if (YTKACEShortsBlocksPiP(self)) return NO;
    BOOL isReel = YTKACEControllerIsReel(self);
    BOOL eligible = YTKACEShortsOrigEligible != NULL
        ? ((BOOL (*)(id, SEL))YTKACEShortsOrigEligible)(self, _cmd)
        : NO;
    if (!eligible && !isReel && YTKACEFeatureEnabled(YTKACEBackgroundPlaybackKey)) {
        return YES;
    }
    return eligible;
}

static BOOL YTKACEShortsCanEnable(id self, SEL _cmd) {
    if (YTKACEShortsBlocksPiP(self)) return NO;
    if (YTKACEControllerIsReel(self)) {
        return YTKACEShortsOrigCanEnable != NULL
            ? ((BOOL (*)(id, SEL))YTKACEShortsOrigCanEnable)(self, _cmd)
            : NO;
    }
    return YTKACEShortsOrigCanEnable != NULL
        ? ((BOOL (*)(id, SEL))YTKACEShortsOrigCanEnable)(self, _cmd)
        : YES;
}

static BOOL YTKACEPiPGetAuto(id self, SEL _cmd) {
    if (YTKACEIsPlaybackPaused(self)) return NO;
    return YTKACEOrigPiPGetAuto != NULL
        ? ((BOOL (*)(id, SEL))YTKACEOrigPiPGetAuto)(self, _cmd)
        : YES;
}

static BOOL YTKACEPiPGetAutoLegacy(id self, SEL _cmd) {
    if (YTKACEIsPlaybackPaused(self)) return NO;
    return YTKACEOrigPiPGetAutoLegacy != NULL
        ? ((BOOL (*)(id, SEL))YTKACEOrigPiPGetAutoLegacy)(self, _cmd)
        : YES;
}

static void YTKACEPiPStart(id self, SEL _cmd) {
    if (!YTKACEManualPiPRequested && YTKACEIsPlaybackPaused(self)) {
        return;
    }
    if (YTKACEOrigPiPStart != NULL) {
        ((void (*)(id, SEL))YTKACEOrigPiPStart)(self, _cmd);
    }
}

// YouTube also requires its own PiP setting, which accounts without Premium cannot turn on.
static IMP YTKACEOrigPiPByUserSettings;
static BOOL YTKACEPiPByUserSettings(id self, SEL _cmd) {
    if (YTKACEFeatureEnabled(YTKACEBackgroundPlaybackKey) || YTKACEFeatureEnabled(YTKACEPiPKey)) return YES;
    return YTKACEOrigPiPByUserSettings != NULL && ((BOOL (*)(id, SEL))YTKACEOrigPiPByUserSettings)(self, _cmd);
}

static IMP YTKACEOrigPiPDefaultOff;
static BOOL YTKACEPiPDefaultOff(id self, SEL _cmd) {
    if (YTKACEFeatureEnabled(YTKACEBackgroundPlaybackKey) || YTKACEFeatureEnabled(YTKACEPiPKey)) return NO;
    return YTKACEOrigPiPDefaultOff != NULL && ((BOOL (*)(id, SEL))YTKACEOrigPiPDefaultOff)(self, _cmd);
}

// iOS shows a video without a finite time range as live: a stop button and no skipping.
static BOOL YTKACEPiPShortDuration(id player, double *duration) {
    if (player == nil || !YTKACEResolveShortsPlayback(player, NULL)) return NO;
    *duration = YTKACESponsorCurrentDuration();
    return isfinite(*duration) && *duration > 0.0;
}

static IMP YTKACEOrigPiPTimeRange;
static CMTimeRange YTKACEPiPTimeRange(id self, SEL _cmd, id controller) {
    CMTimeRange range = YTKACEOrigPiPTimeRange != NULL
        ? ((CMTimeRange (*)(id, SEL, id))YTKACEOrigPiPTimeRange)(self, _cmd, controller)
        : kCMTimeRangeInvalid;
    if (CMTIMERANGE_IS_VALID(range) && CMTIME_IS_NUMERIC(range.duration) &&
        CMTimeGetSeconds(range.duration) > 0.0) {
        return range;
    }
    double duration = 0.0;
    BOOL isShort = YTKACEPiPShortDuration(YTKACEActivePlayerViewController(), &duration);
    YTKACEDebugLog(@"shorts", @"pip range valid=%d short=%d duration=%.1f",
        CMTIMERANGE_IS_VALID(range), isShort, duration);
    return isShort ? CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(duration, 600)) : range;
}

static IMP YTKACEOrigPiPSeek;
static void YTKACEPiPSeek(id self, SEL _cmd, double interval) {
    id player = YTKACEActivePlayerViewController();
    double duration = 0.0;
    SEL seek = @selector(seekToTime:);
    if (YTKACEPiPShortDuration(player, &duration) && [player respondsToSelector:seek]) {
        double target = MAX(0.0, MIN(duration, YTKACESponsorCurrentTime() + interval));
        YTKACEDebugLog(@"shorts", @"pip seek interval=%.0f target=%.1f", interval, target);
        ((void (*)(id, SEL, double))objc_msgSend)(player, seek, target);
        return;
    }
    if (YTKACEOrigPiPSeek != NULL) ((void (*)(id, SEL, double))YTKACEOrigPiPSeek)(self, _cmd, interval);
}

static void YTKACEDidPressPause(id self, SEL _cmd, id sender) {
    YTKACENotifyPlaybackPaused();
    if (YTKACEOrigDidPressPause != NULL) {
        ((void (*)(id, SEL, id))YTKACEOrigDidPressPause)(self, _cmd, sender);
    }
}

static void YTKACEDidPressPlay(id self, SEL _cmd, id sender) {
    YTKACENotifyPlaybackTick();
    if (YTKACEOrigDidPressPlay != NULL) {
        ((void (*)(id, SEL, id))YTKACEOrigDidPressPlay)(self, _cmd, sender);
    }
}

void YTKACEInstallShortsPiPHooks(void) {
    NSString *pipClass = @"YTPlayerPIPController";
    YTKACEInstallInstanceHook(pipClass, @"isPictureInPictureAllowed",
        (IMP)YTKACEShortsAllowed, &YTKACEShortsOrigAllowed);
    YTKACEInstallInstanceHook(pipClass, @"isEligibleForPictureInPicture",
        (IMP)YTKACEShortsEligible, &YTKACEShortsOrigEligible);
    YTKACEInstallInstanceHook(pipClass, @"canEnablePictureInPicture",
        (IMP)YTKACEShortsCanEnable, &YTKACEShortsOrigCanEnable);
    YTKACEInstallInstanceHook(@"YTBackgroundabilityPolicyImpl", @"isPlayableInPictureInPictureByUserSettings",
        (IMP)YTKACEPiPByUserSettings, &YTKACEOrigPiPByUserSettings);
    YTKACEInstallInstanceHook(@"YTHotConfig", @"iosPlayerClientSharedConfigDefaultOffPremiumPip",
        (IMP)YTKACEPiPDefaultOff, &YTKACEOrigPiPDefaultOff);
    YTKACEInstallInstanceHook(@"MLPIPControllerImpl", @"pictureInPictureControllerTimeRangeForPlayback:",
        (IMP)YTKACEPiPTimeRange, &YTKACEOrigPiPTimeRange);
    // Only with the argument this hook expects: a double.
    Method seekMethod = class_getInstanceMethod(NSClassFromString(pipClass),
        NSSelectorFromString(@"pictureInPicturePlaybackRequestedSeekWithInterval:"));
    char *seekArgument = seekMethod != NULL ? method_copyArgumentType(seekMethod, 2) : NULL;
    if (seekArgument != NULL && seekArgument[0] == 'd') {
        YTKACEInstallInstanceHook(pipClass, @"pictureInPicturePlaybackRequestedSeekWithInterval:",
            (IMP)YTKACEPiPSeek, &YTKACEOrigPiPSeek);
    } else {
        YTKACEDownloadLog(@"shorts", @"pip seek hook skipped argument=%s", seekArgument ?: "none");
    }
    free(seekArgument);

    YTKACEInstallInstanceHook(@"AVPictureInPictureController",
        @"canStartPictureInPictureAutomaticallyFromInline",
        (IMP)YTKACEPiPGetAuto, &YTKACEOrigPiPGetAuto);
    if ([NSClassFromString(@"AVPictureInPictureController")
            instancesRespondToSelector:NSSelectorFromString(@"canStartAutomaticallyWhenEnteringBackground")]) {
        YTKACEInstallInstanceHook(@"AVPictureInPictureController",
            @"canStartAutomaticallyWhenEnteringBackground",
            (IMP)YTKACEPiPGetAutoLegacy, &YTKACEOrigPiPGetAutoLegacy);
    }
    YTKACEInstallInstanceHook(@"AVPictureInPictureController",
        @"startPictureInPicture",
        (IMP)YTKACEPiPStart, &YTKACEOrigPiPStart);

    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didPressPause:", (IMP)YTKACEDidPressPause, &YTKACEOrigDidPressPause);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didPressPlay:", (IMP)YTKACEDidPressPlay, &YTKACEOrigDidPressPlay);
}
