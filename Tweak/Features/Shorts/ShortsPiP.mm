#import "../../YTKACE.h"
#include "../../Runtime/MediaPolicy.h"
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
