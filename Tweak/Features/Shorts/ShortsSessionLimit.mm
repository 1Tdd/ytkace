#import "../../YTKACE.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Notice.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const YTKACEShortsLimitKey = @"YTKACE.Preference.Shorts.LimitEnabled";
static NSString * const YTKACEShortsLimitCountKey = @"YTKACE.Preference.Shorts.LimitCount";

static NSMutableOrderedSet<NSString *> *YTKACEShortsSeen;
static BOOL YTKACEShortsBlocked;
static id YTKACEShortsLimitObserver;

static NSInteger YTKACEShortsLimitValue(void) {
    NSInteger value = [NSUserDefaults.standardUserDefaults
        integerForKey:YTKACEShortsLimitCountKey];
    if (value < 1) value = 20;
    return MIN(value, 500);
}

BOOL YTKACEShortsLimitReached(void) {
    return YTKACEShortsBlocked;
}

static UIViewController *YTKACEReelRootController(UIViewController *controller,
                                                  NSUInteger depth) {
    if (controller == nil || depth > 6) return nil;
    if ([controller respondsToSelector:NSSelectorFromString(@"activeReelPlaybackVideoId")] ||
        [controller respondsToSelector:NSSelectorFromString(@"activeReelPlaybackVideoID")]) {
        return controller;
    }
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = YTKACEReelRootController(child, depth + 1);
        if (found != nil) return found;
    }
    return YTKACEReelRootController(controller.presentedViewController, depth + 1);
}

static UIViewController *YTKACEActiveReelController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isHidden) continue;
            UIViewController *found = YTKACEReelRootController(window.rootViewController, 0);
            if (found != nil) return found;
        }
    }
    return nil;
}

static UIScrollView *YTKACEReelPager(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 8) return nil;
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIScrollView.class]) {
            UIScrollView *candidate = (UIScrollView *)child;
            if (CGRectGetHeight(candidate.bounds) > 200.0 &&
                candidate.contentSize.height > CGRectGetHeight(candidate.bounds)) {
                return candidate;
            }
        }
        UIScrollView *found = YTKACEReelPager(child, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static void YTKACEApplyShortsBlock(UIViewController *reel) {
    UIScrollView *pager = YTKACEReelPager(reel.view, 0);
    if (pager == nil) return;
    if (!pager.scrollEnabled) return;
    pager.scrollEnabled = NO;
}

static void YTKACENoteShort(NSString *videoID, UIViewController *reel) {
    if (videoID.length == 0) return;
    if (YTKACEShortsSeen == nil) YTKACEShortsSeen = [NSMutableOrderedSet orderedSet];
    const NSUInteger before = YTKACEShortsSeen.count;
    [YTKACEShortsSeen addObject:videoID];
    if (YTKACEShortsSeen.count == before) return;

    const NSInteger limit = YTKACEShortsLimitValue();
    if ((NSInteger)YTKACEShortsSeen.count < limit) return;

    const BOOL announce = !YTKACEShortsBlocked;
    YTKACEShortsBlocked = YES;
    YTKACEApplyShortsBlock(reel);
    if (announce) {
        YTKACEShowNotice([NSString stringWithFormat:
            YTKACELocalized(@"Shorts limit reached (%ld). Restart YouTube to reset."),
            (long)limit]);
    }
}

static void YTKACEShortsLimitTick(void) {
    if (!YTKACEFeatureEnabled(YTKACEShortsLimitKey)) return;
    static NSTimeInterval last = 0.0;
    const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - last < 0.4) return;
    last = now;

    UIViewController *reel = YTKACEActiveReelController();
    if (reel == nil) return;
    SEL active = [reel respondsToSelector:NSSelectorFromString(@"activeReelPlaybackVideoId")]
        ? NSSelectorFromString(@"activeReelPlaybackVideoId")
        : NSSelectorFromString(@"activeReelPlaybackVideoID");
    id value = [reel respondsToSelector:active]
        ? ((id (*)(id, SEL))objc_msgSend)(reel, active)
        : nil;
    if (![value isKindOfClass:NSString.class] || [value length] == 0) return;

    if (YTKACEShortsBlocked) {
        YTKACEApplyShortsBlock(reel);
        return;
    }
    YTKACENoteShort(value, reel);
}

void YTKACEInstallShortsLimitHooks(void) {
    if (YTKACEShortsLimitObserver != nil) return;
    YTKACEShortsLimitObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:@"YTKACEPlaybackTimeDidChange"
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
                    YTKACEShortsLimitTick();
                }];
}
