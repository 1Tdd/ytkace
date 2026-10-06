#import "SponsorHooks.h"
#import "SponsorSubmitController.h"
#import "SponsorClient.h"
#import "SponsorPreferences.h"
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../Runtime/Localization.h"
#import "../Downloads/DownloadLog.h"
#import "../Downloads/SABRDownloader.h"
#import "../../UI/Assets.h"

#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

static IMP OriginalDidActivateVideo;
static IMP OriginalSingleVideoTimeChanged;
static IMP OriginalMutatedVideoTimeChanged;
static IMP OriginalPlayerBarLayout;
static IMP OriginalMiniplayerBarLayout;
static IMP OriginalOverlayScrubStart;
static IMP OriginalOverlayScrubEnd;
static IMP OriginalPlayerBarDidBeginScrubbing;
static IMP OriginalPlayerBarDidEndScrubbing;
static IMP OriginalOverlayChaptersDidChange;
static IMP OriginalPlayerBarControllerSetChapters;
static IMP OriginalInlinePlayerBarSetChapters;
static BOOL YTKACEUserIsScrubbing = NO;

static const void *YTKACESponsorSegmentsAssociation = &YTKACESponsorSegmentsAssociation;
static const void *YTKACESponsorVideoAssociation = &YTKACESponsorVideoAssociation;
static const void *YTKACESponsorChannelAssociation = &YTKACESponsorChannelAssociation;
static const void *YTKACESponsorSkippedAssociation = &YTKACESponsorSkippedAssociation;
static const void *YTKACESponsorUnskippedAssociation = &YTKACESponsorUnskippedAssociation;
static NSTimeInterval YTKACELastUnskipTime = 0.0;
static BOOL YTKACEWasScrubbing = NO;
static const void *YTKACESponsorMarkerAssociation = &YTKACESponsorMarkerAssociation;
static const void *YTKACESponsorRenderedSegmentsAssociation = &YTKACESponsorRenderedSegmentsAssociation;
static const void *YTKACESponsorMarkerBoundsAssociation = &YTKACESponsorMarkerBoundsAssociation;
static const void *YTKACESponsorMarkerDurationAssociation = &YTKACESponsorMarkerDurationAssociation;
static const void *YTKACESponsorPlaybackDataAssociation = &YTKACESponsorPlaybackDataAssociation;
static const void *YTKACESponsorVideoObjectAssociation = &YTKACESponsorVideoObjectAssociation;
static const void *YTKACEOptionsOriginalDurationTextKey = &YTKACEOptionsOriginalDurationTextKey;
static const void *YTKACEOptionsModifiedDurationTextKey = &YTKACEOptionsModifiedDurationTextKey;
static void YTKACEUpdatePlayerBarDuration(UIView *barView);
static __weak id YTKACECurrentSponsorController;
static __weak id YTKACELastMacroMarkersController;
static __weak id YTKACELastOverlayController;
static __weak id YTKACELastPlayerBarController;
static NSArray *YTKACELastReceivedChapters;
static NSString *YTKACELastChaptersVideoID;
static NSHashTable<UIView *> *YTKACESponsorBars;
static BOOL YTKACESponsorTimeUpdatesEnabled;
static BOOL YTKACEPlaybackTimeNotificationsNeeded;
static id YTKACEPlaybackPreferenceObserver;

static void YTKACERefreshPlaybackTimePreferenceState(void) {
    YTKACESponsorTimeUpdatesEnabled =
        YTKACEFeatureEnabled(YTKACESponsorBlockKey);
    YTKACEPlaybackTimeNotificationsNeeded =
        YTKACEFeatureEnabled(@"shortsProgress") ||
        YTKACEFeatureEnabled(@"autoSkipShorts") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.LoopDisabled") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.LimitEnabled") ||
        YTKACEFeatureEnabled(YTKACESpeedKey) ||
        YTKACEFeatureEnabled(YTKACESleepTimerKey) ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.LocalQueue");
}

static void YTKACEPublishPlaybackTime(id receiver, double time, double duration) {
    if (!YTKACEPlaybackTimeNotificationsNeeded) return;
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"YTKACEPlaybackTimeDidChange"
        object:receiver
        userInfo:@{@"time": @(time), @"duration": @(duration)}];
}

static id YTKACEObjectMessage(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (receiver == nil || ![receiver respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static id YTKACESafeObjectIvar(id obj, const char *ivarName) {
    if (obj == nil || ivarName == NULL) return nil;
    Class cls = object_getClass(obj);
    if (cls == Nil || class_isMetaClass(cls)) return nil;
    Ivar ivar = class_getInstanceVariable(cls, ivarName);
    if (ivar == NULL) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (type == NULL || type[0] != '@') return nil;
    return object_getIvar(obj, ivar);
}

static NSNumber *YTKACESafeNumberForKey(id obj, NSString *key) {
    if (obj == nil || key.length == 0) return nil;
    if ([obj isKindOfClass:NSDictionary.class]) {
        id val = ((NSDictionary *)obj)[key];
        if ([val isKindOfClass:NSNumber.class]) return val;
        if ([val isKindOfClass:NSString.class] && [val length] > 0) return @([val doubleValue]);
        return nil;
    }
    if (![obj respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try {
        id val = [obj valueForKey:key];
        if ([val isKindOfClass:NSNumber.class]) return val;
        if ([val isKindOfClass:NSString.class] && [val length] > 0) return @([val doubleValue]);
    } @catch (__unused NSException *e) {}
    return nil;
}

static double YTKACEDoubleMessage(id receiver, NSArray<NSString *> *selectorNames) {
    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([receiver respondsToSelector:selector]) {
            return ((double (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    return 0.0;
}

static NSString *YTKACEVideoIDFromObject(id object) {
    if (object == nil) return nil;
    if ([object isKindOfClass:NSString.class]) {
        return object;
    }
    for (NSString *selector in @[@"videoID", @"videoId", @"currentVideoID", @"contentVideoID", @"identifier"]) {
        id value = YTKACEObjectMessage(object, selector);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    for (NSString *childSel in @[@"videoDetails", @"singleVideo", @"playerResponse", @"contentPlayerResponse", @"playerData", @"playbackData", @"videoData"]) {
        id child = YTKACEObjectMessage(object, childSel);
        if (child != nil && child != object) {
            for (NSString *selector in @[@"videoID", @"videoId"]) {
                id value = YTKACEObjectMessage(child, selector);
                if ([value isKindOfClass:NSString.class] && [value length] != 0) {
                    return value;
                }
            }
            id nestedDetails = YTKACEObjectMessage(child, @"videoDetails") ?: YTKACEObjectMessage(YTKACEObjectMessage(child, @"playerData"), @"videoDetails");
            if (nestedDetails != nil) {
                for (NSString *selector in @[@"videoID", @"videoId"]) {
                    id value = YTKACEObjectMessage(nestedDetails, selector);
                    if ([value isKindOfClass:NSString.class] && [value length] != 0) {
                        return value;
                    }
                }
            }
        }
    }
    return nil;
}

static BOOL YTKACESponsorFeedbackEnabled(void) {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.SponsorBlock.AudioFeedback");
}

static UIViewController *YTKACETopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).visibleViewController;
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController;
    }
    return controller;
}

static void YTKACESeekToTime(id controller, double time) {
    SEL selector = NSSelectorFromString(@"seekToTime:");
    if ([controller respondsToSelector:selector]) {
        ((void (*)(id, SEL, double))objc_msgSend)(controller, selector, time);
    }
}

static void YTKACEFadeOutSponsorBanner(UIView *banner) {
    if (banner == nil || banner.superview == nil) return;
    [UIView animateWithDuration:0.25 delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        banner.alpha = 0.0;
        banner.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(__unused BOOL finished) {
        [banner removeFromSuperview];
    }];
}

@interface YTKACESponsorUndoTarget : NSObject
+ (instancetype)sharedTarget;
@property(nonatomic, weak) id controller;
@property(nonatomic, assign) double startTime;
@property(nonatomic, assign) double endTime;
@property(nonatomic, assign) NSUInteger segmentIndex;
@property(nonatomic, weak) UIView *banner;
- (void)unskip;
@end

@implementation YTKACESponsorUndoTarget
+ (instancetype)sharedTarget {
    static YTKACESponsorUndoTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACESponsorUndoTarget new]; });
    return target;
}
- (void)unskip {
    id controller = self.controller;
    if (controller != nil) {
        YTKACELastUnskipTime = CACurrentMediaTime();
        NSMutableSet<NSNumber *> *skipped =
            objc_getAssociatedObject(controller, YTKACESponsorSkippedAssociation);
        if (skipped == nil) {
            skipped = [NSMutableSet set];
            objc_setAssociatedObject(controller,
                                     YTKACESponsorSkippedAssociation,
                                     skipped,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [skipped addObject:@(self.segmentIndex)];

        NSMutableSet<NSNumber *> *unskipped =
            objc_getAssociatedObject(controller, YTKACESponsorUnskippedAssociation);
        if (unskipped == nil) {
            unskipped = [NSMutableSet set];
            objc_setAssociatedObject(controller,
                                     YTKACESponsorUnskippedAssociation,
                                     unskipped,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [unskipped addObject:@(self.segmentIndex)];

        if (self.endTime > self.startTime) {
            YTKACESponsorUndoSkippedTime(self.endTime - self.startTime);
        }
        YTKACESeekToTime(controller, self.startTime);
        for (UIView *bar in YTKACESponsorBars.allObjects) {
            YTKACEUpdatePlayerBarDuration(bar);
        }
    }
    YTKACEFadeOutSponsorBanner(self.banner);
}
@end

static void YTKACEShowSponsorSkippedHUD(id controller, double start, double end,
                                        NSUInteger segmentIndex, NSString *category) {
    NSInteger notificationMode = YTKACESponsorNotificationMode();
    if (notificationMode == 2) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = YTKACETopController();
        if (presenter.view.window == nil) {
            return;
        }
        YTKACESponsorUndoTarget *target = YTKACESponsorUndoTarget.sharedTarget;
        YTKACEFadeOutSponsorBanner(target.banner);
        UIView *banner = [UIView new];
        banner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        banner.layer.cornerRadius = 12.0;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *label = [UILabel new];
        label.text = [NSString stringWithFormat:@"%@ %@",
                      YTKACESponsorCategoryTitle(category),
                      YTKACELocalized(@"segment skipped")];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        UIButton *undo = [UIButton buttonWithType:UIButtonTypeSystem];
        [undo setTitle:YTKACELocalized(@"Unskip") forState:UIControlStateNormal];
        [undo setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
        undo.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [undo addTarget:target action:@selector(unskip)
            forControlEvents:UIControlEventTouchUpInside];
        NSArray *views = notificationMode == 0 ? @[label, undo] : @[label];
        UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:views];
        content.axis = UILayoutConstraintAxisHorizontal;
        content.alignment = UIStackViewAlignmentCenter;
        content.spacing = 18.0;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:content];
        YTKACEApplyGlassBackground(banner, YES);
        [presenter.view addSubview:banner];
        UILayoutGuide *safe = presenter.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-54.0],
            [banner.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-28.0],
            [content.topAnchor constraintEqualToAnchor:banner.topAnchor constant:11.0],
            [content.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16.0],
            [content.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
            [content.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-11.0]
        ]];
        target.controller = controller;
        target.startTime = start;
        target.endTime = end;
        target.segmentIndex = segmentIndex;
        target.banner = banner;
        banner.alpha = 0.0;
        banner.transform = CGAffineTransformMakeScale(0.96, 0.96);
        [UIView animateWithDuration:0.25 delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            banner.alpha = 1.0;
            banner.transform = CGAffineTransformIdentity;
        } completion:nil];
        NSTimeInterval duration = notificationMode == 0
            ? YTKACESponsorUnskipAlertDuration()
            : YTKACESponsorSkipAlertDuration();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(duration * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (target.banner == banner) {
                    YTKACEFadeOutSponsorBanner(banner);
                }
            });
    });
}

static void YTKACEPerformSponsorSkip(id controller, double start, double end,
                                     NSUInteger segmentIndex, NSString *category) {
    YTKACESeekToTime(controller, end);
    YTKACEShowSponsorSkippedHUD(controller, start, end, segmentIndex, category);
    YTKACESponsorAddSkippedTime(MAX(0.0, end - start));
    if (YTKACESponsorFeedbackEnabled()) {
        AudioServicesPlaySystemSound(1057);
        UINotificationFeedbackGenerator *feedback =
            [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
}

@interface YTKACESponsorSkipTarget : NSObject
+ (instancetype)sharedTarget;
@property(nonatomic, weak) id controller;
@property(nonatomic, assign) double startTime;
@property(nonatomic, assign) double endTime;
@property(nonatomic, assign) NSUInteger segmentIndex;
@property(nonatomic, copy) NSString *category;
@property(nonatomic, weak) UIView *banner;
- (void)skip;
@end

@implementation YTKACESponsorSkipTarget
+ (instancetype)sharedTarget {
    static YTKACESponsorSkipTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACESponsorSkipTarget new]; });
    return target;
}
- (void)skip {
    id controller = self.controller;
    [self.banner removeFromSuperview];
    if (controller != nil) {
        YTKACEPerformSponsorSkip(controller, self.startTime, self.endTime,
                                 self.segmentIndex, self.category);
    }
}
@end

static void YTKACEAskToSkipSponsor(id controller, double start, double end,
                                   NSUInteger segmentIndex, NSString *category) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = YTKACETopController();
        if (presenter.view.window == nil) {
            return;
        }
        YTKACESponsorSkipTarget *target = YTKACESponsorSkipTarget.sharedTarget;
        [target.banner removeFromSuperview];
        UIView *banner = [UIView new];
        banner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        banner.layer.cornerRadius = 12.0;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *label = [UILabel new];
        label.text = [NSString stringWithFormat:@"%@ %@",
                      YTKACESponsorCategoryTitle(category),
                      YTKACELocalized(@"segment detected")];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        UIButton *skip = [UIButton buttonWithType:UIButtonTypeSystem];
        [skip setTitle:YTKACELocalized(@"Skip") forState:UIControlStateNormal];
        [skip setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
        skip.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [skip addTarget:target action:@selector(skip)
            forControlEvents:UIControlEventTouchUpInside];
        UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
            label, skip
        ]];
        content.axis = UILayoutConstraintAxisHorizontal;
        content.alignment = UIStackViewAlignmentCenter;
        content.spacing = 18.0;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:content];
        YTKACEApplyGlassBackground(banner, YES);
        [presenter.view addSubview:banner];
        UILayoutGuide *safe = presenter.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-54.0],
            [banner.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-28.0],
            [content.topAnchor constraintEqualToAnchor:banner.topAnchor constant:11.0],
            [content.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16.0],
            [content.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
            [content.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-11.0]
        ]];
        target.controller = controller;
        target.startTime = start;
        target.endTime = end;
        target.segmentIndex = segmentIndex;
        target.category = category;
        target.banner = banner;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(YTKACESponsorSkipAlertDuration() * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (target.banner == banner) {
                    [banner removeFromSuperview];
                }
            });
    });
}

static double YTKACETestSkipStart = -1.0;
static double YTKACETestSkipEnd = -1.0;

void YTKACESetTestSkip(double start, double end) {
    YTKACETestSkipStart = start;
    YTKACETestSkipEnd = end;
}

void YTKACESponsorUserDidManualSeek(void) {
    if ((CACurrentMediaTime() - YTKACELastUnskipTime) < 1.5) {
        return;
    }
    id controller = YTKACECurrentSponsorController;
    if (controller == nil) return;
    NSMutableSet<NSNumber *> *skipped =
        objc_getAssociatedObject(controller, YTKACESponsorSkippedAssociation);
    [skipped removeAllObjects];
    NSMutableSet<NSNumber *> *unskipped =
        objc_getAssociatedObject(controller, YTKACESponsorUnskippedAssociation);
    [unskipped removeAllObjects];
}

static void YTKACEOverlayScrubStart(id self, SEL _cmd, BOOL bar) {
    YTKACEUserIsScrubbing = YES;
    if (OriginalOverlayScrubStart != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalOverlayScrubStart)(self, _cmd, bar);
    }
}

static void YTKACEOverlayScrubEnd(id self, SEL _cmd, BOOL bar, BOOL cancelled, int source) {
    YTKACEUserIsScrubbing = NO;
    YTKACEWasScrubbing = NO;
    if (!cancelled) {
        YTKACESponsorUserDidManualSeek();
    }
    if (OriginalOverlayScrubEnd != NULL) {
        ((void (*)(id, SEL, BOOL, BOOL, int))OriginalOverlayScrubEnd)(self, _cmd, bar, cancelled, source);
    }
}

static void YTKACEPlayerBarDidBeginScrubbing(id self, SEL _cmd, id bar) {
    YTKACEUserIsScrubbing = YES;
    if (OriginalPlayerBarDidBeginScrubbing != NULL) {
        ((void (*)(id, SEL, id))OriginalPlayerBarDidBeginScrubbing)(self, _cmd, bar);
    }
}

static void YTKACEPlayerBarDidEndScrubbing(id self, SEL _cmd, id bar) {
    YTKACEUserIsScrubbing = NO;
    YTKACEWasScrubbing = NO;
    YTKACESponsorUserDidManualSeek();
    if (OriginalPlayerBarDidEndScrubbing != NULL) {
        ((void (*)(id, SEL, id))OriginalPlayerBarDidEndScrubbing)(self, _cmd, bar);
    }
}

static BOOL YTKACEIsScrubbing(id controller, UIView *barView) {
    if (YTKACEUserIsScrubbing) return YES;
    if (barView != nil) {
        for (NSString *sel in @[@"isScrubbing", @"scrubbing"]) {
            SEL s = NSSelectorFromString(sel);
            if ([barView respondsToSelector:s]) {
                if (((BOOL (*)(id, SEL))objc_msgSend)(barView, s)) return YES;
            }
        }
        for (NSString *childSel in @[@"playerBar", @"segmentablePlayerBar", @"modularPlayerBar"]) {
            id child = YTKACEObjectMessage(barView, childSel);
            if (child != nil) {
                for (NSString *sel in @[@"isScrubbing", @"scrubbing"]) {
                    SEL s = NSSelectorFromString(sel);
                    if ([child respondsToSelector:s]) {
                        if (((BOOL (*)(id, SEL))objc_msgSend)(child, s)) return YES;
                    }
                }
            }
        }
        for (UIGestureRecognizer *gr in barView.gestureRecognizers) {
            if ([gr isKindOfClass:UIPanGestureRecognizer.class] ||
                [gr isKindOfClass:UILongPressGestureRecognizer.class]) {
                if (gr.state == UIGestureRecognizerStateBegan ||
                    gr.state == UIGestureRecognizerStateChanged) {
                    return YES;
                }
            }
        }
    }
    if (controller != nil) {
        for (NSString *sel in @[@"isScrubbing", @"scrubbing"]) {
            SEL s = NSSelectorFromString(sel);
            if ([controller respondsToSelector:s]) {
                if (((BOOL (*)(id, SEL))objc_msgSend)(controller, s)) return YES;
            }
        }
        id overlay = YTKACEObjectMessage(controller, @"overlayViewController");
        if (overlay != nil) {
            for (NSString *sel in @[@"isScrubbing", @"scrubbing"]) {
                SEL s = NSSelectorFromString(sel);
                if ([overlay respondsToSelector:s]) {
                    if (((BOOL (*)(id, SEL))objc_msgSend)(overlay, s)) return YES;
                }
            }
        }
    }
    return NO;
}

static void YTKACEEvaluateSponsorTime(id controller, double time) {
    if (YTKACETestSkipStart >= 0.0 && YTKACETestSkipEnd > YTKACETestSkipStart) {
        if (time >= YTKACETestSkipStart && time < YTKACETestSkipEnd - 0.05) {
            double destination = YTKACETestSkipEnd;
            YTKACETestSkipStart = -1.0;
            YTKACETestSkipEnd = -1.0;
            YTKACESeekToTime(controller, destination);
            if (YTKACESponsorFeedbackEnabled()) {
                AudioServicesPlaySystemSound(1057);
            }
            YTKACEShowNotice(YTKACELocalized(@"Cut previewed"));
            return;
        }
    }

    if (!YTKACESponsorBlockEnabled()) {
        return;
    }

    if (YTKACEUserIsScrubbing || YTKACEIsScrubbing(controller, nil)) {
        YTKACEWasScrubbing = YES;
        return;
    }
    if (YTKACEWasScrubbing) {
        YTKACEWasScrubbing = NO;
        YTKACESponsorUserDidManualSeek();
    }

    NSArray<NSDictionary<NSString *, id> *> *segments =
        objc_getAssociatedObject(controller, YTKACESponsorSegmentsAssociation);
    if (segments.count == 0) {
        return;
    }

    if (YTKACESponsorWhitelistedChannels().count > 0) {
        NSString *channel = YTKACESponsorCurrentChannelTitle();
        if (channel.length > 0 && YTKACESponsorIsChannelWhitelisted(channel)) {
            return;
        }
    }
    NSMutableSet<NSNumber *> *skipped =
        objc_getAssociatedObject(controller, YTKACESponsorSkippedAssociation);
    if (skipped == nil) {
        skipped = [NSMutableSet set];
        objc_setAssociatedObject(controller,
                                 YTKACESponsorSkippedAssociation,
                                 skipped,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSMutableSet<NSNumber *> *unskipped =
        objc_getAssociatedObject(controller, YTKACESponsorUnskippedAssociation);
    if (unskipped == nil) {
        unskipped = [NSMutableSet set];
        objc_setAssociatedObject(controller,
                                 YTKACESponsorUnskippedAssociation,
                                 unskipped,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSTimeInterval sinceUnskip = CACurrentMediaTime() - YTKACELastUnskipTime;
    [segments enumerateObjectsUsingBlock:
        ^(NSDictionary<NSString *, id> *segment, NSUInteger index, BOOL *stop) {
            double start = [segment[@"start"] doubleValue];
            double end = [segment[@"end"] doubleValue];
            NSString *category = [segment[@"category"] isKindOfClass:NSString.class]
                ? segment[@"category"] : @"sponsor";
            NSString *actionType = [segment[@"actionType"] isKindOfClass:NSString.class]
                ? segment[@"actionType"] : @"skip";
            if ([category isEqualToString:@"poi_highlight"] ||
                [actionType isEqualToString:@"poi"] ||
                [actionType isEqualToString:@"full"]) {
                return;
            }
            NSInteger behavior = YTKACESponsorCategoryBehavior(category);
            if (behavior == 2 || behavior == 3) return;
            NSNumber *token = @(index);
            if ([unskipped containsObject:token]) {
                if (sinceUnskip > 4.0 && (time < start - 2.0 || time > end + 2.0)) {
                    [unskipped removeObject:token];
                    [skipped removeObject:token];
                }
                return;
            }
            if (sinceUnskip > 2.0 && (time < start - 1.0 || time > end + 1.0)) {
                [skipped removeObject:token];
            }
            if (time >= start && time < end - 0.25 && ![skipped containsObject:token]) {
                [skipped addObject:token];
                if (behavior == 1) {
                    YTKACEAskToSkipSponsor(controller, start, end, index, category);
                } else {
                    YTKACEPerformSponsorSkip(controller, start, end, index, category);
                }
                *stop = YES;
            }
        }];
}

static __weak id YTKACELastPlayerController;

void YTKACEPauseYouTubePlayer(void) {
    id controller = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    SEL pause = NSSelectorFromString(@"pause");
    if ([controller respondsToSelector:pause]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, pause);
    }
}

void YTKACEPlayYouTubePlayer(void) {
    id controller = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    SEL play = NSSelectorFromString(@"play");
    if ([controller respondsToSelector:play]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, play);
    }
}

NSString *YTKACESponsorCurrentVideoID(void) {
    id controller = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    if (controller == nil) return YTKACELastVideoID();
    NSString *videoID = objc_getAssociatedObject(controller, YTKACESponsorVideoAssociation);
    if (videoID.length != 0) return videoID;
    return YTKACEVideoIDFromObject(controller) ?: YTKACELastVideoID();
}

double YTKACESponsorCurrentTime(void) {
    id controller = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    if (controller == nil) return 0.0;
    return YTKACEDoubleMessage(controller, @[@"currentVideoMediaTime"]);
}

static id YTKACEFindVideoDetailsInObject(id obj, NSHashTable *visited, NSUInteger depth) {
    if (obj == nil || depth > 8 || [visited containsObject:obj]) return nil;
    if ([obj isKindOfClass:NSString.class] || [obj isKindOfClass:NSNumber.class] || [obj isKindOfClass:NSData.class]) return nil;
    [visited addObject:obj];

    id details = YTKACEObjectMessage(obj, @"videoDetails");
    if (details != nil) {
        if ([details respondsToSelector:NSSelectorFromString(@"shortDescription")] ||
            [details respondsToSelector:NSSelectorFromString(@"videoId")] ||
            [details respondsToSelector:NSSelectorFromString(@"author")]) {
            return details;
        }
    }

    for (NSString *sel in @[@"playerData", @"contentPlayerResponse", @"playerResponse",
                            @"playbackData", @"videoData", @"singleVideo",
                            @"activeVideo", @"contentVideo"]) {
        id child = YTKACEObjectMessage(obj, sel);
        id found = YTKACEFindVideoDetailsInObject(child, visited, depth + 1);
        if (found != nil) return found;
    }

    for (NSString *ivarName in @[@"_playerData", @"_playerResponse", @"_playbackData", @"_singleVideo"]) {
        id child = YTKACESafeObjectIvar(obj, ivarName.UTF8String);
        id found = YTKACEFindVideoDetailsInObject(child, visited, depth + 1);
        if (found != nil) return found;
    }

    return nil;
}

static NSArray *YTKACESponsorCandidateSources(void) {
    NSMutableArray *sources = [NSMutableArray array];
    id controller = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    if (controller != nil) {
        [sources addObject:controller];
        id playbackData = objc_getAssociatedObject(controller, YTKACESponsorPlaybackDataAssociation);
        if (playbackData != nil) [sources addObject:playbackData];
        id videoObj = objc_getAssociatedObject(controller, YTKACESponsorVideoObjectAssociation);
        if (videoObj != nil) [sources addObject:videoObj];
        for (NSString *overlaySel in @[@"activeVideoPlayerOverlay", @"contentVideoPlayerOverlay", @"overlayViewController"]) {
            id ov = YTKACEObjectMessage(controller, overlaySel);
            if (ov != nil) [sources addObject:ov];
        }
        id ovMgr = YTKACESafeObjectIvar(controller, "_overlayManager");
        if (ovMgr != nil) {
            id ov = YTKACEObjectMessage(ovMgr, @"contentVideoPlayerOverlay");
            if (ov != nil) [sources addObject:ov];
        }
    }
    if (YTKACELastOverlayController != nil) {
        [sources addObject:YTKACELastOverlayController];
    }
    if (YTKACELastPlayerBarController != nil) {
        [sources addObject:YTKACELastPlayerBarController];
    }
    for (UIView *bar in YTKACESponsorBars.allObjects) {
        id del = YTKACEObjectMessage(bar, @"delegate") ?: YTKACESafeObjectIvar(bar, "_delegate");
        if (del != nil) [sources addObject:del];
        UIResponder *resp = bar.nextResponder;
        for (NSUInteger d = 0; resp != nil && d < 12; d++) {
            if ([resp isKindOfClass:UIViewController.class]) {
                [sources addObject:resp];
            }
            resp = resp.nextResponder;
        }
    }
    NSString *videoID = YTKACESponsorCurrentVideoID();
    if (videoID.length > 0) {
        id cached = YTKACECachedPlayerResponse(videoID);
        if (cached != nil) [sources addObject:cached];
    }
    return sources;
}

static id YTKACESponsorCurrentVideoDetails(void) {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (id src in YTKACESponsorCandidateSources()) {
        id details = YTKACEFindVideoDetailsInObject(src, visited, 0);
        if (details != nil) return details;
    }
    return nil;
}

double YTKACESponsorCurrentDuration(void) {
    id controller = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    double dur = 0.0;
    if (controller != nil) {
        dur = YTKACEDoubleMessage(
            controller,
            @[@"currentVideoTotalMediaTime", @"currentVideoTotalTime",
              @"currentVideoDuration", @"totalMediaTime"]
        );
    }
    if (dur <= 0.0) {
        id details = YTKACESponsorCurrentVideoDetails();
        NSNumber *len = YTKACESafeNumberForKey(details, @"lengthSeconds");
        if (len != nil && [len doubleValue] > 0.0) {
            dur = [len doubleValue];
        }
    }
    return dur;
}

NSString *YTKACESponsorCurrentVideoTitle(void) {
    id controller = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    if (controller != nil) {
        for (NSString *sel in @[@"currentVideoTitle", @"videoTitle", @"title"]) {
            id val = YTKACEObjectMessage(controller, sel);
            if ([val isKindOfClass:NSString.class] && [val length] > 0) return val;
        }
    }
    id details = YTKACESponsorCurrentVideoDetails();
    if (details != nil) {
        for (NSString *sel in @[@"title", @"videoTitle"]) {
            id val = YTKACEObjectMessage(details, sel);
            if ([val isKindOfClass:NSString.class] && [val length] > 0) return val;
        }
    }
    return nil;
}

@implementation YTKACEVideoChapter

- (instancetype)initWithTitle:(NSString *)title startTime:(double)startTime endTime:(double)endTime {
    self = [super init];
    if (self) {
        _title = [title copy] ?: @"";
        _startTime = MAX(0.0, startTime);
        _endTime = MAX(_startTime, endTime);
    }
    return self;
}

- (double)duration {
    return MAX(0.0, self.endTime - self.startTime);
}

- (BOOL)isLikelySponsor {
    NSString *lower = self.title.lowercaseString;
    if (lower.length == 0) return NO;
    static NSArray<NSString *> *sponsorKeywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sponsorKeywords = @[
            @"sponsor", @"sponsorizzato", @"sponsored", @"partnership", @"advertisement",
            @"pubblicità", @"pubblicita", @"commercial", @"promo", @"codice sconto",
            @"nordvpn", @"surfshark", @"expressvpn", @"protonvpn", @"sharkvpn", @"incogni",
            @"aura", @"raycon", @"manscaped", @"betterhelp", @"hellofresh", @"casetify",
            @"squarespace", @"skillshare", @"audible", @"raid shadow", @"war thunder",
            @"world of warships", @"opera gx", @"honey", @"brilliant", @"ground news",
            @"factor", @"air up", @"airup", @"rhinoshield", @"ugreen", @"anker", @"dbrand",
            @"ridge", @"bespoke post", @"babbel", @"duolingo", @"cambly", @"saily",
            @"holafly", @"trade republic", @"scalable capital", @"revolut", @"satispay",
            @"eneba", @"instant gaming", @"g2a", @"kinguin"
        ];
    });
    for (NSString *kw in sponsorKeywords) {
        if ([lower containsString:kw]) return YES;
    }
    if ([lower containsString:@" ad "] || [lower hasPrefix:@"ad "] || [lower hasSuffix:@" ad"] || [lower isEqualToString:@"ad"] ||
        [lower containsString:@" adv "] || [lower hasPrefix:@"adv "] || [lower hasSuffix:@" adv"] || [lower isEqualToString:@"adv"]) {
        return YES;
    }
    return NO;
}

- (NSString *)suggestedCategory {
    if (self.isLikelySponsor) {
        return @"sponsor";
    }
    NSString *lower = self.title.lowercaseString;
    if ([lower containsString:@"merch"] ||
        [lower containsString:@"patreon"] ||
        [lower containsString:@"social"] ||
        [lower containsString:@"discord"] ||
        [lower containsString:@"subscribe"] ||
        [lower containsString:@"iscriviti"] ||
        [lower containsString:@"iscrizione"] ||
        [lower containsString:@"abbonati"] ||
        [lower containsString:@"follow"] ||
        [lower containsString:@"channel member"] ||
        [lower containsString:@"donation"] ||
        [lower containsString:@"donazioni"] ||
        [lower containsString:@"autopromozione"] ||
        [lower containsString:@"selfpromo"] ||
        [lower containsString:@"self-promo"]) {
        return @"selfpromo";
    }
    if ([lower containsString:@"reminder"] ||
        [lower containsString:@"like and sub"] ||
        [lower containsString:@"like & sub"] ||
        [lower containsString:@"lascia un like"] ||
        [lower containsString:@"metti like"] ||
        [lower containsString:@"campanella"] ||
        [lower containsString:@"bell"] ||
        [lower containsString:@"like the video"]) {
        return @"interaction";
    }
    if ([lower containsString:@"intro"] ||
        [lower containsString:@"introduzione"] ||
        [lower containsString:@"opening"] ||
        [lower containsString:@"start"] ||
        [lower containsString:@"beginning"] ||
        [lower containsString:@"inizio"] ||
        [lower containsString:@"prologo"] ||
        [lower containsString:@"sigla"]) {
        return @"intro";
    }
    if ([lower containsString:@"outro"] ||
        [lower containsString:@"ending"] ||
        [lower containsString:@"end screen"] ||
        [lower containsString:@"credits"] ||
        [lower containsString:@"titoli di coda"] ||
        [lower containsString:@"fine"] ||
        [lower containsString:@"conclusion"] ||
        [lower containsString:@"saluti"] ||
        [lower containsString:@"ringraziamenti"] ||
        [lower containsString:@"epilogo"]) {
        return @"outro";
    }
    if ([lower containsString:@"preview"] ||
        [lower containsString:@"anteprima"] ||
        [lower containsString:@"recap"] ||
        [lower containsString:@"riassunto"] ||
        [lower containsString:@"teaser"] ||
        [lower containsString:@"highlight"] ||
        [lower containsString:@"previously"] ||
        [lower containsString:@"in questo video"]) {
        return @"preview";
    }
    return @"sponsor";
}

@end

static NSString *YTKACEStringFromFormattedObject(id object) {
    if (object == nil) return nil;
    if ([object isKindOfClass:NSString.class]) return object;
    id simple = YTKACEObjectMessage(object, @"simpleText");
    if ([simple isKindOfClass:NSString.class] && [simple length] > 0) return simple;
    id text = YTKACEObjectMessage(object, @"text");
    if ([text isKindOfClass:NSString.class] && [text length] > 0) return text;
    id content = YTKACEObjectMessage(object, @"content");
    if ([content isKindOfClass:NSString.class] && [content length] > 0) return content;
    id runs = YTKACEObjectMessage(object, @"runs") ?: YTKACEObjectMessage(object, @"runsArray");
    if ([runs isKindOfClass:NSArray.class]) {
        NSMutableString *ms = [NSMutableString string];
        for (id run in runs) {
            id t = [run isKindOfClass:NSDictionary.class] ? run[@"text"] : YTKACEObjectMessage(run, @"text");
            if ([t isKindOfClass:NSString.class]) [ms appendString:t];
        }
        if (ms.length > 0) return ms;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)object;
        if ([dict[@"simpleText"] isKindOfClass:NSString.class]) return dict[@"simpleText"];
        if ([dict[@"text"] isKindOfClass:NSString.class]) return dict[@"text"];
        if ([dict[@"runs"] isKindOfClass:NSArray.class]) {
            NSMutableString *ms = [NSMutableString string];
            for (id run in (NSArray *)dict[@"runs"]) {
                if ([run isKindOfClass:NSDictionary.class] && [run[@"text"] isKindOfClass:NSString.class]) {
                    [ms appendString:run[@"text"]];
                }
            }
            if (ms.length > 0) return ms;
        }
    }
    id access = YTKACEObjectMessage(object, @"accessibility");
    if (access != nil) {
        id label = YTKACEObjectMessage(YTKACEObjectMessage(access, @"accessibilityData"), @"label");
        if ([label isKindOfClass:NSString.class] && [label length] > 0) return label;
    }
    return nil;
}

static void YTKACEExtractChaptersFromAnyObject(id obj,
                                               NSMutableArray<NSDictionary *> *foundMarkers,
                                               NSHashTable *visited,
                                               NSInteger depth) {
    if (obj == nil || depth > 12 || [visited containsObject:obj]) return;
    if ([obj isKindOfClass:NSString.class] ||
        [obj isKindOfClass:NSNumber.class] ||
        [obj isKindOfClass:NSValue.class] ||
        [obj isKindOfClass:NSData.class]) {
        return;
    }
    [visited addObject:obj];

    if ([obj isKindOfClass:NSArray.class] || [obj isKindOfClass:NSSet.class] || [obj isKindOfClass:NSOrderedSet.class]) {
        for (id item in (id<NSFastEnumeration>)obj) {
            YTKACEExtractChaptersFromAnyObject(item, foundMarkers, visited, depth + 1);
        }
        return;
    }

    // 1. Check Objective-C Chapter / Marker info objects with seconds (e.g., YTPlayerBarChapterInfo, YTTimelineMarker, YTPlayerBarTimestampMarkerInfo)
    if (![obj isKindOfClass:UIView.class] && ![obj isKindOfClass:UIViewController.class] && ![obj isKindOfClass:NSDictionary.class]) {
        NSNumber *startSecNum = YTKACESafeNumberForKey(obj, @"startTime")
                             ?: YTKACESafeNumberForKey(obj, @"visibleTimeRangeStartTime");
        if (startSecNum != nil && ([obj respondsToSelector:NSSelectorFromString(@"title")] ||
                                   [obj respondsToSelector:NSSelectorFromString(@"label")] ||
                                   [obj respondsToSelector:NSSelectorFromString(@"isGhostChapter")])) {
            double startSec = [startSecNum doubleValue];
            double endSec = 0.0;
            NSNumber *endSecNum = YTKACESafeNumberForKey(obj, @"endTime")
                               ?: YTKACESafeNumberForKey(obj, @"visibleTimeRangeEndTime");
            if (endSecNum != nil && [endSecNum doubleValue] > startSec) {
                endSec = [endSecNum doubleValue];
            } else {
                NSNumber *durSecNum = YTKACESafeNumberForKey(obj, @"duration");
                if (durSecNum != nil && [durSecNum doubleValue] > 0.0) {
                    endSec = startSec + [durSecNum doubleValue];
                }
            }
            id titleObj = YTKACEObjectMessage(obj, @"title")
                       ?: YTKACEObjectMessage(obj, @"label")
                       ?: YTKACESafeObjectIvar(obj, "_title")
                       ?: YTKACESafeObjectIvar(obj, "_label");
            NSString *titleStr = YTKACEStringFromFormattedObject(titleObj);
            if (titleStr.length == 0) {
                NSNumber *ghost = YTKACESafeNumberForKey(obj, @"isGhostChapter");
                if ([ghost boolValue] && endSec > startSec) {
                    titleStr = YTKACELocalized(@"Intro");
                }
            }
            if (isfinite(startSec) && startSec >= 0.0 && titleStr.length > 0) {
                [foundMarkers addObject:@{
                    @"title": titleStr,
                    @"start": @(startSec),
                    @"end": @(endSec > startSec ? endSec : 0.0)
                }];
                return;
            }
        }
    }

    // 2. Check Protobuf / Model / Dictionary objects with milliseconds (e.g., YTIChapterRenderer, YTMacroMarkerMessageModel, YTIMacroMarkerMessage)
    NSNumber *startMsNum = YTKACESafeNumberForKey(obj, @"timeRangeStartMillis")
                        ?: YTKACESafeNumberForKey(obj, @"startMillis")
                        ?: YTKACESafeNumberForKey(obj, @"displayStartMillis")
                        ?: YTKACESafeNumberForKey(obj, @"visibleTimeRangeStartMillis");
    if (startMsNum != nil) {
        double startSec = [startMsNum doubleValue] / 1000.0;
        double endSec = 0.0;
        NSNumber *endMsNum = YTKACESafeNumberForKey(obj, @"timeRangeEndMillis")
                          ?: YTKACESafeNumberForKey(obj, @"endMillis")
                          ?: YTKACESafeNumberForKey(obj, @"visibleTimeRangeEndMillis");
        if (endMsNum != nil && ([endMsNum doubleValue] / 1000.0) > startSec) {
            endSec = [endMsNum doubleValue] / 1000.0;
        } else {
            NSNumber *durMsNum = YTKACESafeNumberForKey(obj, @"durationMillis")
                              ?: YTKACESafeNumberForKey(obj, @"timeRangeDurationMillis");
            if (durMsNum != nil && [durMsNum doubleValue] > 0.0) {
                endSec = startSec + ([durMsNum doubleValue] / 1000.0);
            }
        }
        id titleObj = nil;
        if ([obj isKindOfClass:NSDictionary.class]) {
            titleObj = ((NSDictionary *)obj)[@"title"] ?: ((NSDictionary *)obj)[@"label"];
        } else {
            titleObj = YTKACEObjectMessage(obj, @"title")
                    ?: YTKACEObjectMessage(obj, @"label")
                    ?: YTKACESafeObjectIvar(obj, "_title")
                    ?: YTKACESafeObjectIvar(obj, "_label");
        }
        NSString *titleStr = YTKACEStringFromFormattedObject(titleObj);
        if (isfinite(startSec) && startSec >= 0.0 && titleStr.length > 0) {
            [foundMarkers addObject:@{
                @"title": titleStr,
                @"start": @(startSec),
                @"end": @(endSec > startSec ? endSec : 0.0)
            }];
            return;
        }
    }

    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)obj;
        NSNumber *dictStart = YTKACESafeNumberForKey(dict, @"startTime") ?: YTKACESafeNumberForKey(dict, @"start");
        if (dictStart != nil && (dict[@"title"] != nil || dict[@"label"] != nil)) {
            double startSec = [dictStart doubleValue];
            NSNumber *dictEnd = YTKACESafeNumberForKey(dict, @"endTime") ?: YTKACESafeNumberForKey(dict, @"end");
            double endSec = dictEnd != nil ? [dictEnd doubleValue] : 0.0;
            NSString *titleStr = YTKACEStringFromFormattedObject(dict[@"title"] ?: dict[@"label"]);
            if (isfinite(startSec) && startSec >= 0.0 && titleStr.length > 0) {
                [foundMarkers addObject:@{
                    @"title": titleStr,
                    @"start": @(startSec),
                    @"end": @(endSec > startSec ? endSec : 0.0)
                }];
                return;
            }
        }
        for (id child in dict.allValues) {
            YTKACEExtractChaptersFromAnyObject(child, foundMarkers, visited, depth + 1);
        }
        return;
    }

    NSArray<NSString *> *selectors = @[
        @"chapters", @"currentVisibleChapters", @"currentVisibleChaptersList",
        @"currentVisibleChaptersSet", @"currentVisibleMarkers", @"currentVisibleTimestampMarkersSet",
        @"currentVisibleTimestampMarkersList", @"timelineMarkers", @"timelineMarkersContainers",
        @"timestampMarkers", @"markers", @"markersArray", @"markersList", @"macroMarker",
        @"markersMap", @"markersMapArray", @"macroMarkersListRenderer", @"macroMarkersListEntity",
        @"macroMarkersListItemRenderer", @"chapterRenderer", @"decoratedPlayerBarRenderer",
        @"decoratedPlayerBarRendererExtension", @"playerBar", @"multiMarkersPlayerBarRenderer",
        @"chapteredPlayerBarRenderer", @"playerOverlays", @"playerOverlayRenderer", @"overlay",
        @"playerOverlayLayerRenderersArray", @"contents", @"contentsArray", @"engagementPanelsArray",
        @"engagementPanelSectionListRenderer", @"content", @"sectionListRenderer",
        @"itemSectionRenderer", @"frameworkUpdates", @"entityBatchUpdate", @"mutationsArray",
        @"payload", @"chaptersDecorationController", @"timestampMarkersDecorationController",
        @"playerData", @"contentPlayerResponse", @"playerResponse", @"watchNextResponse", @"protoBuf"
    ];
    for (NSString *selName in selectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([obj respondsToSelector:sel]) {
            id child = YTKACEObjectMessage(obj, selName);
            if (child != nil) {
                YTKACEExtractChaptersFromAnyObject(child, foundMarkers, visited, depth + 1);
            }
        }
    }

    const char *ivarNames[] = {
        "_chapters", "_chaptersToDisplay", "_chaptersForViews", "_lastDisplayedChapters",
        "_timestampMarkers", "_timelineMarkers", "_timelineMarkersContainers",
        "_markers", "_markersArray", "_markersList", "_macroMarker",
        "_currentVisibleChaptersSet", "_currentVisibleMarkers", "_currentVisibleTimestampMarkersSet",
        "_timelineMarkersMonitor", "_chaptersDecorationController", "_timestampMarkersDecorationController",
        "_playerOverlayRenderer", "_playerBarRenderer", "_watchNextResponse", "_protoBuf"
    };
    for (size_t i = 0; i < sizeof(ivarNames) / sizeof(ivarNames[0]); i++) {
        id child = YTKACESafeObjectIvar(obj, ivarNames[i]);
        if (child != nil) {
            YTKACEExtractChaptersFromAnyObject(child, foundMarkers, visited, depth + 1);
        }
    }
}

static NSString *YTKACECleanChapterTitle(NSString *raw) {
    if (raw.length == 0) return @"";
    static NSCharacterSet *trimSet;
    static NSRegularExpression *numPrefix;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *ms = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [ms addCharactersInString:@"[]()-–—:•*|·\t"];
        trimSet = [ms copy];
        numPrefix = [NSRegularExpression
            regularExpressionWithPattern:@"^(?:#?\\d+[.)]|[-•*])\\s*"
            options:0 error:nil];
    });
    NSString *cleaned = [raw stringByTrimmingCharactersInSet:trimSet];
    if (numPrefix != nil && cleaned.length > 0) {
        cleaned = [numPrefix stringByReplacingMatchesInString:cleaned
                                                      options:0
                                                        range:NSMakeRange(0, cleaned.length)
                                                 withTemplate:@""];
        cleaned = [cleaned stringByTrimmingCharactersInSet:trimSet];
    }
    return cleaned;
}

static NSArray<YTKACEVideoChapter *> *YTKACEBuildChaptersFromMarkers(NSArray<NSDictionary *> *markers, double duration) {
    if (markers.count == 0) return @[];
    NSArray<NSDictionary *> *sorted = [markers sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"start"] compare:b[@"start"]];
    }];

    NSMutableArray<NSDictionary *> *uniqueMarkers = [NSMutableArray array];
    for (NSDictionary *m in sorted) {
        if (uniqueMarkers.count == 0) {
            [uniqueMarkers addObject:m];
        } else {
            double prevStart = [uniqueMarkers.lastObject[@"start"] doubleValue];
            double currStart = [m[@"start"] doubleValue];
            if (currStart - prevStart > 0.5) {
                [uniqueMarkers addObject:m];
            } else if ([uniqueMarkers.lastObject[@"end"] doubleValue] <= prevStart &&
                       [m[@"end"] doubleValue] > currStart) {
                uniqueMarkers[uniqueMarkers.count - 1] = m;
            }
        }
    }

    if (uniqueMarkers.count == 1) {
        double start = [uniqueMarkers.firstObject[@"start"] doubleValue];
        double explicitEnd = [uniqueMarkers.firstObject[@"end"] doubleValue];
        if (explicitEnd <= start) {
            return @[];
        }
    }

    NSMutableArray<YTKACEVideoChapter *> *chapters = [NSMutableArray array];
    for (NSUInteger i = 0; i < uniqueMarkers.count; i++) {
        double start = [uniqueMarkers[i][@"start"] doubleValue];
        double explicitEnd = [uniqueMarkers[i][@"end"] doubleValue];
        double nextStart = (i + 1 < uniqueMarkers.count) ? [uniqueMarkers[i + 1][@"start"] doubleValue] : 0.0;
        double end = 0.0;
        if (explicitEnd > start && (nextStart <= start || explicitEnd <= nextStart + 0.5)) {
            end = explicitEnd;
        } else if (nextStart > start) {
            end = nextStart;
        } else if (duration > start) {
            end = duration;
        } else {
            end = start + 60.0;
        }
        if (end > start) {
            [chapters addObject:[[YTKACEVideoChapter alloc]
                initWithTitle:uniqueMarkers[i][@"title"] startTime:start endTime:end]];
        }
    }
    return chapters;
}

static NSArray<YTKACEVideoChapter *> *YTKACEParseChaptersFromDescription(NSString *desc, double duration) {
    if (desc.length == 0) return @[];
    NSRegularExpression *tsRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(?<![0-9:])(?:(\\d{1,2}):)?(\\d{1,2}):(\\d{2})(?!\\d)(?:\\s*[-–—/]\\s*(?:(\\d{1,2}):)?(\\d{1,2}):(\\d{2})(?!\\d))?"
        options:0 error:nil];
    if (tsRegex == nil) return @[];

    NSRegularExpression *urlRegex = [NSRegularExpression
        regularExpressionWithPattern:@"https?://\\S+"
        options:NSRegularExpressionCaseInsensitive error:nil];

    NSMutableArray<NSDictionary *> *parsed = [NSMutableArray array];
    NSArray<NSString *> *lines = [desc componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length < 4) continue;
        if (urlRegex != nil) {
            line = [urlRegex stringByReplacingMatchesInString:line options:0 range:NSMakeRange(0, line.length) withTemplate:@""];
        }
        NSArray<NSTextCheckingResult *> *matches = [tsRegex matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        if (matches.count == 0) continue;

        for (NSUInteger idx = 0; idx < matches.count; idx++) {
            NSTextCheckingResult *match = matches[idx];
            NSString *h1Str = [match rangeAtIndex:1].location != NSNotFound ? [line substringWithRange:[match rangeAtIndex:1]] : nil;
            NSString *m1Str = [match rangeAtIndex:2].location != NSNotFound ? [line substringWithRange:[match rangeAtIndex:2]] : nil;
            NSString *s1Str = [match rangeAtIndex:3].location != NSNotFound ? [line substringWithRange:[match rangeAtIndex:3]] : nil;
            if (m1Str.length == 0 || s1Str.length == 0) continue;

            double h1 = h1Str ? [h1Str doubleValue] : 0.0;
            double m1 = [m1Str doubleValue];
            double s1 = [s1Str doubleValue];
            if (s1 >= 60.0 || (h1Str != nil && m1 >= 60.0)) continue;
            double startSec = h1 * 3600.0 + m1 * 60.0 + s1;
            if (duration > 0.0 && startSec >= duration) continue;

            double endSec = 0.0;
            if ([match rangeAtIndex:5].location != NSNotFound && [match rangeAtIndex:6].location != NSNotFound) {
                NSString *h2Str = [match rangeAtIndex:4].location != NSNotFound ? [line substringWithRange:[match rangeAtIndex:4]] : nil;
                NSString *m2Str = [line substringWithRange:[match rangeAtIndex:5]];
                NSString *s2Str = [line substringWithRange:[match rangeAtIndex:6]];
                double h2 = h2Str ? [h2Str doubleValue] : 0.0;
                double m2 = [m2Str doubleValue];
                double s2 = [s2Str doubleValue];
                if (s2 < 60.0 && (h2Str == nil || m2 < 60.0)) {
                    double candidateEnd = h2 * 3600.0 + m2 * 60.0 + s2;
                    if (candidateEnd > startSec) {
                        endSec = candidateEnd;
                    }
                }
            }

            NSString *title = @"";
            if (matches.count == 1) {
                NSString *prefix = [line substringToIndex:match.range.location];
                NSString *suffix = [line substringFromIndex:NSMaxRange(match.range)];
                NSString *cleanSuffix = YTKACECleanChapterTitle(suffix);
                NSString *cleanPrefix = YTKACECleanChapterTitle(prefix);
                title = cleanSuffix.length > 0 ? cleanSuffix : cleanPrefix;
            } else {
                NSUInteger segStart = NSMaxRange(match.range);
                NSUInteger segEnd = (idx + 1 < matches.count) ? matches[idx + 1].range.location : line.length;
                if (segEnd > segStart) {
                    title = YTKACECleanChapterTitle([line substringWithRange:NSMakeRange(segStart, segEnd - segStart)]);
                }
                if (title.length == 0 && idx == 0 && match.range.location > 0) {
                    title = YTKACECleanChapterTitle([line substringToIndex:match.range.location]);
                }
            }

            if (title.length == 0) {
                title = YTKACELocalized(@"Chapter");
            }
            [parsed addObject:@{
                @"title": title,
                @"start": @(startSec),
                @"end": @(endSec)
            }];
        }
    }

    if (parsed.count == 0) return @[];
    [parsed sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"start"] compare:b[@"start"]];
    }];

    // Prepend an Intro chapter if multiple timestamps exist and the first starts after 5s
    if (parsed.count >= 2 && [parsed.firstObject[@"start"] doubleValue] >= 5.0) {
        double firstStart = [parsed.firstObject[@"start"] doubleValue];
        [parsed insertObject:@{
            @"title": YTKACELocalized(@"Intro"),
            @"start": @(0.0),
            @"end": @(firstStart)
        } atIndex:0];
    }

    return YTKACEBuildChaptersFromMarkers(parsed, duration);
}

NSString *YTKACESponsorCurrentVideoDescription(void) {
    id details = YTKACESponsorCurrentVideoDetails();
    if (details != nil) {
        for (NSString *sel in @[@"shortDescription", @"descriptionText", @"videoDescription", @"description"]) {
            id desc = YTKACEObjectMessage(details, sel);
            if ([desc isKindOfClass:NSString.class] && [desc length] > 0) {
                return desc;
            }
            NSString *formatted = YTKACEStringFromFormattedObject(desc);
            if (formatted.length > 0) return formatted;
        }
    }
    return nil;
}

NSArray<YTKACEVideoChapter *> *YTKACESponsorCurrentChapters(void) {
    double duration = YTKACESponsorCurrentDuration();
    NSMutableArray<NSDictionary *> *primaryMarkers = [NSMutableArray array];
    NSHashTable *visitedPrimary = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];

    // 1. Check direct player bar / overlay chapter arrays first (YTPlayerBarChapterInfo / YTTimelineMarker)
    if (YTKACELastReceivedChapters.count > 0) {
        YTKACEExtractChaptersFromAnyObject(YTKACELastReceivedChapters, primaryMarkers, visitedPrimary, 0);
    }
    if (YTKACELastMacroMarkersController != nil) {
        for (NSString *sel in @[@"currentVisibleChapters", @"currentVisibleChaptersList", @"currentVisibleChaptersSet", @"currentVisibleMarkers"]) {
            id obj = YTKACEObjectMessage(YTKACELastMacroMarkersController, sel);
            if (obj != nil) YTKACEExtractChaptersFromAnyObject(obj, primaryMarkers, visitedPrimary, 0);
        }
        for (NSString *ivar in @[@"_currentVisibleChaptersSet", @"_currentVisibleMarkers", @"_timelineMarkersMonitor"]) {
            id obj = YTKACESafeObjectIvar(YTKACELastMacroMarkersController, ivar.UTF8String);
            if (obj != nil) YTKACEExtractChaptersFromAnyObject(obj, primaryMarkers, visitedPrimary, 0);
        }
    }

    for (UIView *bar in YTKACESponsorBars.allObjects) {
        for (NSString *ivar in @[@"_chapters", @"_chaptersForViews", @"_lastDisplayedChapters", @"_lastDisplayedChapter"]) {
            id arr = YTKACESafeObjectIvar(bar, ivar.UTF8String);
            if (arr != nil) YTKACEExtractChaptersFromAnyObject(arr, primaryMarkers, visitedPrimary, 0);
        }
        id barDelegate = YTKACEObjectMessage(bar, @"delegate") ?: YTKACESafeObjectIvar(bar, "_delegate");
        if (barDelegate != nil) {
            id chs = YTKACEObjectMessage(barDelegate, @"chapters") ?: YTKACESafeObjectIvar(barDelegate, "_chapters");
            if (chs != nil) YTKACEExtractChaptersFromAnyObject(chs, primaryMarkers, visitedPrimary, 0);
            id deco = YTKACEObjectMessage(barDelegate, @"chaptersDecorationController") ?: YTKACESafeObjectIvar(barDelegate, "_chaptersDecorationController");
            if (deco != nil) YTKACEExtractChaptersFromAnyObject(deco, primaryMarkers, visitedPrimary, 0);
            id ov = YTKACESafeObjectIvar(barDelegate, "_delegate");
            if (ov != nil) {
                id ovChs = YTKACESafeObjectIvar(ov, "_chapters");
                if (ovChs != nil) YTKACEExtractChaptersFromAnyObject(ovChs, primaryMarkers, visitedPrimary, 0);
            }
        }
        UIResponder *resp = bar.nextResponder;
        for (NSUInteger d = 0; resp != nil && d < 12; d++) {
            id rChs = YTKACESafeObjectIvar(resp, "_chapters");
            if (rChs != nil) YTKACEExtractChaptersFromAnyObject(rChs, primaryMarkers, visitedPrimary, 0);
            resp = resp.nextResponder;
        }
        id modView = YTKACESafeObjectIvar(bar, "_playerBarView");
        if (modView != nil) {
            id modChs = YTKACESafeObjectIvar(modView, "_chapters") ?: YTKACESafeObjectIvar(modView, "_lastDisplayedChapters");
            if (modChs != nil) YTKACEExtractChaptersFromAnyObject(modChs, primaryMarkers, visitedPrimary, 0);
        }
        for (UIView *sub in bar.subviews) {
            id subChs = YTKACESafeObjectIvar(sub, "_chapters") ?: YTKACESafeObjectIvar(sub, "_lastDisplayedChapters");
            if (subChs != nil) YTKACEExtractChaptersFromAnyObject(subChs, primaryMarkers, visitedPrimary, 0);
        }
    }

    if (YTKACELastPlayerBarController != nil) {
        id chs = YTKACEObjectMessage(YTKACELastPlayerBarController, @"chapters") ?: YTKACESafeObjectIvar(YTKACELastPlayerBarController, "_chapters");
        if (chs != nil) YTKACEExtractChaptersFromAnyObject(chs, primaryMarkers, visitedPrimary, 0);
        id deco = YTKACEObjectMessage(YTKACELastPlayerBarController, @"chaptersDecorationController") ?: YTKACESafeObjectIvar(YTKACELastPlayerBarController, "_chaptersDecorationController");
        if (deco != nil) YTKACEExtractChaptersFromAnyObject(deco, primaryMarkers, visitedPrimary, 0);
    }

    if (YTKACELastOverlayController != nil) {
        id ovChs = YTKACESafeObjectIvar(YTKACELastOverlayController, "_chapters");
        if (ovChs != nil) YTKACEExtractChaptersFromAnyObject(ovChs, primaryMarkers, visitedPrimary, 0);
    }

    NSArray<YTKACEVideoChapter *> *chapters = YTKACEBuildChaptersFromMarkers(primaryMarkers, duration);
    if (chapters.count > 0) {
        return chapters;
    }

    // 2. Fallback to broader object graph traversal (timestampMarkers, watchNextResponse, playerResponse, playbackData)
    NSMutableArray<NSDictionary *> *secondaryMarkers = [NSMutableArray array];
    NSHashTable *visitedSecondary = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (id src in YTKACESponsorCandidateSources()) {
        YTKACEExtractChaptersFromAnyObject(src, secondaryMarkers, visitedSecondary, 0);
    }
    for (UIView *bar in YTKACESponsorBars.allObjects) {
        YTKACEExtractChaptersFromAnyObject(bar, secondaryMarkers, visitedSecondary, 0);
    }
    chapters = YTKACEBuildChaptersFromMarkers(secondaryMarkers, duration);
    if (chapters.count > 0) {
        return chapters;
    }

    // 3. Fallback to parsing video description timestamps
    NSString *desc = YTKACESponsorCurrentVideoDescription();
    NSArray<YTKACEVideoChapter *> *descChapters = YTKACEParseChaptersFromDescription(desc, duration);
    if (descChapters.count > 0) {
        return descChapters;
    }

    return @[];
}

NSString *YTKACESponsorCurrentChannelTitle(void) {
    id controller = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    if (controller != nil) {
        NSString *cached = objc_getAssociatedObject(controller, YTKACESponsorChannelAssociation);
        if (cached != nil) return cached.length > 0 ? cached : nil;
    }
    id details = YTKACESponsorCurrentVideoDetails();
    if (details != nil) {
        for (NSString *sel in @[@"author", @"channelTitle", @"ownerChannelName", @"creator"]) {
            id val = YTKACEObjectMessage(details, sel);
            if ([val isKindOfClass:NSString.class] && [val length] > 0) {
                if (controller != nil) {
                    objc_setAssociatedObject(controller,
                                             YTKACESponsorChannelAssociation,
                                             val,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                return val;
            }
        }
    }
    if (controller != nil) {
        objc_setAssociatedObject(controller,
                                 YTKACESponsorChannelAssociation,
                                 @"",
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return nil;
}

NSArray<NSDictionary<NSString *, id> *> *YTKACESponsorCurrentSegments(void) {
    id controller = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    if (controller == nil) return @[];
    NSArray *segments = objc_getAssociatedObject(controller, YTKACESponsorSegmentsAssociation);
    return [segments isKindOfClass:NSArray.class] ? segments : @[];
}

void YTKACESponsorSeek(double time) {
    id controller = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    if (controller != nil) {
        YTKACESeekToTime(controller, time);
    }
}

void YTKACESponsorRefreshCurrentVideo(void) {
    id receiver = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    if (receiver == nil) return;
    NSString *videoID = objc_getAssociatedObject(receiver, YTKACESponsorVideoAssociation)
                     ?: YTKACEVideoIDFromObject(receiver)
                     ?: YTKACELastVideoID();
    if (videoID.length == 0) return;

    [YTKACESponsorClient.sharedClient clearCache];

    __weak id weakReceiver = receiver;
    [YTKACESponsorClient.sharedClient segmentsForVideoID:videoID
                                             completion:^(NSArray *segments) {
        id strongReceiver = weakReceiver;
        if (strongReceiver == nil) return;
        objc_setAssociatedObject(strongReceiver,
                                 YTKACESponsorSegmentsAssociation,
                                 segments,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(strongReceiver,
                                 YTKACESponsorSkippedAssociation,
                                 [NSMutableSet set],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(strongReceiver,
                                 YTKACESponsorUnskippedAssociation,
                                 [NSMutableSet set],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (UIView *bar in YTKACESponsorBars.allObjects) {
            [bar setNeedsLayout];
            [bar layoutIfNeeded];
            YTKACEUpdatePlayerBarDuration(bar);
        }
    }];
}

static void YTKACEDidActivateVideo(id receiver,
                                   SEL selector,
                                   id playbackController,
                                   id video,
                                   id playbackData) {
    if (OriginalDidActivateVideo != NULL) {
        ((void (*)(id, SEL, id, id, id))OriginalDidActivateVideo)(
            receiver, selector, playbackController, video, playbackData
        );
    }

    YTKACEOpenPausedVideoActivated(receiver);
    YTKACELastPlayerController = receiver;

    if (!YTKACESponsorBlockEnabled()) {
        objc_setAssociatedObject(receiver,
                                 YTKACESponsorSegmentsAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    NSString *videoID =
        YTKACEVideoIDFromObject(receiver) ?:
        YTKACEVideoIDFromObject(video) ?:
        YTKACEVideoIDFromObject(playbackData);
    if (videoID.length == 0) {
        return;
    }

    objc_setAssociatedObject(receiver,
                             YTKACESponsorVideoAssociation,
                             videoID,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTKACESponsorPlaybackDataAssociation,
                             playbackData,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTKACESponsorVideoObjectAssociation,
                             video,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTKACESponsorChannelAssociation,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![YTKACELastChaptersVideoID isEqualToString:videoID]) {
        YTKACELastReceivedChapters = nil;
        YTKACELastChaptersVideoID = videoID;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"YTKACESponsorVideoDidActivate"
                                                      object:nil
                                                    userInfo:@{@"videoID": videoID}];
    objc_setAssociatedObject(receiver,
                             YTKACESponsorSegmentsAssociation,
                             @[],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTKACESponsorSkippedAssociation,
                             [NSMutableSet set],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTKACESponsorUnskippedAssociation,
                             [NSMutableSet set],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACECurrentSponsorController = receiver;

    __weak id weakReceiver = receiver;
    [YTKACESponsorClient.sharedClient segmentsForVideoID:videoID
                                             completion:^(NSArray *segments) {
        id strongReceiver = weakReceiver;
        NSString *current =
            objc_getAssociatedObject(strongReceiver, YTKACESponsorVideoAssociation);
        if (strongReceiver == nil || ![current isEqualToString:videoID]) {
            return;
        }
        objc_setAssociatedObject(strongReceiver,
                                 YTKACESponsorSegmentsAssociation,
                                 segments,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (YTKACESponsorNotificationMode() != 2) {
            NSString *channel = YTKACESponsorCurrentChannelTitle();
            if (channel.length == 0 || !YTKACESponsorIsChannelWhitelisted(channel)) {
                for (NSDictionary *seg in segments) {
                    if ([seg[@"actionType"] isKindOfClass:NSString.class] &&
                        [seg[@"actionType"] isEqualToString:@"full"]) {
                        NSString *cat = [seg[@"category"] isKindOfClass:NSString.class]
                            ? seg[@"category"] : @"sponsor";
                        if (YTKACESponsorCategoryBehavior(cat) != 2) {
                            YTKACEShowNotice([NSString stringWithFormat:@"%@: %@",
                                              YTKACELocalized(@"Full Video"),
                                              YTKACESponsorCategoryTitle(cat)]);
                            break;
                        }
                    }
                }
            }
        }
        for (UIView *bar in YTKACESponsorBars.allObjects) {
            [bar setNeedsLayout];
            [bar layoutIfNeeded];
            YTKACEUpdatePlayerBarDuration(bar);
        }
    }];
}

static void YTKACESingleVideoTimeChanged(id receiver,
                                         SEL selector,
                                         id video,
                                         id videoTime) {
    if (OriginalSingleVideoTimeChanged != NULL) {
        ((void (*)(id, SEL, id, id))OriginalSingleVideoTimeChanged)(
            receiver, selector, video, videoTime
        );
    }
    double objTime = YTKACEDoubleMessage(videoTime, @[@"time"]);
    double current = YTKACEDoubleMessage(receiver, @[@"currentVideoMediaTime"]);
    double resolved = current > 0.0 ? current : objTime;
    double duration = YTKACEDoubleMessage(video, @[@"totalMediaTime", @"duration"]);
    if (duration <= 0.0) {
        duration = YTKACEDoubleMessage(receiver, @[
            @"currentVideoTotalMediaTime",
            @"currentVideoTotalTime",
            @"currentVideoDuration",
            @"totalMediaTime"
        ]);
    }
    if (YTKACESponsorTimeUpdatesEnabled) {
        YTKACEEvaluateSponsorTime(receiver, resolved);
    }
    if (YTKACESponsorShowTimeWithSkipsEnabled() && !YTKACEUserIsScrubbing && !YTKACEIsScrubbing(receiver, nil)) {
        for (UIView *bar in YTKACESponsorBars.allObjects) {
            YTKACEUpdatePlayerBarDuration(bar);
        }
    }
    YTKACEPublishPlaybackTime(receiver, resolved, duration);
}

static void YTKACEMutatedVideoTimeChanged(id receiver,
                                          SEL selector,
                                          id video,
                                          id videoTime) {
    if (OriginalMutatedVideoTimeChanged != NULL) {
        ((void (*)(id, SEL, id, id))OriginalMutatedVideoTimeChanged)(
            receiver, selector, video, videoTime
        );
    }
    double objTime = YTKACEDoubleMessage(videoTime, @[@"time"]);
    double current = YTKACEDoubleMessage(receiver, @[@"currentVideoMediaTime"]);
    double resolved = current > 0.0 ? current : objTime;
    double duration = YTKACEDoubleMessage(video, @[@"totalMediaTime", @"duration"]);
    if (duration <= 0.0) {
        duration = YTKACEDoubleMessage(receiver, @[
            @"currentVideoTotalMediaTime",
            @"currentVideoTotalTime",
            @"currentVideoDuration",
            @"totalMediaTime"
        ]);
    }
    if (YTKACESponsorTimeUpdatesEnabled) {
        YTKACEEvaluateSponsorTime(receiver, resolved);
    }
    if (YTKACESponsorShowTimeWithSkipsEnabled() && !YTKACEUserIsScrubbing && !YTKACEIsScrubbing(receiver, nil)) {
        for (UIView *bar in YTKACESponsorBars.allObjects) {
            YTKACEUpdatePlayerBarDuration(bar);
        }
    }
    YTKACEPublishPlaybackTime(receiver, resolved, duration);
}

static BOOL YTKACETrackGeometry(UIView *target, CGFloat *thickness,
                                CGFloat *offset) {
    CGFloat width = CGRectGetWidth(target.bounds);
    if (width <= 0.0) return NO;
    CGFloat bestWidth = 0.0;
    CGFloat bestHeight = 0.0;
    CGFloat bestY = 0.0;
    BOOL found = NO;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:target];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 60) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        if (node != target && !node.hidden && node.alpha > 0.05) {
            CGRect frame = [node convertRect:node.bounds toView:target];
            CGFloat nodeWidth = CGRectGetWidth(frame);
            CGFloat nodeHeight = CGRectGetHeight(frame);
            if (nodeWidth >= width * 0.55 && nodeHeight > 0.5 && nodeHeight <= 16.0) {
                BOOL better = !found;
                if (!better && nodeWidth > bestWidth + 2.0) better = YES;
                else if (!better && nodeWidth >= bestWidth - 2.0) {
                    if (CGRectGetMinY(frame) > bestY + 0.5) better = YES;
                    else if (fabs(CGRectGetMinY(frame) - bestY) <= 0.5 &&
                             nodeHeight > bestHeight) better = YES;
                }
                if (better) {
                    bestWidth = nodeWidth;
                    bestHeight = nodeHeight;
                    bestY = CGRectGetMinY(frame);
                    found = YES;
                }
            }
        }
        [pending addObjectsFromArray:node.subviews];
    }
    if (!found) return NO;
    *thickness = bestHeight;
    *offset = bestY;
    return YES;
}

static void YTKACERenderSponsorMarkers(UIView *receiver, UIView *target,
                                       BOOL fullHeight) {
    CAShapeLayer *container =
        objc_getAssociatedObject(receiver, YTKACESponsorMarkerAssociation);
    if (container == nil) {
        container = [CAShapeLayer layer];
        container.name = @"YTKACESponsorMarkers";
        objc_setAssociatedObject(receiver,
                                 YTKACESponsorMarkerAssociation,
                                 container,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL reattached = NO;
    if (container.superlayer != target.layer) {
        [container removeFromSuperlayer];
        [target.layer addSublayer:container];
        reattached = YES;
    }
    container.frame = target.bounds;
    container.zPosition = 10000.0;

    id controller = YTKACECurrentSponsorController;
    NSArray<NSDictionary<NSString *, id> *> *segments =
        objc_getAssociatedObject(controller, YTKACESponsorSegmentsAssociation);
    double duration = YTKACEDoubleMessage(
        controller,
        @[@"currentVideoTotalMediaTime", @"currentVideoTotalTime",
          @"currentVideoDuration", @"totalMediaTime"]
    );
    BOOL enabled = YTKACESponsorBlockEnabled() && isfinite(duration) && duration > 0.0 && segments.count != 0;
    container.hidden = !enabled;
    if (!enabled) return;

    CGFloat width = CGRectGetWidth(target.bounds);
    CGFloat height = CGRectGetHeight(target.bounds);
    if (!isfinite(width) || width <= 0.0 || !isfinite(height) || height <= 0.0) return;

    NSArray *renderedSegments = objc_getAssociatedObject(
        receiver, YTKACESponsorRenderedSegmentsAssociation);
    BOOL rebuild = renderedSegments != segments || container.sublayers.count != segments.count;
    if (rebuild) {
        [container.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
        for (NSDictionary<NSString *, id> *segment in segments) {
            CALayer *marker = [CALayer layer];
            NSString *category = [segment[@"category"] isKindOfClass:NSString.class]
                ? segment[@"category"] : @"sponsor";
            marker.backgroundColor = YTKACESponsorCategoryColor(category).CGColor;
            marker.zPosition = 1.0;
            [container addSublayer:marker];
        }
        objc_setAssociatedObject(receiver,
                                 YTKACESponsorRenderedSegmentsAssociation,
                                 segments,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat trackThickness = 2.0;
    CGFloat trackOffset = MAX(0.0, height - 2.0);
    if (!fullHeight) {
        CGFloat measured = 0.0;
        CGFloat measuredOffset = 0.0;
        if (YTKACETrackGeometry(target, &measured, &measuredOffset)) {
            trackThickness = measured;
            trackOffset = measuredOffset;
        }
    }
    objc_setAssociatedObject(receiver,
                             YTKACESponsorMarkerBoundsAssociation,
                             [NSValue valueWithCGRect:CGRectMake(width, height, trackThickness, trackOffset)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTKACESponsorMarkerDurationAssociation,
                             @(duration),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSArray<CALayer *> *sublayers = [container.sublayers copy];
    [segments enumerateObjectsUsingBlock:
        ^(NSDictionary<NSString *, id> *segment, NSUInteger index, __unused BOOL *stop) {
        if (index >= sublayers.count) return;
        CALayer *marker = sublayers[index];
        NSString *category = [segment[@"category"] isKindOfClass:NSString.class]
            ? segment[@"category"] : @"sponsor";
        NSString *actionType = [segment[@"actionType"] isKindOfClass:NSString.class]
            ? segment[@"actionType"] : @"skip";
        if ([actionType isEqualToString:@"full"] ||
            YTKACESponsorCategoryBehavior(category) == 2) {
            marker.hidden = YES;
            return;
        }
        marker.backgroundColor = YTKACESponsorCategoryColor(category).CGColor;

        double start = [segment[@"start"] doubleValue];
        double end = MIN([segment[@"end"] doubleValue], duration);
        BOOL isPOI = [category isEqualToString:@"poi_highlight"] ||
                     [actionType isEqualToString:@"poi"];
        if (!isfinite(start) || !isfinite(end) || start < 0.0 || start > duration ||
            (!isPOI && end <= start)) {
            marker.hidden = YES;
            return;
        }
        marker.hidden = NO;
        CGFloat markerHeight = fullHeight ? MAX(height, 1.0) : trackThickness;
        CGFloat markerX = (CGFloat)(start / duration) * width;
        CGFloat markerW = isPOI
            ? 4.0
            : MAX(1.5, (CGFloat)((end - start) / duration) * width);
        if (isPOI && markerX + markerW > width) {
            markerX = MAX(0.0, width - markerW);
        }
        if (!isfinite(markerX) || !isfinite(markerW) || !isfinite(markerHeight) || !isfinite(trackOffset)) return;
        marker.frame = CGRectMake(markerX,
                                  fullHeight ? 0.0 : trackOffset,
                                  markerW,
                                  markerHeight);
    }];
    [CATransaction commit];
}

static NSString *YTKACEFormatTimeDuration(double seconds, BOOL forceHours) {
    if (!isfinite(seconds) || seconds < 0.0) seconds = 0.0;
    NSInteger total = (NSInteger)lround(seconds);
    NSInteger s = total % 60;
    NSInteger m = (total / 60) % 60;
    NSInteger h = total / 3600;
    if (forceHours || h > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)m, (long)s];
}

static double YTKACEParseSecondsFromTimeString(NSString *str) {
    if (str.length == 0) return -1.0;
    NSCharacterSet *trim = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *cleaned = [str stringByTrimmingCharactersInSet:trim];
    if ([cleaned hasPrefix:@"-"] || [cleaned hasPrefix:@"–"]) {
        cleaned = [cleaned substringFromIndex:1];
    }
    NSArray<NSString *> *parts = [cleaned componentsSeparatedByString:@":"];
    if (parts.count < 2 || parts.count > 3) return -1.0;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    for (NSString *part in parts) {
        NSString *trimmedPart = [part stringByTrimmingCharactersInSet:trim];
        if (trimmedPart.length == 0) return -1.0;
        if ([trimmedPart rangeOfCharacterFromSet:[digits invertedSet]].location != NSNotFound) {
            return -1.0;
        }
    }
    if (parts.count == 2) {
        return [parts[0] doubleValue] * 60.0 + [parts[1] doubleValue];
    } else if (parts.count == 3) {
        return [parts[0] doubleValue] * 3600.0 + [parts[1] doubleValue] * 60.0 + [parts[2] doubleValue];
    }
    return -1.0;
}

static NSString *YTKACEFindCompoundSeparator(NSString *text) {
    if (text.length == 0) return nil;
    NSArray<NSString *> *separators = @[@" / ", @" • ", @" · ", @" - ", @" – ", @" — ", @"/", @"-"];
    for (NSString *sep in separators) {
        NSRange r = [text rangeOfString:sep];
        if (r.location != NSNotFound) {
            NSString *left = [text substringToIndex:r.location];
            NSString *right = [text substringFromIndex:r.location + r.length];
            if ([left containsString:@":"] && [right containsString:@":"]) {
                return sep;
            }
        }
    }
    return nil;
}

static BOOL YTKACEIsExcludedTimeView(UIView *view) {
    if (view == nil) return YES;
    NSString *cls = NSStringFromClass(view.class).lowercaseString;
    if ([cls containsString:@"preview"] ||
        [cls containsString:@"scrub"] ||
        [cls containsString:@"chapter"] ||
        [cls containsString:@"tooltip"] ||
        [cls containsString:@"badge"] ||
        [cls containsString:@"seek"] ||
        [cls containsString:@"speed"] ||
        [cls containsString:@"button"]) {
        return YES;
    }
    NSString *ident = view.accessibilityIdentifier.lowercaseString ?: @"";
    if ([ident containsString:@"preview"] ||
        [ident containsString:@"scrub"] ||
        [ident containsString:@"chapter"] ||
        [ident containsString:@"tooltip"] ||
        [ident containsString:@"badge"] ||
        [ident containsString:@"seek"] ||
        [ident containsString:@"current"] ||
        [ident containsString:@"elapsed"]) {
        return YES;
    }
    return NO;
}

static BOOL YTKACEHasExcludedAncestor(UIView *view, UIView *root) {
    UIView *p = view;
    while (p != nil && p != root) {
        if (YTKACEIsExcludedTimeView(p)) return YES;
        p = p.superview;
    }
    return NO;
}

static BOOL YTKACEIsValidTimeString(NSString *str) {
    if (str.length < 3 || str.length > 30) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789: -–/·•()"];
    if ([str rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound) {
        return NO;
    }
    return [str containsString:@":"];
}

static void YTKACECollectTimeLabelsFromView(UIView *view,
                                            NSMutableSet<UILabel *> *currentLabels,
                                            NSMutableSet<UILabel *> *durationLabels) {
    if (view == nil) return;
    for (NSString *sel in @[@"currentTimeLabel", @"elapsedTimeLabel", @"currentMediaTimeLabel"]) {
        id obj = YTKACEObjectMessage(view, sel);
        if ([obj isKindOfClass:UILabel.class]) [currentLabels addObject:(UILabel *)obj];
    }
    id timeObj = YTKACEObjectMessage(view, @"timeLabel");
    if ([timeObj isKindOfClass:UILabel.class]) {
        UILabel *lbl = (UILabel *)timeObj;
        if (YTKACEFindCompoundSeparator(lbl.text) != nil) {
            [durationLabels addObject:lbl];
        } else {
            [currentLabels addObject:lbl];
        }
    }
    for (NSString *sel in @[@"durationLabel", @"totalTimeLabel", @"remainingTimeLabel"]) {
        id obj = YTKACEObjectMessage(view, sel);
        if ([obj isKindOfClass:UILabel.class]) [durationLabels addObject:(UILabel *)obj];
    }
}

static NSArray<UILabel *> *YTKACEDurationLabelsInBar(UIView *barView, NSMutableSet<UILabel *> *outCurrentLabels) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    if (barView == nil) return labels;

    NSMutableSet<UILabel *> *knownCurrentLabels = outCurrentLabels ?: [NSMutableSet set];
    NSMutableSet<UILabel *> *knownDurationLabels = [NSMutableSet set];

    YTKACECollectTimeLabelsFromView(barView, knownCurrentLabels, knownDurationLabels);
    for (NSString *childSel in @[@"playerBar", @"segmentablePlayerBar", @"modularPlayerBar", @"timeStatusView", @"inlinePlayerBarView"]) {
        id child = YTKACEObjectMessage(barView, childSel);
        if ([child isKindOfClass:UIView.class]) {
            YTKACECollectTimeLabelsFromView((UIView *)child, knownCurrentLabels, knownDurationLabels);
        }
    }

    [knownDurationLabels minusSet:knownCurrentLabels];
    NSMutableSet<UILabel *> *filteredDurationLabels = [NSMutableSet set];
    for (UILabel *lbl in knownDurationLabels) {
        if (!YTKACEHasExcludedAncestor(lbl, barView)) {
            [filteredDurationLabels addObject:lbl];
        }
    }
    if (filteredDurationLabels.count > 0) {
        return filteredDurationLabels.allObjects;
    }

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:barView];
    NSMutableArray<UILabel *> *candidates = [NSMutableArray array];
    while (queue.count != 0) {
        UIView *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (YTKACEIsExcludedTimeView(node)) {
            continue;
        }
        if ([node isKindOfClass:UILabel.class]) {
            UILabel *lbl = (UILabel *)node;
            if (![knownCurrentLabels containsObject:lbl] && !YTKACEHasExcludedAncestor(lbl, barView)) {
                NSString *txt = lbl.text;
                if (YTKACEIsValidTimeString(txt)) {
                    [candidates addObject:lbl];
                }
            }
        }
        [queue addObjectsFromArray:node.subviews];
    }

    if (candidates.count == 0) return labels;

    for (UILabel *cand in candidates) {
        if (YTKACEFindCompoundSeparator(cand.text) != nil) {
            [labels addObject:cand];
        }
    }
    if (labels.count > 0) return labels;

    if (candidates.count > 1) {
        [candidates sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
            CGRect fa = [a convertRect:a.bounds toView:barView];
            CGRect fb = [b convertRect:b.bounds toView:barView];
            if (CGRectGetMinX(fa) < CGRectGetMinX(fb)) return NSOrderedAscending;
            if (CGRectGetMinX(fa) > CGRectGetMinX(fb)) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        [knownCurrentLabels addObject:candidates.firstObject];
        [labels addObject:candidates.lastObject];
    } else if (candidates.count == 1) {
        UILabel *cand = candidates.firstObject;
        if (YTKACEFindCompoundSeparator(cand.text) != nil ||
            [cand.text hasPrefix:@"-"] || [cand.text hasPrefix:@"–"] ||
            objc_getAssociatedObject(cand, YTKACEOptionsOriginalDurationTextKey) != nil) {
            [labels addObject:cand];
        }
    }

    return labels;
}

static const void *YTKACEOptionsOriginalSepHiddenKey = &YTKACEOptionsOriginalSepHiddenKey;

static void YTKACEUpdatePlayerBarDuration(UIView *barView) {
    if (barView == nil) return;
    id controller = YTKACECurrentSponsorController ?: YTKACELastPlayerController;
    if (YTKACEUserIsScrubbing || YTKACEIsScrubbing(controller, barView)) {
        return;
    }

    NSMutableSet<UILabel *> *currentLabels = [NSMutableSet set];
    NSArray<UILabel *> *labels = YTKACEDurationLabelsInBar(barView, currentLabels);
    if (labels.count == 0) return;

    double duration = 0.0;
    double current = 0.0;
    if (controller != nil) {
        duration = YTKACEDoubleMessage(
            controller,
            @[@"currentVideoTotalMediaTime", @"currentVideoTotalTime",
              @"currentVideoDuration", @"totalMediaTime"]
        );
        current = YTKACEDoubleMessage(
            controller,
            @[@"currentVideoMediaTime", @"currentMediaTime"]
        );
    }
    if (!isfinite(duration) || duration <= 0.0) return;
    if (!isfinite(current) || current < 0.0) current = 0.0;

    NSArray *rawSegments = controller != nil ? objc_getAssociatedObject(controller, YTKACESponsorSegmentsAssociation) : nil;
    NSSet<NSNumber *> *unskipped = controller != nil ? objc_getAssociatedObject(controller, YTKACESponsorUnskippedAssociation) : nil;
    NSMutableArray<NSDictionary *> *segments = [NSMutableArray arrayWithCapacity:rawSegments.count];
    [rawSegments enumerateObjectsUsingBlock:^(NSDictionary *seg, NSUInteger idx, __unused BOOL *stop) {
        if (![unskipped containsObject:@(idx)]) {
            [segments addObject:seg];
        }
    }];
    BOOL enabled = YTKACESponsorBlockEnabled() && YTKACESponsorShowTimeWithSkipsEnabled() && duration > 0.0;
    double skipped = (enabled && segments.count > 0) ? YTKACESponsorCalculateSkippedDuration(segments, duration) : 0.0;
    BOOL shouldModify = enabled && skipped > 0.0;

    @try {
        for (UILabel *label in labels) {
            NSString *currentText = label.text;
            if (currentText.length == 0) continue;

            NSString *modified = objc_getAssociatedObject(label, YTKACEOptionsModifiedDurationTextKey);
            NSString *original = objc_getAssociatedObject(label, YTKACEOptionsOriginalDurationTextKey);

            // Find any separate separator label between currentLabels and this duration label in the same superview
            UILabel *inlineSep = nil;
            if (label.superview != nil) {
                CGFloat durMinX = CGRectGetMinX(label.frame);
                NSArray<UIView *> *subviewsCopy = [label.superview.subviews copy];
                for (UIView *subview in subviewsCopy) {
                    if (![subview isKindOfClass:UILabel.class]) continue;
                    if (subview == label || [currentLabels containsObject:(UILabel *)subview]) continue;
                    CGFloat x = CGRectGetMidX(subview.frame);
                    if (x <= durMinX + 5.0) {
                        UILabel *subLbl = (UILabel *)subview;
                        NSString *t = [subLbl.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                        if ([t isEqualToString:@"/"] || [t isEqualToString:@"•"] || [t isEqualToString:@"·"] ||
                            [t isEqualToString:@"-"] || [t isEqualToString:@"–"]) {
                            inlineSep = subLbl;
                            break;
                        }
                    }
                }
            }

            if (inlineSep != nil) {
                if (shouldModify) {
                    if (objc_getAssociatedObject(inlineSep, YTKACEOptionsOriginalSepHiddenKey) == nil) {
                        objc_setAssociatedObject(inlineSep, YTKACEOptionsOriginalSepHiddenKey, @(inlineSep.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    inlineSep.hidden = YES;
                } else {
                    NSNumber *origHidden = objc_getAssociatedObject(inlineSep, YTKACEOptionsOriginalSepHiddenKey);
                    if (origHidden != nil) {
                        inlineSep.hidden = origHidden.boolValue;
                        objc_setAssociatedObject(inlineSep, YTKACEOptionsOriginalSepHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                }
            }

            if (!shouldModify) {
                if (modified != nil && [currentText isEqualToString:modified] && original != nil) {
                    label.text = original;
                    [label sizeToFit];
                }
                objc_setAssociatedObject(label, YTKACEOptionsOriginalDurationTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(label, YTKACEOptionsModifiedDurationTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                continue;
            }

            NSString *compoundSep = YTKACEFindCompoundSeparator(original);
            if (compoundSep == nil) {
                compoundSep = YTKACEFindCompoundSeparator(currentText);
            }
            if (compoundSep == nil && modified != nil) {
                compoundSep = YTKACEFindCompoundSeparator(modified);
            }

            BOOL isCountdown = [original hasPrefix:@"-"] || [original hasPrefix:@" -"] || [original hasPrefix:@"–"] ||
                               [currentText hasPrefix:@"-"] || [currentText hasPrefix:@" -"] || [currentText hasPrefix:@"–"];

            if (compoundSep == nil && !isCountdown) {
                double parsed = YTKACEParseSecondsFromTimeString(currentText);
                if (parsed >= 0.0 && duration > 20.0) {
                    if (fabs(parsed - current) <= 15.0 && fabs(parsed - duration) > 15.0) {
                        continue;
                    }
                }
            }

            if (modified == nil || ![currentText isEqualToString:modified]) {
                original = currentText;
                objc_setAssociatedObject(label, YTKACEOptionsOriginalDurationTextKey, original, OBJC_ASSOCIATION_COPY_NONATOMIC);
            }

            double effectiveDuration = MAX(0.0, duration - skipped);
            BOOL forceHours = duration >= 3600.0;

            NSString *effectiveDurStr = YTKACEFormatTimeDuration(effectiveDuration, forceHours);
            NSString *origDurStr = YTKACEFormatTimeDuration(duration, forceHours);
            NSString *combinedDurStr = [NSString stringWithFormat:@"%@ (%@)", effectiveDurStr, origDurStr];

            NSString *newDurStr = nil;
            if (compoundSep != nil) {
                NSRange r = [original rangeOfString:compoundSep];
                NSString *leftPart = nil;
                if (r.location != NSNotFound) {
                    leftPart = [original substringToIndex:r.location];
                } else {
                    NSRange curR = [currentText rangeOfString:compoundSep];
                    if (curR.location != NSNotFound) {
                        leftPart = [currentText substringToIndex:curR.location];
                    }
                }
                if (leftPart.length > 0) {
                    leftPart = [leftPart stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    newDurStr = [NSString stringWithFormat:@"%@ / %@", leftPart, combinedDurStr];
                }
            } else if (isCountdown) {
                NSMutableArray<NSDictionary *> *remSegments = [NSMutableArray array];
                for (NSDictionary *seg in segments) {
                    double segStart = [seg[@"start"] doubleValue];
                    double segEnd = [seg[@"end"] doubleValue];
                    if (segEnd > current) {
                        double effectiveStart = MAX(current, segStart);
                        if (segEnd > effectiveStart) {
                            NSMutableDictionary *clamped = [seg mutableCopy];
                            clamped[@"start"] = @(effectiveStart);
                            clamped[@"end"] = @(segEnd);
                            [remSegments addObject:clamped];
                        }
                    }
                }
                double remainingSkips = YTKACESponsorCalculateSkippedDuration(remSegments, duration);
                double remaining = MAX(0.0, duration - current);
                double remainingEffective = MAX(0.0, remaining - remainingSkips);
                NSString *prefix = [original hasPrefix:@" -"] ? @" -" : ([original hasPrefix:@"–"] ? @"–" : @"-");
                NSString *effectiveRemStr = [prefix stringByAppendingString:YTKACEFormatTimeDuration(remainingEffective, forceHours)];
                NSString *origRemStr = [prefix stringByAppendingString:YTKACEFormatTimeDuration(remaining, forceHours)];
                newDurStr = [NSString stringWithFormat:@"%@ (%@)", effectiveRemStr, origRemStr];
            } else {
                newDurStr = [NSString stringWithFormat:@" / %@", combinedDurStr];
                if ([original hasSuffix:@" "]) {
                    newDurStr = [newDurStr stringByAppendingString:@" "];
                }
            }

            if (newDurStr.length > 0 && ![currentText isEqualToString:newDurStr]) {
                label.text = newDurStr;
                objc_setAssociatedObject(label, YTKACEOptionsModifiedDurationTextKey, newDurStr, OBJC_ASSOCIATION_COPY_NONATOMIC);
                [label sizeToFit];
            }
        }
    } @catch (__unused NSException *exception) {
    }
}

static void YTKACEPlayerBarLayout(UIView *receiver, SEL selector) {
    if (OriginalPlayerBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalPlayerBarLayout)(receiver, selector);
    }

    YTKACEConfigureTapToSeek(receiver);

    [YTKACESponsorBars addObject:receiver];
    UIView *target = receiver;
    for (UIView *subview in receiver.subviews) {
        if ([NSStringFromClass(subview.class) isEqualToString:@"YTModularPlayerBarView"]) {
            target = subview;
            break;
        }
    }
    YTKACERenderSponsorMarkers(receiver, target, NO);
    if (!YTKACEUserIsScrubbing && !YTKACEIsScrubbing(nil, receiver)) {
        YTKACEUpdatePlayerBarDuration(receiver);
    }
}

static void YTKACEMiniplayerBarLayout(UIView *receiver, SEL selector) {
    if (OriginalMiniplayerBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalMiniplayerBarLayout)(receiver, selector);
    }
    [YTKACESponsorBars addObject:receiver];
    YTKACEApplyProgressStyleToBar(receiver);
    YTKACERenderSponsorMarkers(receiver, receiver, YES);
    if (!YTKACEUserIsScrubbing && !YTKACEIsScrubbing(nil, receiver)) {
        YTKACEUpdatePlayerBarDuration(receiver);
    }
}

static void YTKACEOverlayChaptersDidChange(id receiver,
                                           SEL selector,
                                           id macroMarkersController,
                                           id chapters) {
    if (OriginalOverlayChaptersDidChange != NULL) {
        ((void (*)(id, SEL, id, id))OriginalOverlayChaptersDidChange)(
            receiver, selector, macroMarkersController, chapters
        );
    }
    YTKACELastOverlayController = receiver;
    if (macroMarkersController != nil) {
        YTKACELastMacroMarkersController = macroMarkersController;
    }
    if ([chapters isKindOfClass:NSArray.class]) {
        YTKACELastReceivedChapters = [(NSArray *)chapters count] > 0 ? [chapters copy] : nil;
        YTKACELastChaptersVideoID = YTKACESponsorCurrentVideoID();
    } else if (chapters == nil) {
        YTKACELastReceivedChapters = nil;
    }
}

static void YTKACEPlayerBarControllerSetChapters(id receiver,
                                                 SEL selector,
                                                 id chapters) {
    if (OriginalPlayerBarControllerSetChapters != NULL) {
        ((void (*)(id, SEL, id))OriginalPlayerBarControllerSetChapters)(
            receiver, selector, chapters
        );
    }
    YTKACELastPlayerBarController = receiver;
    if ([chapters isKindOfClass:NSArray.class]) {
        if ([(NSArray *)chapters count] > 0) {
            YTKACELastReceivedChapters = [chapters copy];
            YTKACELastChaptersVideoID = YTKACESponsorCurrentVideoID();
        }
    }
}

static void YTKACEInlinePlayerBarSetChapters(UIView *receiver,
                                             SEL selector,
                                             id chapters) {
    if (OriginalInlinePlayerBarSetChapters != NULL) {
        ((void (*)(id, SEL, id))OriginalInlinePlayerBarSetChapters)(
            receiver, selector, chapters
        );
    }
    if (receiver != nil) {
        [YTKACESponsorBars addObject:receiver];
    }
    if ([chapters isKindOfClass:NSArray.class]) {
        if ([(NSArray *)chapters count] > 0) {
            YTKACELastReceivedChapters = [chapters copy];
            YTKACELastChaptersVideoID = YTKACESponsorCurrentVideoID();
        }
    }
}

void YTKACEInstallSponsorBlockHooks(void) {
    if (YTKACESponsorBars == nil) {
        YTKACESponsorBars = [NSHashTable weakObjectsHashTable];
    }
    YTKACERefreshPlaybackTimePreferenceState();
    if (YTKACEPlaybackPreferenceObserver == nil) {
        YTKACEPlaybackPreferenceObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:YTKACEPreferencesDidChangeNotification
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *notification) {
                YTKACERefreshPlaybackTimePreferenceState();
                for (UIView *bar in YTKACESponsorBars.allObjects) {
                    YTKACEUpdatePlayerBarDuration(bar);
                }
            }];
    }
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"didStartPlayerBarScrubbingWithGestureOriginatingInPlayerBar:",
                              (IMP)YTKACEOverlayScrubStart,
                              &OriginalOverlayScrubStart);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"didEndPlayerBarScrubbingWithGestureOriginatingInPlayerBar:withSeekCancelled:seekSource:",
                              (IMP)YTKACEOverlayScrubEnd,
                              &OriginalOverlayScrubEnd);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"macroMarkersController:chaptersDidChange:",
                              (IMP)YTKACEOverlayChaptersDidChange,
                              &OriginalOverlayChaptersDidChange);
    YTKACEInstallInstanceHook(@"YTPlayerBarController",
                              @"setChapters:",
                              (IMP)YTKACEPlayerBarControllerSetChapters,
                              &OriginalPlayerBarControllerSetChapters);
    YTKACEInstallInstanceHook(@"YTInlinePlayerBarContainerView",
                              @"setChapters:",
                              (IMP)YTKACEInlinePlayerBarSetChapters,
                              &OriginalInlinePlayerBarSetChapters);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"playerBarDidBeginScrubbing:",
                              (IMP)YTKACEPlayerBarDidBeginScrubbing,
                              &OriginalPlayerBarDidBeginScrubbing);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"playerBarDidEndScrubbing:",
                              (IMP)YTKACEPlayerBarDidEndScrubbing,
                              &OriginalPlayerBarDidEndScrubbing);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"playbackController:didActivateVideo:withPlaybackData:",
                              (IMP)YTKACEDidActivateVideo,
                              &OriginalDidActivateVideo);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"singleVideo:currentVideoTimeDidChange:",
                              (IMP)YTKACESingleVideoTimeChanged,
                              &OriginalSingleVideoTimeChanged);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"potentiallyMutatedSingleVideo:currentVideoTimeDidChange:",
                              (IMP)YTKACEMutatedVideoTimeChanged,
                              &OriginalMutatedVideoTimeChanged);
    YTKACEInstallInstanceHook(@"YTInlinePlayerBarContainerView",
                              @"layoutSubviews",
                              (IMP)YTKACEPlayerBarLayout,
                              &OriginalPlayerBarLayout);
    YTKACEInstallInstanceHook(@"YTWatchFloatingMiniplayerProgressBarView",
                              @"layoutSubviews",
                              (IMP)YTKACEMiniplayerBarLayout,
                              &OriginalMiniplayerBarLayout);
    YTKACEInstallSponsorSubmitControls();
}
