#import "../../YTKACE.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadCoordinator.h"
#import "../Downloads/DownloadLog.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

static NSHashTable<UIView *> *YTKACEReelViews;
static NSMutableDictionary<NSString *, NSValue *> *YTKACEShortsOriginals;
static NSMutableSet<NSString *> *YTKACEShortsInstalledHooks;
static const void *YTKACEShortsTrackAssociation = &YTKACEShortsTrackAssociation;
static const void *YTKACEShortsFillAssociation = &YTKACEShortsFillAssociation;
static const void *YTKACEShortsSkipAssociation = &YTKACEShortsSkipAssociation;
static const void *YTKACEShortsDownloadAssociation = &YTKACEShortsDownloadAssociation;
static const void *YTKACEShortsHiddenAssociation = &YTKACEShortsHiddenAssociation;
static const void *YTKACEShortsDownloadConstraintsAssociation =
    &YTKACEShortsDownloadConstraintsAssociation;
static const void *YTKACEShortsDownloadAnchoredAssociation =
    &YTKACEShortsDownloadAnchoredAssociation;
static const void *YTKACEShortsRailTransformAssociation =
    &YTKACEShortsRailTransformAssociation;
static const void *YTKACEShortsInitialRefreshAssociation =
    &YTKACEShortsInitialRefreshAssociation;
static NSInteger const YTKACEShortsDownloadTag = 0x59544B44;
static double YTKACELastShortsTime;
static double YTKACELastShortsDuration;
static id YTKACELatestShortsPlayerResponse;

static void YTKACEReelLayout(UIView *receiver, SEL selector);
static void YTKACEReelOverlayLayout(UIView *receiver, SEL selector);
static void YTKACEShortsControllerLayout(UIViewController *receiver,
                                         SEL selector);
static void YTKACEPausedLayout(UIView *receiver, SEL selector);
static void YTKACEInteractiveStickerLayout(UIView *receiver, SEL selector);
static NSArray<NSArray<NSString *> *> *YTKACEShortsRules(void);

static void YTKACESetShortsHidden(UIView *view, BOOL hidden) {
    NSNumber *owned = objc_getAssociatedObject(
        view, YTKACEShortsHiddenAssociation);
    if (hidden) {
        if (owned == nil) {
            objc_setAssociatedObject(view, YTKACEShortsHiddenAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (owned != nil) {
        view.hidden = NO;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view, YTKACEShortsHiddenAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL YTKACEAnyShortsActionHidden(void) {
    for (NSArray<NSString *> *rule in YTKACEShortsRules()) {
        if (YTKACEFeatureEnabled(rule.firstObject)) return YES;
    }
    return NO;
}

static NSArray<NSArray<NSString *> *> *YTKACEShortsRules(void) {
    static NSArray<NSArray<NSString *> *> *rules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rules = @[
            @[@"YTKACE.Preference.Shorts.RemixHidden", @"id.reel_remix_button"],
            @[@"YTKACE.Preference.Shorts.SoundHidden", @"id.reel_pivot_button"],
            @[@"YTKACE.Preference.Shorts.ShareHidden", @"id.reel_share_button"],
            @[@"YTKACE.Preference.Shorts.CommentsHidden", @"id.reel_comment_button"],
            @[@"YTKACE.Preference.Shorts.LikeHidden", @"id.reel_like_button"],
            @[@"YTKACE.Preference.Shorts.SaveHidden"]
        ];
    });
    return rules;
}

typedef struct {
    CGFloat minX;
    CGFloat width;
    CGFloat height;
    BOOL valid;
} YTKACERailMetrics;

static BOOL YTKACEIsIdentifiedRailButton(NSString *identifier) {
    return [identifier hasPrefix:@"id.reel_"] &&
        [identifier hasSuffix:@"_button"];
}

static void YTKACECollectRailMetrics(UIView *view,
                                     UIView *root,
                                     YTKACERailMetrics *metrics) {
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    if (YTKACEIsIdentifiedRailButton(identifier)) {
        CGRect frame = [view convertRect:view.bounds toView:root];
        if (CGRectGetWidth(frame) > 32.0 && CGRectGetHeight(frame) > 32.0) {
            metrics->minX = CGRectGetMinX(frame);
            metrics->width = CGRectGetWidth(frame);
            metrics->height = CGRectGetHeight(frame);
            metrics->valid = YES;
        }
    }
    for (UIView *child in view.subviews) {
        YTKACECollectRailMetrics(child, root, metrics);
    }
}

static BOOL YTKACEShortsIsSaveButton(UIView *view,
                                     UIView *root,
                                     const YTKACERailMetrics *metrics) {
    if (metrics == NULL || !metrics->valid) return NO;
    if (view.accessibilityIdentifier.length != 0) return NO;
    if (view.accessibilityLabel.length == 0) return NO;
    if (view.tag == YTKACEShortsDownloadTag) return NO;
    CGRect frame = [view convertRect:view.bounds toView:root];
    return fabs(CGRectGetMinX(frame) - metrics->minX) < 6.0 &&
        fabs(CGRectGetWidth(frame) - metrics->width) < 8.0 &&
        fabs(CGRectGetHeight(frame) - metrics->height) < 14.0;
}

static BOOL YTKACEShortsActionHidden(UIView *view,
                                     UIView *root,
                                     const YTKACERailMetrics *metrics) {
    if (view.tag == YTKACEShortsDownloadTag ||
        [view.accessibilityIdentifier hasPrefix:@"YTKACE"]) {
        return NO;
    }
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    BOOL actionable = [view isKindOfClass:UIControl.class] ||
        view.accessibilityIdentifier.length != 0 ||
        view.accessibilityLabel.length != 0;
    if (!actionable) return NO;
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.SaveHidden") &&
        YTKACEShortsIsSaveButton(view, root, metrics)) {
        return YES;
    }
    for (NSArray<NSString *> *rule in YTKACEShortsRules()) {
        if (!YTKACEFeatureEnabled(rule.firstObject)) continue;
        for (NSUInteger index = 1; index < rule.count; index++) {
            NSString *needle = rule[index];
            if (identifier.length != 0 && [identifier containsString:needle]) {
                return YES;
            }
        }
    }
    return NO;
}

static void YTKACEApplyShortsVisibilityWalk(UIView *view,
                                            UIView *root,
                                            const YTKACERailMetrics *metrics) {
    YTKACESetShortsHidden(view, YTKACEShortsActionHidden(view, root, metrics));
    for (UIView *subview in view.subviews) {
        YTKACEApplyShortsVisibilityWalk(subview, root, metrics);
    }
}

static void YTKACEApplyShortsActionVisibility(UIView *view) {
    YTKACERailMetrics metrics = {0.0, 0.0, 0.0, NO};
    YTKACECollectRailMetrics(view, view, &metrics);
    YTKACEApplyShortsVisibilityWalk(view, view, &metrics);
}

static BOOL YTKACEIsShortsActionIdentifier(NSString *identifier) {
    return [identifier isEqualToString:@"id.reel_like_button"] ||
        [identifier isEqualToString:@"id.reel_comment_button"] ||
        [identifier isEqualToString:@"id.reel_share_button"] ||
        [identifier isEqualToString:@"id.reel_remix_button"] ||
        [identifier isEqualToString:@"id.reel_pivot_button"];
}

static BOOL YTKACEIsShortsActionView(UIView *view, UIView *root,
                                     const YTKACERailMetrics *metrics) {
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    if (identifier.length != 0) {
        return YTKACEIsShortsActionIdentifier(identifier);
    }
    return YTKACEShortsIsSaveButton(view, root, metrics);
}

static BOOL YTKACEActionIsFullyVisible(UIView *view, UIView *root) {
    CGRect frame = [view convertRect:view.bounds toView:root];
    return CGRectGetWidth(frame) > 20.0 &&
        CGRectGetHeight(frame) > 20.0 &&
        CGRectGetMidX(frame) > CGRectGetWidth(root.bounds) * 0.55 &&
        CGRectGetMinY(frame) >= 0.0 &&
        CGRectGetMaxY(frame) <= CGRectGetHeight(root.bounds);
}

static UIView *YTKACEShortsPlaybackOverlay(UIView *view, UIView *root) {
    for (UIView *candidate = view; candidate != nil;
         candidate = candidate.superview) {
        if ([NSStringFromClass(candidate.class)
                containsString:@"ReelWatchPlaybackOverlayView"]) {
            return candidate;
        }
        if (candidate == root) break;
    }
    CGSize full = root.bounds.size;
    for (UIView *candidate = view.superview; candidate != nil && candidate != root;
         candidate = candidate.superview) {
        CGSize size = candidate.bounds.size;
        if (size.width >= full.width * 0.9 && size.height >= full.height * 0.6) return candidate;
    }
    return nil;
}

static void YTKACECollectShortsActionsWalk(UIView *view,
                                           UIView *root,
                                           BOOL includeHidden,
                                           const YTKACERailMetrics *metrics,
                                           NSMutableArray<UIView *> *views) {
    if (view.tag != YTKACEShortsDownloadTag &&
        (includeHidden || (!view.hidden && view.alpha > 0.05)) &&
        YTKACEIsShortsActionView(view, root, metrics) &&
        YTKACEActionIsFullyVisible(view, root)) {
        [views addObject:view];
    }
    for (UIView *subview in view.subviews) {
        YTKACECollectShortsActionsWalk(subview, root, includeHidden, metrics, views);
    }
}

static void YTKACECollectShortsActions(UIView *view,
                                       UIView *root,
                                       BOOL includeHidden,
                                       NSMutableArray<UIView *> *views) {
    YTKACERailMetrics metrics = {0.0, 0.0, 0.0, NO};
    YTKACECollectRailMetrics(root, root, &metrics);
    YTKACECollectShortsActionsWalk(view, root, includeHidden, &metrics, views);
}

static UIView *YTKACEVisibleShortsAction(UIView *root) {
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    YTKACECollectShortsActions(root, root, NO, actions);
    NSString *expected = nil;
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.LikeHidden")) {
        expected = @"id.reel_like_button";
    } else if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.CommentsHidden")) {
        expected = @"id.reel_comment_button";
    } else if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.ShareHidden")) {
        expected = @"id.reel_share_button";
    } else if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.RemixHidden")) {
        expected = @"id.reel_remix_button";
    } else if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.SoundHidden")) {
        expected = @"id.reel_pivot_button";
    }
    if (expected == nil) return nil;
    for (UIView *action in actions) {
        if (YTKACEShortsPlaybackOverlay(action, root) == nil) continue;
        if ([action.accessibilityIdentifier.lowercaseString
                isEqualToString:expected]) {
            return action;
        }
    }
    return nil;
}

static UIView *YTKACEVisibleShortsPlaybackOverlay(UIView *root) {
    NSString *className = NSStringFromClass(root.class);
    if ([className containsString:@"ReelWatchPlaybackOverlayView"] &&
        root.window != nil && !root.hidden && root.alpha > 0.05 &&
        CGRectGetWidth(root.bounds) > 200.0 &&
        CGRectGetHeight(root.bounds) > 300.0) {
        return root;
    }
    for (UIView *subview in root.subviews) {
        UIView *overlay = YTKACEVisibleShortsPlaybackOverlay(subview);
        if (overlay != nil) return overlay;
    }
    return nil;
}

static UIView *YTKACECurrentShortsPlaybackOverlay(UIView *root) {
    UIView *visibleOverlay = YTKACEVisibleShortsPlaybackOverlay(root);
    if (visibleOverlay != nil) return visibleOverlay;
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    YTKACECollectShortsActions(root, root, YES, actions);
    for (UIView *action in actions) {
        UIView *overlay = YTKACEShortsPlaybackOverlay(action, root);
        if (overlay != nil) return overlay;
    }
    return nil;
}

static void YTKACECompactShortsRail(UIView *root) {
    if (!YTKACEAnyShortsActionHidden()) return;
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    YTKACECollectShortsActions(root, root, YES, actions);
    for (UIView *action in actions) {
        NSValue *baselineValue = objc_getAssociatedObject(
            action, YTKACEShortsRailTransformAssociation);
        if (baselineValue == nil) {
            baselineValue = [NSValue valueWithCGAffineTransform:action.transform];
            objc_setAssociatedObject(action,
                YTKACEShortsRailTransformAssociation, baselineValue,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        action.transform = baselineValue.CGAffineTransformValue;
    }
    for (UIView *action in actions) {
        NSValue *baselineValue = objc_getAssociatedObject(
            action, YTKACEShortsRailTransformAssociation);
        CGFloat offset = 0.0;
        if (!action.hidden) {
            CGFloat actionY = CGRectGetMinY(
                [action convertRect:action.bounds toView:root]);
            for (UIView *candidate in actions) {
                if (!candidate.hidden) continue;
                CGFloat hiddenY = CGRectGetMinY(
                    [candidate convertRect:candidate.bounds toView:root]);
                if (hiddenY > actionY) {
                    offset += 64.0;
                }
            }
        }
        action.transform = CGAffineTransformTranslate(
            baselineValue.CGAffineTransformValue, 0.0, offset);
    }
}

static void YTKACEPositionShortsDownload(UIView *host,
                                         UIView *action,
                                         UIButton *download) {
    NSArray<NSLayoutConstraint *> *constraints = objc_getAssociatedObject(
        download, YTKACEShortsDownloadConstraintsAssociation);
    NSInteger position = [NSUserDefaults.standardUserDefaults
        integerForKey:@"YTKACE.Preference.Shorts.DownloadPosition"];
    BOOL legacyHost = [NSStringFromClass(host.class) containsString:@"ReelWatchPlaybackOverlayView"];
    if (position == 0 && !legacyHost) {
        if (constraints.count != 0) [NSLayoutConstraint deactivateConstraints:constraints];
        download.translatesAutoresizingMaskIntoConstraints = YES;
        UIEdgeInsets safe = host.safeAreaInsets;
        download.frame = CGRectMake(round(CGRectGetWidth(host.bounds) - safe.right - 12.0 - 36.0),
                                    round(safe.top + 65.0), 36.0, 36.0);
        download.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        return;
    }
    if (position == 0) {
        if (download.translatesAutoresizingMaskIntoConstraints) {
            download.translatesAutoresizingMaskIntoConstraints = NO;
        }
        if (constraints == nil) {
            constraints = @[
                [download.widthAnchor constraintEqualToConstant:36.0],
                [download.heightAnchor constraintEqualToConstant:36.0],
                [download.trailingAnchor constraintEqualToAnchor:
                    host.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
                [download.topAnchor constraintEqualToAnchor:
                    host.safeAreaLayoutGuide.topAnchor constant:65.0]
            ];
            objc_setAssociatedObject(download,
                YTKACEShortsDownloadConstraintsAssociation,
                constraints, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [NSLayoutConstraint activateConstraints:constraints];
        [host layoutIfNeeded];
        return;
    }

    if (constraints.count != 0) {
        [NSLayoutConstraint deactivateConstraints:constraints];
    }
    download.translatesAutoresizingMaskIntoConstraints = YES;
    CGFloat centerX = CGRectGetWidth(host.bounds) - 32.0;
    CGFloat top = host.safeAreaInsets.top + 65.0;
    if (action == nil && !CGRectIsEmpty(download.frame) &&
        CGRectGetWidth(download.frame) >= 35.0) {
        return;
    }
    if (action != nil) {
        CGRect frame = [action convertRect:action.bounds toView:host];
        centerX = CGRectGetMidX(frame);
        top = CGRectGetMinY(frame) - 48.0;
    }
    top = MAX(host.safeAreaInsets.top + 52.0, top);
    download.frame = CGRectMake(round(centerX - 18.0), round(top), 36.0, 36.0);
    download.autoresizingMask =
        UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
}

static NSString *YTKACEShortsHookKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP YTKACEShortsOriginal(id receiver, SEL selector,
                                NSUInteger ordinal) {
    NSUInteger candidate = 0;
    for (Class cls = object_getClass(receiver); cls != Nil;
         cls = class_getSuperclass(cls)) {
        IMP original = (IMP)[YTKACEShortsOriginals[
            YTKACEShortsHookKey(cls, selector)] pointerValue];
        if (original != NULL &&
            original != (IMP)YTKACEReelLayout &&
            original != (IMP)YTKACEReelOverlayLayout &&
            original != (IMP)YTKACEShortsControllerLayout &&
            original != (IMP)YTKACEPausedLayout &&
            original != (IMP)YTKACEInteractiveStickerLayout) {
            if (candidate == ordinal) {
                return original;
            }
            candidate++;
        }
    }
    return NULL;
}

static void YTKACEInvokeShortsOriginal(id receiver, SEL selector) {
    NSMutableDictionary *threadState = NSThread.currentThread.threadDictionary;
    NSString *depthKey = [NSString stringWithFormat:
        @"YTKACE.Shorts.%p.%@", receiver, NSStringFromSelector(selector)];
    NSUInteger depth = [threadState[depthKey] unsignedIntegerValue];
    IMP original = YTKACEShortsOriginal(receiver, selector, depth);
    if (original == NULL) return;

    threadState[depthKey] = @(depth + 1);
    @try {
        ((void (*)(id, SEL))original)(receiver, selector);
    } @finally {
        if (depth == 0) {
            [threadState removeObjectForKey:depthKey];
        } else {
            threadState[depthKey] = @(depth);
        }
    }
}

static Method YTKACEShortsDirectMethod(Class cls, SEL selector) {
    if (cls == Nil) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

static BOOL YTKACEShortsIsReplacement(IMP implementation) {
    return implementation == (IMP)YTKACEReelLayout ||
        implementation == (IMP)YTKACEReelOverlayLayout ||
        implementation == (IMP)YTKACEShortsControllerLayout ||
        implementation == (IMP)YTKACEPausedLayout ||
        implementation == (IMP)YTKACEInteractiveStickerLayout;
}

static id YTKACEShortsObject(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector) : nil;
}

static id YTKACEShortsResponseFromObject(id object,
                                         NSHashTable *visited,
                                         NSUInteger depth) {
    if (object == nil || depth > 7 || [visited containsObject:object]) {
        return nil;
    }
    [visited addObject:object];
    id response = YTKACEShortsObject(object, @"contentPlayerResponse") ?:
        YTKACEShortsObject(object, @"playerResponse");
    if (response != nil) {
        return response;
    }
    for (NSString *name in @[@"_youtubeiOSPlayerViewController", @"parentResponder",
                              @"parentViewController", @"eventsDelegate",
                              @"playbackController", @"activeVideoPlayerOverlay"]) {
        id related = YTKACEShortsObject(object, name);
        response = YTKACEShortsResponseFromObject(related, visited, depth + 1);
        if (response != nil) {
            return response;
        }
    }
    if ([object isKindOfClass:UIResponder.class]) {
        return YTKACEShortsResponseFromObject(
            ((UIResponder *)object).nextResponder, visited, depth + 1);
    }
    return nil;
}

static NSMutableDictionary<NSString *, NSNumber *> *YTKACEShortsBarrenClasses;

static id YTKACEShortsPlayerResponseFromObject(id object) {
    if (object == nil) return nil;
    NSString *name = NSStringFromClass([object class]);
    if (YTKACEShortsBarrenClasses == nil) {
        YTKACEShortsBarrenClasses = [NSMutableDictionary dictionary];
    }
    if (YTKACEShortsBarrenClasses[name].integerValue >= 3) return nil;

    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    id result = YTKACEShortsResponseFromObject(object, visited, 0);
    if (result != nil) {
        [YTKACEShortsBarrenClasses removeObjectForKey:name];
    } else {
        YTKACEShortsBarrenClasses[name] =
            @(YTKACEShortsBarrenClasses[name].integerValue + 1);
    }
    return result;
}

@interface YTKACEShortsDownloadTarget : NSObject
+ (instancetype)sharedTarget;
- (void)downloadTapped:(UIButton *)sender;
@end

@implementation YTKACEShortsDownloadTarget
+ (instancetype)sharedTarget {
    static YTKACEShortsDownloadTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACEShortsDownloadTarget new]; });
    return target;
}
- (void)downloadTapped:(UIButton *)sender {
    [YTKACEShortsBarrenClasses removeAllObjects];
    id fromView = YTKACEShortsPlayerResponseFromObject(sender);
    id response = fromView ?: YTKACELatestShortsPlayerResponse;
    YTKACEDownloadCoordinator.sharedCoordinator.playerResponse = response;
    [YTKACEDownloadCoordinator.sharedCoordinator
        showShortsDownloadMenuFromView:sender];
}
@end

static double YTKACEShortsDouble(id receiver, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            return ((double (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    return 0.0;
}

static id YTKACEShortsParent(id receiver) {
    SEL selector = NSSelectorFromString(@"parentViewController");
    return [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector)
        : nil;
}

static BOOL YTKACEIsShortsController(id candidate) {
    if (![candidate isKindOfClass:UIViewController.class]) return NO;
    NSString *name = NSStringFromClass([candidate class]).lowercaseString;
    if ([name containsString:@"shorts"] || [name containsString:@"reel"]) {
        return YES;
    }
    for (NSString *selectorName in @[
        @"playbackSequentialItemControllerDidRequestNextReel:isAutoAdvance:",
        @"advanceToNextReelWithTransitionType:",
        @"autoAdvanceIfNeeded",
        @"reelContentViewRequestsAdvanceToNextVideo:",
        @"activeReelPlaybackVideoId",
        @"activeReelPlaybackVideoID",
        @"advanceToNextVideo:",
        @"advanceToNextVideo",
        @"scrollToNextVideo"
    ]) {
        if ([candidate respondsToSelector:NSSelectorFromString(selectorName)]) {
            return YES;
        }
    }
    return NO;
}

static void YTKACEAppendShortsChain(id start,
                                    NSMutableArray<UIViewController *> *results,
                                    NSHashTable *visited) {
    id current = start;
    for (NSInteger depth = 0; current != nil && depth < 28; depth++) {
        if ([visited containsObject:current]) break;
        [visited addObject:current];
        if (YTKACEIsShortsController(current) && ![results containsObject:current]) {
            [results addObject:(UIViewController *)current];
        }
        for (NSString *relKey in @[
            @"activePlaybackSequenceItemController",
            @"delegate",
            @"parentViewController",
            @"parentResponder",
            @"eventsDelegate",
            @"UIDelegate"
        ]) {
            id rel = YTKACEShortsObject(current, relKey);
            if (rel != nil && ![visited containsObject:rel] && YTKACEIsShortsController(rel) && ![results containsObject:rel]) {
                if ([relKey isEqualToString:@"activePlaybackSequenceItemController"]) {
                    [results insertObject:(UIViewController *)rel atIndex:0];
                } else {
                    [results addObject:(UIViewController *)rel];
                }
            }
        }
        id pageVC = YTKACEShortsObject(current, @"scrollablePageViewController");
        id currentVC = YTKACEShortsObject(pageVC, @"currentViewController");
        if (YTKACEIsShortsController(currentVC) && ![results containsObject:currentVC]) {
            [results insertObject:(UIViewController *)currentVC atIndex:0];
        }
        id next = YTKACEShortsParent(current);
        if (next == nil || next == current || [visited containsObject:next]) {
            next = YTKACEShortsObject(current, @"parentResponder");
        }
        if ((next == nil || next == current || [visited containsObject:next]) &&
            [current isKindOfClass:UIResponder.class]) {
            next = ((UIResponder *)current).nextResponder;
        }
        if (next == current) break;
        current = next;
    }
}

static NSArray<UIViewController *> *YTKACECollectShortsControllers(id receiver) {
    if (receiver == nil) return @[];
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    YTKACEAppendShortsChain(receiver, controllers, visited);
    id playerView = YTKACEShortsObject(receiver, @"playerView");
    id delegate = YTKACEShortsObject(playerView, @"playerViewDelegate");
    YTKACEAppendShortsChain(delegate, controllers, visited);
    YTKACEAppendShortsChain(playerView, controllers, visited);
    if ([receiver isKindOfClass:UIViewController.class] &&
        ((UIViewController *)receiver).isViewLoaded) {
        YTKACEAppendShortsChain(((UIViewController *)receiver).view, controllers, visited);
    }
    for (UIViewController *found in [controllers copy]) {
        YTKACEAppendShortsChain(found, controllers, visited);
        if (found.isViewLoaded) {
            YTKACEAppendShortsChain(found.view, controllers, visited);
        }
    }
    return controllers;
}

static NSString *YTKACECurrentShortsVideoID(id player, NSArray<UIViewController *> *controllers) {
    for (NSString *selName in @[@"currentVideoID", @"videoId", @"activeVideoID", @"activeReelPlaybackVideoId", @"activeReelPlaybackVideoID"]) {
        id val = YTKACEShortsObject(player, selName);
        if ([val isKindOfClass:NSString.class] && ((NSString *)val).length > 0) {
            return (NSString *)val;
        }
    }
    id activeVideo = YTKACEShortsObject(player, @"activeVideo");
    if (activeVideo != nil) {
        id val = YTKACEShortsObject(activeVideo, @"videoId");
        if (![val isKindOfClass:NSString.class]) {
            id single = YTKACEShortsObject(activeVideo, @"singleVideo");
            val = YTKACEShortsObject(single, @"videoId");
        }
        if ([val isKindOfClass:NSString.class] && ((NSString *)val).length > 0) {
            return (NSString *)val;
        }
    }
    static NSArray<NSString *> *idSelectors;
    static dispatch_once_t idOnce;
    dispatch_once(&idOnce, ^{
        idSelectors = @[@"activeReelPlaybackVideoId", @"activeReelPlaybackVideoID",
                        @"activeVideoID", @"currentVideoID", @"videoId"];
    });
    for (UIViewController *vc in controllers) {
        for (NSString *selName in idSelectors) {
            id val = YTKACEShortsObject(vc, selName);
            if ([val isKindOfClass:NSString.class] && ((NSString *)val).length > 0) {
                return (NSString *)val;
            }
        }
    }
    return nil;
}

static BOOL YTKACERequestNextReelFromController(id controller) {
    if (controller == nil) return NO;
    SEL reqPipSel = NSSelectorFromString(@"playbackSequentialItemControllerDidRequestNextReelFromPIP:isAutoAdvance:");
    SEL reqSel = NSSelectorFromString(@"playbackSequentialItemControllerDidRequestNextReel:isAutoAdvance:");
    SEL pipStateSel = NSSelectorFromString(@"isPictureInPicturePlayback");
    BOOL inPip = [controller respondsToSelector:pipStateSel] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(controller, pipStateSel);

    id delegate = YTKACEShortsObject(controller, @"delegate");
    if (delegate != nil && delegate != controller) {
        if (inPip && [delegate respondsToSelector:reqPipSel]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(delegate, reqPipSel, controller, YES);
            return YES;
        }
        if ([delegate respondsToSelector:reqSel]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(delegate, reqSel, controller, YES);
            return YES;
        }
    }

    if ([controller respondsToSelector:reqSel]) {
        id activeItem = YTKACEShortsObject(controller, @"activePlaybackSequenceItemController") ?: controller;
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(controller, reqSel, activeItem, YES);
        return YES;
    }

    SEL transitionSel = NSSelectorFromString(@"advanceToNextReelWithTransitionType:");
    if ([controller respondsToSelector:transitionSel]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(controller, transitionSel, 7);
        return YES;
    }

    SEL a11ySkipSel = NSSelectorFromString(@"a11yContainerViewDidTapSkipForwards:");
    if ([controller respondsToSelector:a11ySkipSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, a11ySkipSel, nil);
        return YES;
    }

    static NSArray<NSString *> *advanceSelectors;
    static dispatch_once_t advOnce;
    dispatch_once(&advOnce, ^{
        advanceSelectors = @[
            @"reelContentViewRequestsAdvanceToNextVideo:",
            @"advanceToNextVideo:",
            @"advanceToNextVideo",
            @"scrollToNextVideo",
            @"scrollToNextVideo:",
            @"playNextVideo"
        ];
    });
    for (NSString *name in advanceSelectors) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod([controller class], selector);
        if (method == NULL) continue;
        unsigned int argCount = method_getNumberOfArguments(method);
        if (argCount == 3) {
            char *argType = method_copyArgumentType(method, 2);
            if (argType != NULL && (argType[0] == 'B' || argType[0] == 'c')) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, selector, YES);
            } else {
                id arg = YTKACEShortsObject(controller, @"contentView");
                ((void (*)(id, SEL, id))objc_msgSend)(controller, selector, arg);
            }
            if (argType != NULL) free(argType);
        } else if (argCount == 2) {
            ((void (*)(id, SEL))objc_msgSend)(controller, selector);
        } else {
            continue;
        }
        return YES;
    }
    return NO;
}

static BOOL YTKACEAdvanceShort(NSArray<UIViewController *> *controllers, __unused id player) {
    for (UIViewController *controller in controllers) {
        if (YTKACERequestNextReelFromController(controller)) {
            return YES;
        }
    }
    return NO;
}

static void YTKACEUpdateShortsProgress(void) {
    BOOL enabled = YTKACEFeatureEnabled(@"shortsProgress");
    CGFloat ratio = YTKACELastShortsDuration > 0.0
        ? (CGFloat)MIN(1.0, MAX(0.0, YTKACELastShortsTime / YTKACELastShortsDuration))
        : 0.0;
    for (UIView *view in YTKACEReelViews.allObjects) {
        CALayer *track = objc_getAssociatedObject(view, YTKACEShortsTrackAssociation);
        CALayer *fill = objc_getAssociatedObject(view, YTKACEShortsFillAssociation);
        track.hidden = !enabled;
        fill.hidden = !enabled;
        if (enabled) {
            CGFloat height = 3.0;
            track.frame = CGRectMake(0.0,
                                     MAX(0.0, CGRectGetHeight(view.bounds) - height),
                                     CGRectGetWidth(view.bounds),
                                     height);
            fill.frame = CGRectMake(0.0, 0.0,
                                    CGRectGetWidth(track.bounds) * ratio,
                                    height);
            YTKACEStyleProgressLayer(fill, CGRectGetWidth(track.bounds));
        }
    }
}

@interface YTKACEShortsPinchTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation YTKACEShortsPinchTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if ([other isKindOfClass:UIPinchGestureRecognizer.class]) return NO;
    if ([other.view isKindOfClass:UIScrollView.class] &&
        other == ((UIScrollView *)other.view).panGestureRecognizer) return NO;
    return YES;
}

- (void)stopPagerUnder:(UIView *)view {
    UIScrollView *pager = nil;
    for (UIView *candidate = view.superview; candidate != nil; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UIScrollView.class]) {
            pager = (UIScrollView *)candidate;
            break;
        }
    }
    if (pager == nil) return;
    CGFloat page = CGRectGetHeight(pager.bounds);
    CGPoint offset = pager.contentOffset;
    pager.panGestureRecognizer.enabled = NO;
    pager.panGestureRecognizer.enabled = YES;
    if (page > 1.0) {
        CGFloat snapped = round(offset.y / page) * page;
        if (fabs(snapped - offset.y) > 0.5) [pager setContentOffset:CGPointMake(offset.x, snapped) animated:YES];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    if (![other isKindOfClass:UIPinchGestureRecognizer.class] || other == gesture) return NO;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.PinchFullscreen");
}

- (void)pinched:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state == UIGestureRecognizerStateBegan) {
        [self stopPagerUnder:pinch.view];
        return;
    }
    if (pinch.state != UIGestureRecognizerStateEnded) return;
    BOOL active = YTKACEShortsNewFullscreenActive();
    if (pinch.scale > 1.0 && !active) {
        YTKACESetShortsNewFullscreen(pinch.view, YES);
    } else if (pinch.scale < 1.0 && active) {
        YTKACESetShortsNewFullscreen(pinch.view, NO);
    }
}
@end

static const void *YTKACEShortsPinchAssociation = &YTKACEShortsPinchAssociation;
static IMP OriginalReelElementLayout;

static void YTKACEReelElementLayout(UIView *receiver, SEL selector) {
    if (OriginalReelElementLayout != NULL) ((void (*)(id, SEL))OriginalReelElementLayout)(receiver, selector);
    if (!YTKACEShortsNewFullscreenActive() || receiver.alpha <= 0.01 || receiver.window == nil) return;
    Class containerClass = NSClassFromString(@"YTReelContainerView");
    UIView *container = receiver.superview;
    for (NSUInteger depth = 0; container != nil && depth < 8 && ![container isKindOfClass:containerClass]; depth++) {
        container = container.superview;
    }
    if (![container isKindOfClass:containerClass]) return;
    YTKACERegisterFadedShortsContainer(container);
    YTKACEFadeShortsElement(receiver);
}

static void YTKACEPrepareNewShortsContainer(UIView *receiver) {
    if (![NSStringFromClass(receiver.class) isEqualToString:@"YTReelContainerView"]) return;
    if (objc_getAssociatedObject(receiver, YTKACEShortsPinchAssociation) == nil) {
        static YTKACEShortsPinchTarget *target;
        if (target == nil) target = [YTKACEShortsPinchTarget new];
        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:target
                                                                                    action:@selector(pinched:)];
        pinch.delegate = target;
        pinch.cancelsTouchesInView = NO;
        [receiver addGestureRecognizer:pinch];
        objc_setAssociatedObject(receiver, YTKACEShortsPinchAssociation, pinch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void YTKACEConfigureReelView(UIView *receiver, BOOL showDownload) {
    [YTKACEReelViews addObject:receiver];
    YTKACEPrepareNewShortsContainer(receiver);
    CALayer *track = objc_getAssociatedObject(receiver, YTKACEShortsTrackAssociation);
    CALayer *fill = objc_getAssociatedObject(receiver, YTKACEShortsFillAssociation);
    if (track == nil) {
        track = [CALayer layer];
        track.backgroundColor = [UIColor colorWithWhite:0.45 alpha:0.55].CGColor;
        track.zPosition = 10000.0;
        fill = [CALayer layer];
        fill.backgroundColor = UIColor.redColor.CGColor;
        objc_setAssociatedObject(receiver, YTKACEShortsFillAssociation,
                                 fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [track addSublayer:fill];
        [receiver.layer addSublayer:track];
        objc_setAssociatedObject(receiver, YTKACEShortsTrackAssociation,
                                 track, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(receiver, YTKACEShortsFillAssociation,
                                 fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (showDownload) {
        YTKACEApplyShortsActionVisibility(receiver);
        YTKACECompactShortsRail(receiver);
    }
    BOOL visibleHost = receiver.window != nil && !receiver.hidden &&
        receiver.alpha > 0.05 && CGRectGetWidth(receiver.bounds) > 200.0 &&
        CGRectGetHeight(receiver.bounds) > 300.0;
    UIView *action = showDownload && visibleHost
        ? YTKACEVisibleShortsAction(receiver)
        : nil;
    UIView *downloadHost = action == nil
        ? YTKACECurrentShortsPlaybackOverlay(receiver)
        : YTKACEShortsPlaybackOverlay(action, receiver);
    if (![NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"]) {
        Class containerClass = NSClassFromString(@"YTReelContainerView");
        UIView *container = nil;
        for (UIView *candidate = action ?: receiver; candidate != nil; candidate = candidate.superview) {
            if (containerClass != Nil && [candidate isKindOfClass:containerClass]) {
                container = candidate;
                break;
            }
        }
        if (container == nil && containerClass != Nil && [receiver isKindOfClass:containerClass]) container = receiver;
        if (container != nil && showDownload && visibleHost) downloadHost = container;
        else if (container == nil && downloadHost != nil &&
                 ![NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"]) downloadHost = nil;
    }
    UIButton *download = objc_getAssociatedObject(
        downloadHost, YTKACEShortsDownloadAssociation);
    if (showDownload && visibleHost && downloadHost != nil &&
        download == nil) {
        download = [UIButton buttonWithType:UIButtonTypeSystem];
        download.tag = YTKACEShortsDownloadTag;
        download.accessibilityIdentifier = @"YTKACE Shorts Download";
        download.accessibilityLabel = YTKACELocalized(@"Download Short");
        download.tintColor = UIColor.whiteColor;
        [download setImage:YTKACEDownloadGlyphImage()
                  forState:UIControlStateNormal];
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                            weight:UIImageSymbolWeightMedium];
        [download setPreferredSymbolConfiguration:configuration
                                  forImageInState:UIControlStateNormal];
        download.layer.shadowColor = UIColor.blackColor.CGColor;
        download.layer.shadowOpacity = 0.55;
        download.layer.shadowRadius = 4.0;
        download.layer.shadowOffset = CGSizeMake(0.0, 2.0);
        download.translatesAutoresizingMaskIntoConstraints = NO;
        [download addTarget:YTKACEShortsDownloadTarget.sharedTarget
                     action:@selector(downloadTapped:)
           forControlEvents:UIControlEventTouchUpInside];
        [downloadHost addSubview:download];
        objc_setAssociatedObject(downloadHost, YTKACEShortsDownloadAssociation,
            download, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (download != nil && download.superview == downloadHost) {
        if (action != nil) {
            objc_setAssociatedObject(download,
                YTKACEShortsDownloadAnchoredAssociation, @YES,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        BOOL railMode = [NSUserDefaults.standardUserDefaults
            integerForKey:@"YTKACE.Preference.Shorts.DownloadPosition"] != 0;
        BOOL anchored = [objc_getAssociatedObject(download,
            YTKACEShortsDownloadAnchoredAssociation) boolValue];
        BOOL legacyHost = [NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"];
        download.hidden = !YTKACEDownloadsEnabled() ||
            (railMode && !anchored && (legacyHost || !YTKACEShortsNewFullscreenActive()));
        YTKACEPositionShortsDownload(downloadHost, action, download);
        [downloadHost bringSubviewToFront:download];
        NSMutableArray<UIView *> *stack =
            [NSMutableArray arrayWithObject:downloadHost];
        NSUInteger duplicates = 0;
        while (stack.count != 0) {
            UIView *candidate = stack.lastObject;
            [stack removeLastObject];
            for (UIView *subview in candidate.subviews) {
                if (subview.tag == YTKACEShortsDownloadTag &&
                    subview != download) {
                    duplicates++;
                    [subview removeFromSuperview];
                } else {
                    [stack addObject:subview];
                }
            }
        }
        (void)duplicates;
    }
    static NSTimeInterval lastResolve = 0.0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (YTKACELatestShortsPlayerResponse == nil || now - lastResolve > 0.5) {
        lastResolve = now;
        id response = YTKACEShortsPlayerResponseFromObject(receiver);
        if (response != nil) {
            YTKACELatestShortsPlayerResponse = response;
        }
    }
    YTKACEUpdateShortsProgress();
}

static void YTKACEReelLayout(UIView *receiver, SEL selector) {
    YTKACEInvokeShortsOriginal(receiver, selector);
    YTKACEConfigureReelView(receiver, NO);
}

static void YTKACEReelOverlayLayout(UIView *receiver, SEL selector) {
    YTKACEInvokeShortsOriginal(receiver, selector);
    YTKACEConfigureReelView(receiver, YES);
}

static BOOL YTKACEShortsViewHasLiveBadge(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 8) return NO;
    Class liveClass = NSClassFromString(@"YTLiveWatchPlaybackOverlayView");
    if (liveClass != Nil && [view isKindOfClass:liveClass]) return YES;
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    if ([name containsString:@"reellive"] || [name containsString:@"liveoverlay"]) return YES;
    NSString *ident = view.accessibilityIdentifier.lowercaseString ?: @"";
    if ([ident containsString:@"reel_live"] || [ident containsString:@"live_stream"]) return YES;
    NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
    if ([label containsString:@"tocca per guardare live"] ||
        [label containsString:@"tap to watch live"] ||
        [label containsString:@"live stream"]) return YES;
    for (UIView *child in view.subviews) {
        if (YTKACEShortsViewHasLiveBadge(child, depth + 1)) return YES;
    }
    return NO;
}

static BOOL YTKACEShortsIsLivePlayback(UIViewController *controller, id player) {
    if (player != nil) {
        for (NSString *selName in @[@"isLivePlayback", @"isLive", @"isLiveStream"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([player respondsToSelector:sel]) {
                NSMethodSignature *sig = [player methodSignatureForSelector:sel];
                if (sig != nil) {
                    const char *type = [sig methodReturnType];
                    if (type != NULL && (type[0] == 'B' || type[0] == 'c')) {
                        if (((BOOL (*)(id, SEL))objc_msgSend)(player, sel)) return YES;
                    }
                }
            }
        }
    }

    if (controller != nil) {
        id currentItem = YTKACEShortsObject(controller, @"activePlaybackSequenceItemController") ?: controller;
        id itemPlayer = YTKACEShortsObject(currentItem, @"player") ?: YTKACEShortsObject(controller, @"player");
        if (itemPlayer != nil && itemPlayer != player) {
            if (YTKACEShortsIsLivePlayback(nil, itemPlayer)) return YES;
        }

        id model = YTKACEShortsObject(currentItem, @"contentModel") ?:
                   YTKACEShortsObject(currentItem, @"reelModel") ?:
                   YTKACEShortsObject(currentItem, @"model") ?:
                   YTKACEShortsObject(controller, @"contentModel");
        if (model != nil) {
            NSString *modelName = NSStringFromClass([model class]).lowercaseString;
            if ([modelName containsString:@"live"]) return YES;
            if (YTKACEShortsObject(model, @"nonVideoContentModel") != nil) return YES;
            for (NSString *selName in @[@"isLive", @"isLivePlayback", @"isLiveStream"]) {
                SEL sel = NSSelectorFromString(selName);
                if ([model respondsToSelector:sel]) {
                    NSMethodSignature *sig = [model methodSignatureForSelector:sel];
                    if (sig != nil) {
                        const char *type = [sig methodReturnType];
                        if (type != NULL && (type[0] == 'B' || type[0] == 'c')) {
                            if (((BOOL (*)(id, SEL))objc_msgSend)(model, sel)) return YES;
                        }
                    }
                }
            }
        }

        id response = YTKACEShortsPlayerResponseFromObject(currentItem) ?:
                      YTKACEShortsPlayerResponseFromObject(controller) ?:
                      YTKACELatestShortsPlayerResponse;
        if (response != nil) {
            id videoDetails = YTKACEShortsObject(response, @"videoDetails");
            if (videoDetails != nil) {
                for (NSString *selName in @[@"isLive", @"isLiveContent", @"isLivePlayback"]) {
                    SEL sel = NSSelectorFromString(selName);
                    if ([videoDetails respondsToSelector:sel]) {
                        NSMethodSignature *sig = [videoDetails methodSignatureForSelector:sel];
                        if (sig != nil) {
                            const char *type = [sig methodReturnType];
                            if (type != NULL && (type[0] == 'B' || type[0] == 'c')) {
                                if (((BOOL (*)(id, SEL))objc_msgSend)(videoDetails, sel)) return YES;
                            }
                        }
                    }
                }
            }
            if (YTKACEShortsObject(response, @"liveBroadcastDetails") != nil) return YES;
        }

        if (controller.isViewLoaded && YTKACEShortsViewHasLiveBadge(controller.view, 0)) {
            return YES;
        }
    }

    return NO;
}

static CFTimeInterval YTKACELastLiveAdvanceTime = 0.0;
static void YTKACEAutoSkipLiveShortIfNeeded(UIViewController *receiver) {
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.LiveHidden")) return;
    if (receiver == nil) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - YTKACELastLiveAdvanceTime < 0.8) return;
    if (YTKACEShortsIsLivePlayback(receiver, nil)) {
        YTKACELastLiveAdvanceTime = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACERequestNextReelFromController(receiver);
        });
    }
}

static void YTKACEShortsControllerLayout(UIViewController *receiver,
                                         SEL selector) {
    YTKACEInvokeShortsOriginal(receiver, selector);
    YTKACEConfigureReelView(receiver.view, YES);
    YTKACEAutoSkipLiveShortIfNeeded(receiver);
    if (![objc_getAssociatedObject(receiver,
            YTKACEShortsInitialRefreshAssociation) boolValue]) {
        objc_setAssociatedObject(receiver,
            YTKACEShortsInitialRefreshAssociation, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIViewController *weakReceiver = receiver;
        for (NSNumber *delay in @[@0.08, @0.30]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    UIViewController *controller = weakReceiver;
                    if (controller.view.window != nil) {
                        YTKACEConfigureReelView(controller.view, YES);
                        YTKACEAutoSkipLiveShortIfNeeded(controller);
                    }
                });
        }
    }
}

static void YTKACEPausedLayout(UIView *receiver, SEL selector) {
    YTKACEInvokeShortsOriginal(receiver, selector);
    BOOL hidden = YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.PauseCardHidden");
    YTKACESetShortsHidden(receiver, hidden);
}

static void YTKACEInteractiveStickerLayout(UIView *receiver, SEL selector) {
    YTKACEInvokeShortsOriginal(receiver, selector);
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        NSStringFromClass(receiver.class).lowercaseString,
        receiver.accessibilityIdentifier.lowercaseString ?: @"",
        receiver.description.lowercaseString ?: @""];
    BOOL product = YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        ([token containsString:@"product"] ||
         [token containsString:@"shopping"]);
    BOOL stickerAd = YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.StickerAdsHidden") &&
        (([token containsString:@"sticker"] &&
          ([token containsString:@"sponsor"] ||
           [token containsString:@"promot"] ||
           [token containsString:@"brand"] ||
           [token containsString:@"product"])) ||
         [token containsString:@"shorts_ads_shopping"]);
    YTKACESetShortsHidden(receiver, product || stickerAd);
}

static void YTKACEInstallShortsLayout(NSString *className, IMP replacement) {
    Class cls = NSClassFromString(className);
    SEL selector = @selector(layoutSubviews);
    if (YTKACEShortsDirectMethod(cls, selector) == NULL) return;
    NSString *key = YTKACEShortsHookKey(cls, selector);
    if ([YTKACEShortsInstalledHooks containsObject:key]) return;
    IMP current = method_getImplementation(class_getInstanceMethod(cls, selector));
    if (YTKACEShortsIsReplacement(current)) return;
    IMP original = NULL;
    if (YTKACEInstallInstanceHook(className, @"layoutSubviews",
                                  replacement, &original) &&
        original != NULL && !YTKACEShortsIsReplacement(original)) {
        YTKACEShortsOriginals[key] =
            [NSValue valueWithPointer:(const void *)original];
        [YTKACEShortsInstalledHooks addObject:key];
    }
}

static void YTKACEInstallShortsController(NSString *className) {
    SEL selector = @selector(viewDidLayoutSubviews);
    Class cls = NSClassFromString(className);
    if (YTKACEShortsDirectMethod(cls, selector) == NULL) return;
    NSString *key = YTKACEShortsHookKey(cls, selector);
    if ([YTKACEShortsInstalledHooks containsObject:key]) return;
    IMP current = method_getImplementation(class_getInstanceMethod(cls, selector));
    if (YTKACEShortsIsReplacement(current)) return;
    IMP original = NULL;
    if (YTKACEInstallInstanceHook(className,
                                  NSStringFromSelector(selector),
                                  (IMP)YTKACEShortsControllerLayout,
                                  &original) && original != NULL &&
        !YTKACEShortsIsReplacement(original)) {
        YTKACEShortsOriginals[key] =
            [NSValue valueWithPointer:(const void *)original];
        [YTKACEShortsInstalledHooks addObject:key];
    }
}

static const void *YTKACEShortsLoopAssociation = &YTKACEShortsLoopAssociation;
static CFTimeInterval YTKACELastShortsAdvanceTime = 0.0;
static NSString *YTKACELastAdvancedShortsToken = nil;
static double YTKACEPrevShortsTime = 0.0;
static NSString *YTKACEPrevShortsToken = nil;

static IMP OriginalReelEnablePIPAutoAdvance;
static IMP OriginalReelShouldAutoAdvance;
static IMP OriginalReelShouldAutoAdvanceInPip;
static IMP OriginalReelContainerAutoAdvanceIfNeeded;
static IMP OriginalReelContainerHandleLoopBehavior;
static IMP OriginalReelPlayerHandleLoopBehavior;

static BOOL YTKACEReelEnablePIPAutoAdvance(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"autoSkipShorts")) return YES;
    return OriginalReelEnablePIPAutoAdvance != NULL
        ? ((BOOL (*)(id, SEL))OriginalReelEnablePIPAutoAdvance)(receiver, selector)
        : NO;
}

static BOOL YTKACEReelShouldAutoAdvance(id receiver, SEL selector) {
    if (YTKACEShortsLimitReached()) return NO;
    if (YTKACEFeatureEnabled(@"autoSkipShorts")) return YES;
    return OriginalReelShouldAutoAdvance != NULL
        ? ((BOOL (*)(id, SEL))OriginalReelShouldAutoAdvance)(receiver, selector)
        : NO;
}

static BOOL YTKACEReelShouldAutoAdvanceInPip(id receiver, SEL selector) {
    if (YTKACEShortsLimitReached()) return NO;
    if (YTKACEFeatureEnabled(@"autoSkipShorts")) return YES;
    return OriginalReelShouldAutoAdvanceInPip != NULL
        ? ((BOOL (*)(id, SEL))OriginalReelShouldAutoAdvanceInPip)(receiver, selector)
        : NO;
}

static BOOL YTKACEReelContainerAutoAdvanceIfNeeded(id receiver, SEL selector) {
    if (YTKACEShortsLimitReached()) return NO;
    if (OriginalReelContainerAutoAdvanceIfNeeded != NULL) {
        if (((BOOL (*)(id, SEL))OriginalReelContainerAutoAdvanceIfNeeded)(receiver, selector)) {
            YTKACELastShortsAdvanceTime = CACurrentMediaTime();
            return YES;
        }
    }
    if (!YTKACEFeatureEnabled(@"autoSkipShorts")) return NO;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - YTKACELastShortsAdvanceTime >= 1.0) {
        if (YTKACERequestNextReelFromController(receiver)) {
            YTKACELastShortsAdvanceTime = now;
        }
    }
    return YES;
}

static void YTKACEReelContainerHandleLoopBehavior(id receiver, SEL selector) {
    if (YTKACEShortsLimitReached()) return;
    if (!YTKACEFeatureEnabled(@"autoSkipShorts") &&
        YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.LoopDisabled")) {
        SEL pause = NSSelectorFromString(@"pause");
        if ([receiver respondsToSelector:pause]) {
            ((void (*)(id, SEL))objc_msgSend)(receiver, pause);
        } else {
            id player = YTKACEShortsObject(receiver, @"player");
            if ([player respondsToSelector:pause]) {
                ((void (*)(id, SEL))objc_msgSend)(player, pause);
            }
        }
        return;
    }
    if (OriginalReelContainerHandleLoopBehavior != NULL) {
        ((void (*)(id, SEL))OriginalReelContainerHandleLoopBehavior)(receiver, selector);
    }
}

static void YTKACEReelPlayerHandleLoopBehavior(id receiver, SEL selector) {
    if (YTKACEShortsLimitReached()) return;
    if (YTKACEFeatureEnabled(@"autoSkipShorts")) {
        CFTimeInterval now = CACurrentMediaTime();
        if (now - YTKACELastShortsAdvanceTime >= 1.0) {
            if (YTKACERequestNextReelFromController(receiver)) {
                YTKACELastShortsAdvanceTime = now;
            }
        }
        return;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.LoopDisabled")) {
        id player = YTKACEShortsObject(receiver, @"player");
        SEL pause = NSSelectorFromString(@"pause");
        if ([player respondsToSelector:pause]) {
            ((void (*)(id, SEL))objc_msgSend)(player, pause);
        }
        return;
    }
    if (OriginalReelPlayerHandleLoopBehavior != NULL) {
        ((void (*)(id, SEL))OriginalReelPlayerHandleLoopBehavior)(receiver, selector);
    }
}

static void YTKACEShortsTimeChanged(NSNotification *notification) {
    id player = notification.object;
    NSArray<UIViewController *> *controllers = YTKACECollectShortsControllers(player);
    UIViewController *shorts = controllers.firstObject;
    if (shorts == nil) {
        return;
    }
    static CFTimeInterval lastLookup = 0.0;
    if (YTKACELatestShortsPlayerResponse == nil ||
        CACurrentMediaTime() - lastLookup > 1.0) {
        lastLookup = CACurrentMediaTime();
        id response = YTKACEShortsPlayerResponseFromObject(player);
        for (UIViewController *vc in controllers) {
            if (response != nil) break;
            response = YTKACEShortsPlayerResponseFromObject(vc);
        }
        if (response != nil) {
            YTKACELatestShortsPlayerResponse = response;
        }
    }
    double time = [notification.userInfo[@"time"] doubleValue];
    double duration = [notification.userInfo[@"duration"] doubleValue];
    if (duration <= 0.0) {
        id activeVideo = YTKACEShortsObject(player, @"activeVideo");
        duration = YTKACEShortsDouble(activeVideo, @[@"totalMediaTime", @"duration"]);
    }
    if (duration <= 0.0) {
        duration = YTKACEShortsDouble(player, @[
            @"currentVideoTotalMediaTime",
            @"currentVideoTotalTime",
            @"currentVideoDuration",
            @"totalMediaTime"
        ]);
    }
    if (duration <= 0.0) {
        duration = YTKACEShortsDouble(shorts, @[
            @"duration",
            @"totalMediaTime",
            @"currentVideoTotalMediaTime"
        ]);
    }
    YTKACELastShortsTime = time;
    YTKACELastShortsDuration = duration;
    YTKACEUpdateShortsProgress();

    if (YTKACEShortsLimitReached()) {
        return;
    }

    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.LiveHidden") &&
        YTKACEShortsIsLivePlayback(shorts, player)) {
        YTKACEAutoSkipLiveShortIfNeeded(shorts);
        return;
    }

    NSString *videoID = YTKACECurrentShortsVideoID(player, controllers);
    NSString *token = videoID.length > 0
        ? videoID
        : [NSString stringWithFormat:@"%p-%.2f", shorts, duration];
    BOOL sameVideo = YTKACEPrevShortsToken != nil && [token isEqualToString:YTKACEPrevShortsToken];
    double prevTime = sameVideo ? YTKACEPrevShortsTime : 0.0;
    YTKACEPrevShortsToken = token;
    YTKACEPrevShortsTime = time;

    BOOL loopWrapped = sameVideo && duration > 1.0 &&
        prevTime >= MAX(1.0, duration - 1.5) &&
        time < 0.85 && time < prevTime - 0.5;

    if (!YTKACEFeatureEnabled(@"autoSkipShorts") && YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.LoopDisabled") &&
        duration > 1.0) {
        if (time < duration * 0.5 && !loopWrapped) {
            objc_setAssociatedObject(shorts, YTKACEShortsLoopAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if ((time >= duration - 0.35 || loopWrapped) &&
                   ![objc_getAssociatedObject(shorts, YTKACEShortsLoopAssociation) boolValue]) {
            objc_setAssociatedObject(shorts, YTKACEShortsLoopAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SEL pause = NSSelectorFromString(@"pause");
            if ([player respondsToSelector:pause]) ((void (*)(id, SEL))objc_msgSend)(player, pause);
        }
        return;
    }
    if (!YTKACEFeatureEnabled(@"autoSkipShorts") || duration <= 1.0) {
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (time < duration * 0.5 && !loopWrapped && (now - YTKACELastShortsAdvanceTime > 0.8)) {
        objc_setAssociatedObject(shorts, YTKACEShortsSkipAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([token isEqualToString:YTKACELastAdvancedShortsToken]) {
            YTKACELastAdvancedShortsToken = nil;
        }
    }

    BOOL reachedEnd = (time >= duration - 0.30 && time > 0.4) || loopWrapped;
    BOOL alreadySkipped = [objc_getAssociatedObject(shorts, YTKACEShortsSkipAssociation) boolValue] &&
        [token isEqualToString:YTKACELastAdvancedShortsToken];
    if (reachedEnd && !alreadySkipped && (now - YTKACELastShortsAdvanceTime >= 1.0)) {
        if (YTKACEAdvanceShort(controllers, player)) {
            YTKACELastShortsAdvanceTime = now;
            YTKACELastAdvancedShortsToken = token;
            objc_setAssociatedObject(shorts, YTKACEShortsSkipAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

void YTKACEInstallShortsHooks(void) {
    if (YTKACEReelViews == nil) {
        YTKACEReelViews = [NSHashTable weakObjectsHashTable];
        YTKACEShortsOriginals = [NSMutableDictionary dictionary];
        YTKACEShortsInstalledHooks = [NSMutableSet set];
        [NSNotificationCenter.defaultCenter
            addObserverForName:@"YTKACEPlaybackTimeDidChange"
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *notification) {
                YTKACEShortsTimeChanged(notification);
            }];
    }
    YTKACEInstallInstanceHook(@"YTReelExperimentConfig",
                              @"enableReelsPIPAutoAdvance",
                              (IMP)YTKACEReelEnablePIPAutoAdvance,
                              &OriginalReelEnablePIPAutoAdvance);
    YTKACEInstallInstanceHook(@"YTReelAutoAdvanceController",
                              @"shouldAutoAdvance",
                              (IMP)YTKACEReelShouldAutoAdvance,
                              &OriginalReelShouldAutoAdvance);
    YTKACEInstallInstanceHook(@"YTReelAutoAdvanceController",
                              @"shouldAutoAdvanceInPip",
                              (IMP)YTKACEReelShouldAutoAdvanceInPip,
                              &OriginalReelShouldAutoAdvanceInPip);
    YTKACEInstallInstanceHook(@"YTReelContainerViewController",
                              @"autoAdvanceIfNeeded",
                              (IMP)YTKACEReelContainerAutoAdvanceIfNeeded,
                              &OriginalReelContainerAutoAdvanceIfNeeded);
    YTKACEInstallInstanceHook(@"YTReelContainerViewController",
                              @"handleLoopBehavior",
                              (IMP)YTKACEReelContainerHandleLoopBehavior,
                              &OriginalReelContainerHandleLoopBehavior);
    YTKACEInstallInstanceHook(@"YTReelPlayerViewController",
                              @"handleLoopBehavior",
                              (IMP)YTKACEReelPlayerHandleLoopBehavior,
                              &OriginalReelPlayerHandleLoopBehavior);
    for (NSString *className in @[
        @"YTReelContentView",
        @"YTReelPlayerView",
        @"YTShortsPlayerView",
        @"YTShortsPlayerViewControllerView",
        @"YTShortsPlayerViewSwift"
    ]) {
        YTKACEInstallShortsLayout(className, (IMP)YTKACEReelLayout);
    }
    YTKACEInstallInstanceHook(@"YTReelElementAsyncComponentView", @"layoutSubviews",
                              (IMP)YTKACEReelElementLayout, &OriginalReelElementLayout);
    YTKACEInstallShortsLayout(@"YTReelWatchPlaybackOverlayView",
                              (IMP)YTKACEReelOverlayLayout);
    for (NSString *className in @[
        @"YTAppReelWatchRootViewController",
        @"YTReelWatchRootViewController",
        @"YTReelContainerViewController",
        @"YTReelPlaybackViewController",
        @"YTReelPlayerViewController",
        @"YTShortsPlayerViewController"
    ]) {
        YTKACEInstallShortsController(className);
    }
    for (NSString *className in @[
        @"YTReelPausedStateCarouselView",
        @"YTReelPlayerPausedStateView"
    ]) {
        YTKACEInstallShortsLayout(className, (IMP)YTKACEPausedLayout);
    }
    for (NSString *className in @[
        @"YTReelInteractiveStickerView",
        @"YTShortsStickersView",
        @"YTShortsStickersViewSwift"
    ]) {
        YTKACEInstallShortsLayout(className,
                                  (IMP)YTKACEInteractiveStickerLayout);
    }
}
