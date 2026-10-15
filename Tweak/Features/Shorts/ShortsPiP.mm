#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/YTKACEDownloadPlayerController.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>

BOOL YTKACEManualPiPRequested = NO;
static CFTimeInterval YTKACELastPauseTime = 0.0;
static CFTimeInterval YTKACELastPlayTime = 0.0;

void YTKACENotifyPlaybackTick(void) {
    YTKACELastPlayTime = CACurrentMediaTime();
}

static NSString *const YTKACEShortsPiPKey = @"YTKACE.Preference.Shorts.PiPDisabled";

static IMP YTKACEShortsOrigAllowed;
static IMP YTKACEShortsOrigEligible;
static IMP YTKACEShortsOrigCanEnable;
static IMP YTKACEOrigMaybeEnablePiP;
static IMP YTKACEOrigMaybeInvokePiP;
static IMP YTKACEOrigMLPIPActivate;
static IMP YTKACEOrigPiPGetAuto;
static IMP YTKACEOrigPiPGetAutoLegacy;
static IMP YTKACEOrigPiPStart;
static IMP YTKACEOrigPlayerVCPause;
static IMP YTKACEOrigPlayerVCPlay;
static IMP YTKACEOrigMLAVPlayerPlay;
static IMP YTKACEOrigMLAVPlayerPause;

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

static BOOL YTKACEIsPiPControllerPaused(AVPictureInPictureController *pip) {
    if (pip == nil) return YES;

    AVPlayerLayer *playerLayer = nil;
    if ([pip respondsToSelector:@selector(playerLayer)]) {
        playerLayer = pip.playerLayer;
    }
    if (playerLayer == nil) {
        @try {
            id val = [pip valueForKey:@"_playerLayer"];
            if ([val isKindOfClass:AVPlayerLayer.class]) {
                playerLayer = (AVPlayerLayer *)val;
            }
        } @catch (__unused id ex) {}
    }
    if (playerLayer != nil && [playerLayer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayer *player = playerLayer.player;
        if (player != nil) {
            if (player.rate <= 0.001f) return YES;
            if (@available(iOS 10.0, *)) {
                if (player.timeControlStatus == AVPlayerTimeControlStatusPaused) {
                    return YES;
                }
            }
            return NO;
        }
    }

    if (@available(iOS 15.0, *)) {
        if ([pip respondsToSelector:@selector(contentSource)]) {
            AVPictureInPictureControllerContentSource *source = pip.contentSource;
            if (source != nil) {
                if ([source respondsToSelector:@selector(playerLayer)]) {
                    AVPlayerLayer *pl = source.playerLayer;
                    if (pl != nil && [pl isKindOfClass:AVPlayerLayer.class] && pl.player != nil) {
                        if (pl.player.rate <= 0.001f) return YES;
                        if (pl.player.timeControlStatus == AVPlayerTimeControlStatusPaused) {
                            return YES;
                        }
                        return NO;
                    }
                }
                if ([source respondsToSelector:@selector(sampleBufferDisplayLayer)]) {
                    AVSampleBufferDisplayLayer *sbdl = source.sampleBufferDisplayLayer;
                    if (sbdl != nil && [sbdl isKindOfClass:AVSampleBufferDisplayLayer.class]) {
                        CMTimebaseRef tb = sbdl.controlTimebase;
                        if (tb == NULL) return YES;
                        Float64 rate = CMTimebaseGetRate(tb);
                        return rate <= 0.001;
                    }
                }
            }
        }
    }

    return NO;
}

BOOL YTKACEIsPlaybackPaused(id sender) {
    if (YTKACEManualPiPRequested) return NO;

    if ([sender isKindOfClass:AVPictureInPictureController.class]) {
        return YTKACEIsPiPControllerPaused((AVPictureInPictureController *)sender);
    }

    if (sender != nil) {
        @try {
            id pip = [sender valueForKey:@"_pipController"];
            if (pip != nil) {
                id avpip = [pip valueForKey:@"_pictureInPictureController"];
                if ([avpip isKindOfClass:AVPictureInPictureController.class]) {
                    return YTKACEIsPiPControllerPaused((AVPictureInPictureController *)avpip);
                }
            }
        } @catch (__unused id ex) {}
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (YTKACELastPauseTime > 0.0 &&
        (YTKACELastPauseTime >= YTKACELastPlayTime ||
         (now - YTKACELastPlayTime > 1.5 && YTKACELastPauseTime > YTKACELastPlayTime - 0.5))) {
        return YES;
    }

    id owner = nil;
    if (sender != nil) {
        owner = YTKACEShortsPiPOwner(sender);
    }
    if (owner == nil) {
        owner = YTKACEActivePlayerViewController();
    }

    if (owner != nil) {
        id media = nil;
        SEL mediaSel = NSSelectorFromString(@"mediaPlayer");
        SEL activeSel = NSSelectorFromString(@"activeVideo");
        if ([owner respondsToSelector:mediaSel]) {
            media = ((id (*)(id, SEL))objc_msgSend)(owner, mediaSel);
        } else if ([owner respondsToSelector:activeSel]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(owner, activeSel);
            if (v != nil && [v respondsToSelector:mediaSel]) {
                media = ((id (*)(id, SEL))objc_msgSend)(v, mediaSel);
            }
        }

        if (media != nil) {
            SEL rateSel = NSSelectorFromString(@"rate");
            if ([media respondsToSelector:rateSel]) {
                float r = ((float (*)(id, SEL))objc_msgSend)(media, rateSel);
                if (r <= 0.001f) return YES;
                return NO;
            }
            SEL isPlayingSel = NSSelectorFromString(@"isPlaying");
            if ([media respondsToSelector:isPlayingSel]) {
                BOOL playing = ((BOOL (*)(id, SEL))objc_msgSend)(media, isPlayingSel);
                return !playing;
            }
            SEL isPausedSel = NSSelectorFromString(@"isPaused");
            if ([media respondsToSelector:isPausedSel]) {
                return ((BOOL (*)(id, SEL))objc_msgSend)(media, isPausedSel);
            }
        }

        SEL isPlayingSel = NSSelectorFromString(@"isPlaying");
        if ([owner respondsToSelector:isPlayingSel]) {
            BOOL playing = ((BOOL (*)(id, SEL))objc_msgSend)(owner, isPlayingSel);
            return !playing;
        }
        SEL rateSel = NSSelectorFromString(@"rate");
        if ([owner respondsToSelector:rateSel]) {
            float r = ((float (*)(id, SEL))objc_msgSend)(owner, rateSel);
            if (r <= 0.001f) return YES;
            return NO;
        }
        SEL playerStateSel = NSSelectorFromString(@"playerState");
        if ([owner respondsToSelector:playerStateSel]) {
            NSInteger state = ((NSInteger (*)(id, SEL))objc_msgSend)(owner, playerStateSel);
            if (state == 3 || state == 1 || state == 0) return YES;
            if (state == 2) return NO;
        }
    }

    NSHashTable<AVPictureInPictureController *> *allPiP = YTKACEAllPiPControllers();
    if (allPiP != nil && allPiP.count > 0) {
        BOOL anyPlaying = NO;
        BOOL foundKnownState = NO;
        for (AVPictureInPictureController *pip in allPiP.allObjects) {
            if ([pip isKindOfClass:AVPictureInPictureController.class]) {
                if (!YTKACEIsPiPControllerPaused(pip)) {
                    anyPlaying = YES;
                    break;
                }
                foundKnownState = YES;
            }
        }
        if (anyPlaying) return NO;
        if (foundKnownState) return YES;
    }

    return NO;
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
    if (YTKACEIsPlaybackPaused(self)) return NO;
    return YTKACEShortsOrigAllowed != NULL
        ? ((BOOL (*)(id, SEL))YTKACEShortsOrigAllowed)(self, _cmd)
        : NO;
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
        : NO;
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

static void YTKACEMLPIPActivate(id self, SEL _cmd) {
    if (!YTKACEManualPiPRequested && YTKACEIsPlaybackPaused(self)) return;
    if (YTKACEOrigMLPIPActivate != NULL) {
        ((void (*)(id, SEL))YTKACEOrigMLPIPActivate)(self, _cmd);
    }
}

static BOOL YTKACEPiPGetAuto(id self, SEL _cmd) {
    if (YTKACEIsPlaybackPaused(self)) return NO;
    return YTKACEOrigPiPGetAuto != NULL
        ? ((BOOL (*)(id, SEL))YTKACEOrigPiPGetAuto)(self, _cmd)
        : NO;
}

static BOOL YTKACEPiPGetAutoLegacy(id self, SEL _cmd) {
    if (YTKACEIsPlaybackPaused(self)) return NO;
    return YTKACEOrigPiPGetAutoLegacy != NULL
        ? ((BOOL (*)(id, SEL))YTKACEOrigPiPGetAutoLegacy)(self, _cmd)
        : NO;
}

static void YTKACEPiPStart(id self, SEL _cmd) {
    if (!YTKACEManualPiPRequested && YTKACEIsPlaybackPaused(self)) {
        return;
    }
    if (YTKACEOrigPiPStart != NULL) {
        ((void (*)(id, SEL))YTKACEOrigPiPStart)(self, _cmd);
    }
}

static void YTKACEPlayerVCPause(id self, SEL _cmd) {
    YTKACELastPauseTime = CACurrentMediaTime();
    if (YTKACEOrigPlayerVCPause != NULL) {
        ((void (*)(id, SEL))YTKACEOrigPlayerVCPause)(self, _cmd);
    }
}

static void YTKACEPlayerVCPlay(id self, SEL _cmd) {
    YTKACELastPlayTime = CACurrentMediaTime();
    if (YTKACEOrigPlayerVCPlay != NULL) {
        ((void (*)(id, SEL))YTKACEOrigPlayerVCPlay)(self, _cmd);
    }
}

static void YTKACEMLAVPlayerPlay(id self, SEL _cmd) {
    YTKACELastPlayTime = CACurrentMediaTime();
    if (YTKACEOrigMLAVPlayerPlay != NULL) {
        ((void (*)(id, SEL))YTKACEOrigMLAVPlayerPlay)(self, _cmd);
    }
}

static void YTKACEMLAVPlayerPause(id self, SEL _cmd, int reason) {
    YTKACELastPauseTime = CACurrentMediaTime();
    if (YTKACEOrigMLAVPlayerPause != NULL) {
        ((void (*)(id, SEL, int))YTKACEOrigMLAVPlayerPause)(self, _cmd, reason);
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

    YTKACEInstallInstanceHook(@"MLPIPController", @"activatePiPController",
        (IMP)YTKACEMLPIPActivate, &YTKACEOrigMLPIPActivate);
    YTKACEInstallInstanceHook(@"MLPIPControllerImpl", @"activatePiPController",
        (IMP)YTKACEMLPIPActivate, &YTKACEOrigMLPIPActivate);

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

    YTKACEInstallInstanceHook(@"YTPlayerViewController", @"pause",
        (IMP)YTKACEPlayerVCPause, &YTKACEOrigPlayerVCPause);
    YTKACEInstallInstanceHook(@"YTPlayerViewController", @"play",
        (IMP)YTKACEPlayerVCPlay, &YTKACEOrigPlayerVCPlay);

    YTKACEInstallInstanceHook(@"MLAVPlayer", @"play",
        (IMP)YTKACEMLAVPlayerPlay, &YTKACEOrigMLAVPlayerPlay);
    YTKACEInstallInstanceHook(@"MLAVPlayer", @"pauseWithStoppageReason:",
        (IMP)YTKACEMLAVPlayerPause, &YTKACEOrigMLAVPlayerPause);
}
