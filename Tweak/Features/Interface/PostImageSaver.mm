#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadLog.h"
#import "CommunityPostMenu.h"

#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTKACEPostImageSaveKey = @"YTKACE.Preference.Posts.SaveImage";

static IMP OriginalZoomNodeVisible;
static __weak id YTKACECurrentZoomNode;
static const void *YTKACEPostSaveButtonKey = &YTKACEPostSaveButtonKey;

@interface YTKACEPostImageSaveTarget : NSObject
+ (instancetype)sharedTarget;
- (void)saveTapped:(UIButton *)sender;
@end

@implementation YTKACEPostImageSaveTarget

+ (instancetype)sharedTarget {
    static YTKACEPostImageSaveTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACEPostImageSaveTarget new]; });
    return target;
}

- (void)saveTapped:(UIButton *)sender {
    id node = YTKACECurrentZoomNode;
    if (node == nil) {
        YTKACEShowNotice(YTKACELocalized(@"The image could not be saved."));
        return;
    }

    SEL urlGetter = NSSelectorFromString(@"URL");
    NSURL *url = [node respondsToSelector:urlGetter]
        ? ((id (*)(id, SEL))objc_msgSend)(node, urlGetter)
        : nil;
    if (url == nil) {
        YTKACEShowNotice(YTKACELocalized(@"The image is still loading."));
        return;
    }

    YTKACEPresentPostImageMenu(url, sender);
}

@end

static UIImage *YTKACEPostSaveIcon(void) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:18.0
                                                           weight:UIImageSymbolWeightSemibold];
        return [UIImage systemImageNamed:@"square.and.arrow.down"
                       withConfiguration:configuration];
    }
    return nil;
}

static void YTKACEAttachSaveButton(UIView *container) {
    UIButton *existing = objc_getAssociatedObject(container, YTKACEPostSaveButtonKey);
    if (existing != nil && existing.superview == container) {
        existing.hidden = NO;
        [container bringSubviewToFront:existing];
        return;
    }
    [existing removeFromSuperview];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:YTKACEPostSaveIcon() forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = YTKACELocalized(@"Image actions");
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.5f;
    button.layer.shadowRadius = 3.0f;
    button.layer.shadowOffset = CGSizeZero;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:[YTKACEPostImageSaveTarget sharedTarget]
               action:@selector(saveTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(container, YTKACEPostSaveButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [container addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                            constant:12.0],
        [button.topAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor
                                        constant:8.0],
        [button.widthAnchor constraintEqualToConstant:44.0],
        [button.heightAnchor constraintEqualToConstant:44.0]
    ]];
}

static UIViewController *YTKACEOwningController(UIView *view) {
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static void YTKACEZoomNodeDidEnterVisibleState(id receiver, SEL selector) {
    if (OriginalZoomNodeVisible != NULL) {
        ((void (*)(id, SEL))OriginalZoomNodeVisible)(receiver, selector);
    }
    if (!YTKACEFeatureEnabled(YTKACEPostImageSaveKey)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SEL viewGetter = NSSelectorFromString(@"view");
        if (![receiver respondsToSelector:viewGetter]) return;
        UIView *view = ((id (*)(id, SEL))objc_msgSend)(receiver, viewGetter);
        if (view.window == nil) return;
        UIViewController *owner = YTKACEOwningController(view);
        if (owner.view == nil) return;

        Class viewerClass =
            NSClassFromString(@"YTInterstitialElementsViewControllerImpl");
        if (viewerClass == Nil || ![owner isKindOfClass:viewerClass]) return;
        YTKACECurrentZoomNode = receiver;
        YTKACEAttachSaveButton(owner.view);
    });
}

static NSString *const YTKACEPostCopyTextKey = @"YTKACE.Preference.Posts.CopyText";
static const void *YTKACEPostCopyGestureKey = &YTKACEPostCopyGestureKey;

static id YTKACENodeValue(id node, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![node respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [node methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(node, selector);
}

static id YTKACEFindExpandableText(id node, NSUInteger depth) {
    if (node == nil || depth > 12) return nil;
    if ([NSStringFromClass([node class]) isEqualToString:@"ELMExpandableTextNode"]) return node;
    for (id child in YTKACENodeValue(node, @"subnodes")) {
        id found = YTKACEFindExpandableText(child, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static NSString *YTKACENodeText(id node, NSUInteger depth) {
    if (node == nil || depth > 4) return nil;
    NSString *text = [YTKACENodeValue(node, @"attributedText") string];
    if (text.length != 0) return text;
    for (id child in YTKACENodeValue(node, @"subnodes")) {
        text = YTKACENodeText(child, depth + 1);
        if (text.length != 0) return text;
    }
    return nil;
}

@interface YTKACEPostCopyHandler : NSObject <UIGestureRecognizerDelegate>
@end

static UIView *YTKACEPostCellForGesture(UIGestureRecognizer *gesture) {
    UIView *cell = [gesture.view hitTest:[gesture locationInView:gesture.view] withEvent:nil];
    while (cell && ![NSStringFromClass(cell.class) isEqual:@"_ASCollectionViewCell"]) cell = cell.superview;
    id node = YTKACENodeValue(cell, @"node");
    NSString *identifier = YTKACENodeValue(node, @"accessibilityIdentifier");
    NSString *token = [NSString stringWithFormat:@"%@ %@", NSStringFromClass([node class]) ?: @"", identifier ?: @""].lowercaseString;
    if ([token containsString:@"community"] || [token containsString:@"backstage"] ||
        [token containsString:@"post_node"] || [NSStringFromClass([node class]) isEqual:@"YTCommentNode"]) return cell;
    return nil;
}

@implementation YTKACEPostCopyHandler
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)gesture;
    return ![other isKindOfClass:UILongPressGestureRecognizer.class];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (!YTKACEMasterEnabled() || !(YTKACEFeatureEnabled(YTKACEPostCopyTextKey) || YTKACEFeatureEnabled(YTKACEPostImageSaveKey))) return NO;
    UIView *cell = YTKACEPostCellForGesture(gesture);
    if (!cell || [cell.nextResponder isKindOfClass:UITextView.class]) return NO;
    return YES;
}
- (void)pressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIView *cell = YTKACEPostCellForGesture(gesture);
    id node = YTKACENodeValue(cell, @"node");
    if (!cell || !node) return;
    id textNode = YTKACEFindExpandableText(node, 0);
    NSString *text = YTKACENodeText(textNode, 0);
    NSURL *imageURL = nil;
    UIView *hit = [gesture.view hitTest:[gesture locationInView:gesture.view] withEvent:nil];
    for (UIView *view = hit; view && view != cell; view = view.superview) {
        id imageNode = YTKACENodeValue(view, @"keepalive_node");
        id URL = YTKACENodeValue(imageNode, @"URL");
        if ([URL isKindOfClass:NSURL.class] && CGRectGetWidth(view.bounds) >= 100) { imageURL = URL; break; }
    }
    [[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    YTKACEPresentCommunityPostMenu(cell, node, text, imageURL);
}
@end

static YTKACEPostCopyHandler *YTKACEPostCopy;

static void YTKACEAttachPostCopyGestures(void) {
    if (!YTKACEMasterEnabled() || !(YTKACEFeatureEnabled(YTKACEPostCopyTextKey) || YTKACEFeatureEnabled(YTKACEPostImageSaveKey))) return;
    if (YTKACEPostCopy == nil) YTKACEPostCopy = [YTKACEPostCopyHandler new];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (objc_getAssociatedObject(window, YTKACEPostCopyGestureKey) != nil) continue;
            UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
                initWithTarget:YTKACEPostCopy action:@selector(pressed:)];
            press.minimumPressDuration = 0.5;
            press.cancelsTouchesInView = NO;
            press.delegate = YTKACEPostCopy;
            [window addGestureRecognizer:press];
            objc_setAssociatedObject(window, YTKACEPostCopyGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

void YTKACEInstallPostImageSaverHooks(void) {
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, YTKACEPreferencesDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                           ^{ YTKACEAttachPostCopyGestures(); });
        }];
    }
    YTKACEInstallInstanceHook(
        @"YTImageZoomNode", @"didEnterVisibleState",
        (IMP)YTKACEZoomNodeDidEnterVisibleState, &OriginalZoomNodeVisible);
    dispatch_async(dispatch_get_main_queue(), ^{ YTKACEAttachPostCopyGestures(); });
}
