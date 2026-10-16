#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/YTKACEDownloadPlayerController.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

BOOL YTKACEManualPiPRequested = NO;
static CFTimeInterval YTKACELastPlayTick = 0.0;
static CFTimeInterval YTKACELastPauseTick = 0.0;
static BOOL YTKACEPlaybackIsPlaying = NO;
static double YTKACELastSeenVideoTime = -1.0;

void YTKACENotifyPlaybackTick(void) {
    YTKACELastPlayTick = CACurrentMediaTime();
    YTKACEPlaybackIsPlaying = YES;
}

void YTKACENotifyPlaybackPaused(void) {
    YTKACELastPauseTick = CACurrentMediaTime();
    YTKACEPlaybackIsPlaying = NO;
}

void YTKACENotifyVideoTime(double time) {
    if (time > 0.0) {
        if (fabs(time - YTKACELastSeenVideoTime) > 0.01) {
            YTKACELastSeenVideoTime = time;
            YTKACENotifyPlaybackTick();
        }
    } else {
        YTKACENotifyPlaybackTick();
    }
}

static NSString *const YTKACEShortsPiPKey = @"YTKACE.Preference.Shorts.PiPDisabled";

static IMP YTKACEShortsOrigAllowed;
static IMP YTKACEShortsOrigEligible;
static IMP YTKACEShortsOrigCanEnable;
static IMP YTKACEOrigMaybeEnablePiP;
static IMP YTKACEOrigMaybeInvokePiP;
static IMP YTKACEOrigPiPGetAuto;
static IMP YTKACEOrigPiPGetAutoLegacy;
static IMP YTKACEOrigPiPStart;
static IMP YTKACEOrigHAMSetRate;
static IMP YTKACEOrigMLAVPlayerPlay;
static IMP YTKACEOrigMLAVPlayerPause;
static IMP YTKACEOrigPlayerPIPPlay;
static IMP YTKACEOrigPlayerPIPPause;
static IMP YTKACEOrigMLPIPPause;
static IMP YTKACEOrigMLPIPImplPause;
static IMP YTKACEOrigMLPIPStartPlayback;
static IMP YTKACEOrigMLPIPStopPlayback;
static IMP YTKACEOrigDidPressPause;
static IMP YTKACEOrigDidPressPlay;
static IMP YTKACEOrigPlayerVCPause;
static IMP YTKACEOrigPlayerVCPlay;

BOOL YTKACEIsPlaybackPaused(id sender) {
    if (YTKACEManualPiPRequested) return NO;

    // Check offline downloads player session
    YTKACEDownloadPlaybackSession *dlSession = YTKACEDownloadPlaybackSession.existingSession;
    if (dlSession != nil && dlSession.currentURL != nil && dlSession.player != nil) {
        return dlSession.player.rate <= 0.001f;
    }

    // Direct AVPlayer check if sender exposes a playerLayer with AVPlayer
    if ([sender isKindOfClass:AVPictureInPictureController.class]) {
        AVPictureInPictureController *pip = (AVPictureInPictureController *)sender;
        if ([pip respondsToSelector:@selector(playerLayer)]) {
            AVPlayerLayer *pl = pip.playerLayer;
            if (pl != nil && [pl isKindOfClass:AVPlayerLayer.class] && pl.player != nil) {
                return pl.player.rate <= 0.001f;
            }
        }
    }

    CFTimeInterval now = CACurrentMediaTime();

    // Explicit pause occurred after the last play tick -> PAUSED
    if (YTKACELastPauseTick > 0.0 && YTKACELastPauseTick >= YTKACELastPlayTick) {
        return YES;
    }

    // Playback ticked recently (within 2.5s) and not superseded by pause -> PLAYING
    if (YTKACELastPlayTick > 0.0 && (now - YTKACELastPlayTick < 2.5)) {
        return NO;
    }

    // Playback is marked playing and ticked within 3.5s -> PLAYING
    if (YTKACEPlaybackIsPlaying && YTKACELastPlayTick > 0.0 && (now - YTKACELastPlayTick < 3.5)) {
        return NO;
    }

    // Otherwise (cold launch, ended video, idle) -> PAUSED
    return YES;
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

static BOOL YTKACEShortsBlocksPiP(id controller) {
    if (YTKACELibraryOwnsPiP()) return YES;
    if (!YTKACEFeatureEnabled(YTKACEShortsPiPKey)) return NO;
    SEL parentSel = NSSelectorFromString(@"parentResponder");
    id current = YTKACEShortsPiPOwner(controller);
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

static BOOL YTKACEShortsAllowed(id self, SEL _cmd) {
    if (YTKACEShortsBlocksPiP(self)) return NO;
    return YTKACEShortsOrigAllowed != NULL
        ? ((BOOL (*)(id, SEL))YTKACEShortsOrigAllowed)(self, _cmd)
        : YES;
}

static BOOL YTKACEShortsEligible(id self, SEL _cmd) {
    if (YTKACEShortsBlocksPiP(self)) return NO;
    if (YTKACEIsPlaybackPaused(self)) return NO;
    BOOL eligible = YTKACEShortsOrigEligible != NULL
        ? ((BOOL (*)(id, SEL))YTKACEShortsOrigEligible)(self, _cmd)
        : NO;
    if (!eligible && YTKACEFeatureEnabled(YTKACEBackgroundPlaybackKey)) return YES;
    return eligible;
}

static BOOL YTKACEShortsCanEnable(id self, SEL _cmd) {
    if (YTKACEShortsBlocksPiP(self)) return NO;
    if (YTKACEIsPlaybackPaused(self)) return NO;
    return YTKACEShortsOrigCanEnable != NULL
        ? ((BOOL (*)(id, SEL))YTKACEShortsOrigCanEnable)(self, _cmd)
        : YES;
}

static void YTKACEMaybeEnablePiP(id self, SEL _cmd) {
    if (YTKACEIsPlaybackPaused(self)) return;
    if (YTKACEOrigMaybeEnablePiP != NULL) {
        ((void (*)(id, SEL))YTKACEOrigMaybeEnablePiP)(self, _cmd);
    }
}

static void YTKACEMaybeInvokePiP(id self, SEL _cmd) {
    if (YTKACEIsPlaybackPaused(self)) return;
    if (YTKACEOrigMaybeInvokePiP != NULL) {
        ((void (*)(id, SEL))YTKACEOrigMaybeInvokePiP)(self, _cmd);
    }
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

static void YTKACEHAMSetRate(id self, SEL _cmd, float rate) {
    if (rate <= 0.001f) {
        YTKACENotifyPlaybackPaused();
    } else {
        YTKACENotifyPlaybackTick();
    }
    if (YTKACEOrigHAMSetRate != NULL) {
        ((void (*)(id, SEL, float))YTKACEOrigHAMSetRate)(self, _cmd, rate);
    }
}

static void YTKACEMLAVPlayerPlay(id self, SEL _cmd) {
    YTKACENotifyPlaybackTick();
    if (YTKACEOrigMLAVPlayerPlay != NULL) {
        ((void (*)(id, SEL))YTKACEOrigMLAVPlayerPlay)(self, _cmd);
    }
}

static void YTKACEMLAVPlayerPause(id self, SEL _cmd, int reason) {
    YTKACENotifyPlaybackPaused();
    if (YTKACEOrigMLAVPlayerPause != NULL) {
        ((void (*)(id, SEL, int))YTKACEOrigMLAVPlayerPause)(self, _cmd, reason);
    }
}

static void YTKACEPlayerPIPPlay(id self, SEL _cmd) {
    YTKACENotifyPlaybackTick();
    if (YTKACEOrigPlayerPIPPlay != NULL) {
        ((void (*)(id, SEL))YTKACEOrigPlayerPIPPlay)(self, _cmd);
    }
}

static void YTKACEPlayerPIPPause(id self, SEL _cmd) {
    YTKACENotifyPlaybackPaused();
    if (YTKACEOrigPlayerPIPPause != NULL) {
        ((void (*)(id, SEL))YTKACEOrigPlayerPIPPause)(self, _cmd);
    }
}

static void YTKACEMLPIPPause(id self, SEL _cmd) {
    YTKACENotifyPlaybackPaused();
    if (YTKACEOrigMLPIPPause != NULL) {
        ((void (*)(id, SEL))YTKACEOrigMLPIPPause)(self, _cmd);
    }
}

static void YTKACEMLPIPImplPause(id self, SEL _cmd) {
    YTKACENotifyPlaybackPaused();
    if (YTKACEOrigMLPIPImplPause != NULL) {
        ((void (*)(id, SEL))YTKACEOrigMLPIPImplPause)(self, _cmd);
    }
}

static void YTKACEMLPIPStartPlayback(id self, SEL _cmd) {
    YTKACENotifyPlaybackTick();
    if (YTKACEOrigMLPIPStartPlayback != NULL) {
        ((void (*)(id, SEL))YTKACEOrigMLPIPStartPlayback)(self, _cmd);
    }
}

static void YTKACEMLPIPStopPlayback(id self, SEL _cmd) {
    YTKACENotifyPlaybackPaused();
    if (YTKACEOrigMLPIPStopPlayback != NULL) {
        ((void (*)(id, SEL))YTKACEOrigMLPIPStopPlayback)(self, _cmd);
    }
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

static void YTKACEPlayerVCPause(id self, SEL _cmd) {
    YTKACENotifyPlaybackPaused();
    if (YTKACEOrigPlayerVCPause != NULL) {
        ((void (*)(id, SEL))YTKACEOrigPlayerVCPause)(self, _cmd);
    }
}

static void YTKACEPlayerVCPlay(id self, SEL _cmd) {
    YTKACENotifyPlaybackTick();
    if (YTKACEOrigPlayerVCPlay != NULL) {
        ((void (*)(id, SEL))YTKACEOrigPlayerVCPlay)(self, _cmd);
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
    YTKACEInstallInstanceHook(pipClass, @"maybeEnablePictureInPicture",
        (IMP)YTKACEMaybeEnablePiP, &YTKACEOrigMaybeEnablePiP);
    YTKACEInstallInstanceHook(pipClass, @"maybeInvokePictureInPicture",
        (IMP)YTKACEMaybeInvokePiP, &YTKACEOrigMaybeInvokePiP);
    YTKACEInstallInstanceHook(pipClass, @"play",
        (IMP)YTKACEPlayerPIPPlay, &YTKACEOrigPlayerPIPPlay);
    YTKACEInstallInstanceHook(pipClass, @"pause",
        (IMP)YTKACEPlayerPIPPause, &YTKACEOrigPlayerPIPPause);

    YTKACEInstallInstanceHook(@"MLPIPController", @"pause",
        (IMP)YTKACEMLPIPPause, &YTKACEOrigMLPIPPause);
    YTKACEInstallInstanceHook(@"MLPIPControllerImpl", @"pause",
        (IMP)YTKACEMLPIPImplPause, &YTKACEOrigMLPIPImplPause);
    YTKACEInstallInstanceHook(@"MLPIPController", @"pictureInPictureControllerStartPlayback",
        (IMP)YTKACEMLPIPStartPlayback, &YTKACEOrigMLPIPStartPlayback);
    YTKACEInstallInstanceHook(@"MLPIPController", @"pictureInPictureControllerStopPlayback",
        (IMP)YTKACEMLPIPStopPlayback, &YTKACEOrigMLPIPStopPlayback);

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

    YTKACEInstallInstanceHook(@"MLHAMQueuePlayer", @"setRate:",
        (IMP)YTKACEHAMSetRate, &YTKACEOrigHAMSetRate);

    YTKACEInstallInstanceHook(@"MLAVPlayer", @"play",
        (IMP)YTKACEMLAVPlayerPlay, &YTKACEOrigMLAVPlayerPlay);
    YTKACEInstallInstanceHook(@"MLAVPlayer", @"pauseWithStoppageReason:",
        (IMP)YTKACEMLAVPlayerPause, &YTKACEOrigMLAVPlayerPause);

    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didPressPause:", (IMP)YTKACEDidPressPause, &YTKACEOrigDidPressPause);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didPressPlay:", (IMP)YTKACEDidPressPlay, &YTKACEOrigDidPressPlay);

    YTKACEInstallInstanceHook(@"YTPlayerViewController", @"pause",
        (IMP)YTKACEPlayerVCPause, &YTKACEOrigPlayerVCPause);
    YTKACEInstallInstanceHook(@"YTPlayerViewController", @"play",
        (IMP)YTKACEPlayerVCPlay, &YTKACEOrigPlayerVCPlay);
}
