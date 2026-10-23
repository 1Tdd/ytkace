#import "SponsorSubmitController.h"
#import "SponsorClient.h"
#import "SponsorPreferences.h"
#import "SponsorHooks.h"
#include "SponsorPreview.h"
#include "../../Runtime/MediaPolicy.h"
#import "../../YTKACE.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Assets.h"
#import "../../UI/Notice.h"
#import "../../UI/OverlayButtonHost.h"
#import "../../Settings/YTKACESettingsPages.h"
#import "../Downloads/StreamResolver.h"
#import "../Downloads/SABRDownloader.h"
#import "../Shorts/ShortsPlayback.h"
#include "../Shorts/ShortsSubmitPlacement.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"


static NSString *YTKACEFormatSponsorTime(double seconds) {
    if (!isfinite(seconds) || seconds < 0.0) seconds = 0.0;
    NSInteger totalSec = (NSInteger)floor(seconds);
    NSInteger fraction = (NSInteger)round((seconds - totalSec) * 100.0);
    if (fraction >= 100) {
        totalSec += 1;
        fraction = 0;
    }
    NSInteger hours = totalSec / 3600;
    NSInteger minutes = (totalSec % 3600) / 60;
    NSInteger secs = totalSec % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld.%02ld",
                (long)hours, (long)minutes, (long)secs, (long)fraction];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld.%02ld",
            (long)minutes, (long)secs, (long)fraction];
}

static UIColor *YTKACESurfaceColor(void) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:0.14 alpha:1.0]
                : [UIColor colorWithWhite:0.95 alpha:1.0];
        }];
    }
    return [UIColor colorWithWhite:0.15 alpha:1.0];
}

static UIColor *YTKACEButtonBgColor(void) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:0.22 alpha:1.0]
                : [UIColor colorWithWhite:0.88 alpha:1.0];
        }];
    }
    return [UIColor colorWithWhite:0.22 alpha:1.0];
}

static UIColor *YTKACETitleColor(void) {
    if (@available(iOS 13.0, *)) {
        return UIColor.labelColor;
    }
    return UIColor.whiteColor;
}

static UIColor *YTKACESubtitleColor(void) {
    if (@available(iOS 13.0, *)) {
        return UIColor.secondaryLabelColor;
    }
    return [UIColor colorWithWhite:0.7 alpha:1.0];
}

static UIViewController *YTKACEFindTopController(void) {
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

@interface YTKACESponsorSubmitCoordinator : NSObject
+ (instancetype)sharedCoordinator;
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, weak) UIButton *button;
@property(nonatomic, strong) NSHashTable<UIButton *> *shortsButtons;
@property(nonatomic, weak) UIButton *menuAnchor;
- (void)handleShortsButtonTap:(UIButton *)sender;
- (void)handleRegularButtonTap;
- (UIButton *)presentationAnchor;
@property(nonatomic, weak) UIView *draftBanner;
@property(nonatomic, copy, nullable) NSString *draftVideoID;
@property(nonatomic, assign) double draftStartTime;
@property(nonatomic, assign) double draftEndTime;
@property(nonatomic, assign) BOOL hasDraftStart;
@property(nonatomic, assign) BOOL hasDraftEnd;
@property(nonatomic, copy) NSString *draftCategory;
- (void)handleButtonTap;
- (void)handleButtonLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)updateButton;
- (void)clearDraft;
@end

@implementation YTKACESponsorSubmitCoordinator

+ (instancetype)sharedCoordinator {
    static YTKACESponsorSubmitCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [YTKACESponsorSubmitCoordinator new];
    });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _draftStartTime = 0.0;
        _draftEndTime = 0.0;
        _draftCategory = @"sponsor";
        _shortsButtons = [NSHashTable weakObjectsHashTable];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(updateButton)
                   name:YTKACEPreferencesDidChangeNotification
                 object:nil];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(videoDidActivate:)
                   name:@"YTKACESponsorVideoDidActivate"
                 object:nil];
    }
    return self;
}

- (void)videoDidActivate:(NSNotification *)note {
    NSString *videoID = note.userInfo[@"videoID"];
    if (self.hasDraftStart && videoID.length > 0 && ![self.draftVideoID isEqualToString:videoID]) {
        [self clearDraft];
    }
}

- (void)dismissDraftBanner {
    UIView *banner = self.draftBanner;
    self.draftBanner = nil;
    if (banner != nil && banner.superview != nil) {
        [UIView animateWithDuration:0.18 animations:^{
            banner.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            [banner removeFromSuperview];
        }];
    }
}

- (void)cancelDraftFromBanner {
    [self clearDraft];
    AudioServicesPlaySystemSound(1520);
    YTKACEShowNotice(YTKACELocalized(@"Draft discarded"));
}

- (void)showDraftStartBannerWithMessage:(NSString *)message {
    if (message.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self dismissDraftBanner];
        UIViewController *presenter = YTKACEFindTopController();
        UIView *host = presenter.view;
        if (host == nil || host.window == nil) {
            YTKACEShowNotice(message);
            return;
        }
        UIView *oldNotice = [host viewWithTag:0x594B4E54];
        [oldNotice removeFromSuperview];

        UIView *banner = [UIView new];
        banner.tag = 0x594B4E54;
        banner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        banner.layer.cornerRadius = 12.0;
        banner.layer.masksToBounds = YES;
        banner.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *label = [UILabel new];
        label.text = message;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        label.numberOfLines = 2;

        UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [cancelBtn setTitle:YTKACELocalized(@"Cancel") forState:UIControlStateNormal];
        [cancelBtn setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
        cancelBtn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBold];
        [cancelBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [cancelBtn setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [cancelBtn addTarget:self action:@selector(cancelDraftFromBanner) forControlEvents:UIControlEventTouchUpInside];

        UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[label, cancelBtn]];
        content.axis = UILayoutConstraintAxisHorizontal;
        content.alignment = UIStackViewAlignmentCenter;
        content.spacing = 16.0;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:content];

        YTKACEApplyGlassBackground(banner, YES);
        [host addSubview:banner];

        UILayoutGuide *safe = host.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-54.0],
            [banner.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-28.0],
            [content.topAnchor constraintEqualToAnchor:banner.topAnchor constant:11.0],
            [content.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16.0],
            [content.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-14.0],
            [content.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-11.0]
        ]];

        self.draftBanner = banner;
        banner.alpha = 0.0;
        banner.transform = CGAffineTransformMakeScale(0.96, 0.96);
        [UIView animateWithDuration:0.22
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            banner.alpha = 1.0;
            banner.transform = CGAffineTransformIdentity;
        } completion:nil];

        __weak YTKACESponsorSubmitCoordinator *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf.draftBanner == banner) {
                [strongSelf dismissDraftBanner];
            }
        });
    });
}

- (void)clearDraft {
    self.draftVideoID = nil;
    self.draftStartTime = 0.0;
    self.draftEndTime = 0.0;
    self.hasDraftStart = NO;
    self.hasDraftEnd = NO;
    [self dismissDraftBanner];
    [self updateButton];
}

- (UIButton *)presentationAnchor {
    return self.menuAnchor.window != nil ? self.menuAnchor : self.button;
}

- (void)handleRegularButtonTap {
    self.menuAnchor = self.button;
    [self handleButtonTap];
}

- (void)handleShortsButtonTap:(UIButton *)sender {
    if (!YTKACESponsorBlockEnabled() || !YTKACEFeatureEnabled(YTKACESponsorShortsKey) ||
        !YTKACESponsorSubmitButtonEnabled()) return;
    NSString *videoID = nil;
    if (!YTKACEResolveShortsPlayback(YTKACEActivePlayerViewController(), &videoID) ||
        (videoID.length > 0 && ![videoID isEqualToString:YTKACESponsorCurrentVideoID()])) {
        YTKACEShowNotice(YTKACELocalized(@"No active video"));
        return;
    }
    self.menuAnchor = sender;
    [self handleButtonTap];
}

- (void)updateButton {
    BOOL enabled = YTKACESponsorBlockEnabled() && YTKACESponsorSubmitButtonEnabled();
    self.button.hidden = !enabled;
    self.button.tintColor = self.hasDraftStart ? YTKACEAccentColor() : UIColor.whiteColor;
    for (UIButton *button in self.shortsButtons.allObjects) {
        button.hidden = !enabled || !YTKACEFeatureEnabled(YTKACESponsorShortsKey);
        button.tintColor = self.hasDraftStart ? YTKACEAccentColor() : UIColor.whiteColor;
        button.accessibilityValue = self.hasDraftStart ? YTKACELocalized(@"Set End Time & Review") : nil;
    }
}

- (void)handleButtonLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (!YTKACESponsorBlockEnabled() || !YTKACESponsorSubmitButtonEnabled()) return;
    AudioServicesPlaySystemSound(1519);
    NSString *videoID = YTKACESponsorCurrentVideoID();
    if (videoID.length == 0) {
        YTKACEShowNotice(YTKACELocalized(@"No active video"));
        return;
    }
    if (![self.draftVideoID isEqualToString:videoID]) [self clearDraft];
    if ([gesture.view isKindOfClass:UIButton.class]) self.menuAnchor = (UIButton *)gesture.view;
    double dur = YTKACESponsorCurrentDuration();
    double curTime = YTKACESponsorCurrentTime();
    if (dur > 0.0 && curTime > dur) curTime = dur;
    double start = self.hasDraftStart ? self.draftStartTime : curTime;
    double end = self.hasDraftEnd ? self.draftEndTime : (self.hasDraftStart ? curTime : start);
    if (dur > 0.0 && self.hasDraftStart && (end <= 0.0 || end >= dur - 0.5)) {
        end = dur;
    }
    YTKACEPresentSponsorSubmitController(videoID, start, end, nil);
}

- (void)presentChapterPickerForVideoID:(NSString *)videoID {
    NSArray<YTKACEVideoChapter *> *chapters = YTKACESponsorCurrentChapters();
    if (chapters.count == 0) {
        YTKACEShowNotice(YTKACELocalized(@"No chapters found for this video"));
        return;
    }
    UIViewController *presenter = YTKACEFindTopController();
    if (!presenter) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:YTKACELocalized(@"Select Video Chapter")
                         message:YTKACELocalized(@"Choose a chapter to fill as a segment:")
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (YTKACEVideoChapter *ch in chapters) {
        NSString *cat = YTKACESponsorCategoryTitle(ch.suggestedCategory);
        NSString *prefix = ch.isLikelySponsor ? @"★ " : @"";
        NSString *title = [NSString stringWithFormat:@"%@%@ (%@ - %@) [%@]",
            prefix,
            ch.title,
            YTKACEFormatSponsorTime(ch.startTime),
            YTKACEFormatSponsorTime(ch.endTime),
            cat];

        UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(__unused UIAlertAction *act) {
            YTKACEPresentSponsorSubmitController(videoID, ch.startTime, ch.endTime, nil);
        }];
        [alert addAction:action];
    }
    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    if (alert.popoverPresentationController != nil) {
        if (self.presentationAnchor != nil && self.presentationAnchor.window != nil) {
            alert.popoverPresentationController.sourceView = self.presentationAnchor;
            alert.popoverPresentationController.sourceRect = self.presentationAnchor.bounds;
        } else if (presenter.view != nil) {
            alert.popoverPresentationController.sourceView = presenter.view;
            alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1.0, 1.0);
        }
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)presentSegmentsViewerForVideoID:(NSString *)videoID {
    NSArray<NSDictionary<NSString *, id> *> *segments = YTKACESponsorCurrentSegments();
    if (segments.count == 0) {
        YTKACEShowNotice(YTKACELocalized(@"No SponsorBlock segments found for this video"));
        return;
    }
    UIViewController *presenter = YTKACEFindTopController();
    if (!presenter) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:YTKACELocalized(@"Current Video Segments")
                         message:YTKACELocalized(@"Tap a segment to jump or vote:")
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSDictionary *seg in segments) {
        double start = [seg[@"start"] doubleValue];
        double end = [seg[@"end"] doubleValue];
        NSString *cat = seg[@"category"] ?: @"sponsor";
        NSString *actType = [seg[@"actionType"] isKindOfClass:NSString.class] ? seg[@"actionType"] : @"skip";
        NSString *title = [actType isEqualToString:@"full"]
            ? [NSString stringWithFormat:@"%@: %@", YTKACESponsorCategoryTitle(cat), YTKACELocalized(@"Full Video")]
            : [NSString stringWithFormat:@"%@: %@ - %@ (%.1fs)",
                YTKACESponsorCategoryTitle(cat),
                YTKACEFormatSponsorTime(start),
                YTKACEFormatSponsorTime(end),
                MAX(0.0, end - start)];

        UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(__unused UIAlertAction *act) {
            [self presentSegmentDetailForSegment:seg videoID:videoID];
        }];
        [alert addAction:action];
    }

    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    if (alert.popoverPresentationController != nil) {
        if (self.presentationAnchor != nil && self.presentationAnchor.window != nil) {
            alert.popoverPresentationController.sourceView = self.presentationAnchor;
            alert.popoverPresentationController.sourceRect = self.presentationAnchor.bounds;
        } else if (presenter.view != nil) {
            alert.popoverPresentationController.sourceView = presenter.view;
            alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1.0, 1.0);
        }
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)presentSegmentDetailForSegment:(NSDictionary *)seg videoID:(__unused NSString *)videoID {
    UIViewController *presenter = YTKACEFindTopController();
    if (!presenter) return;

    double start = [seg[@"start"] doubleValue];
    double end = [seg[@"end"] doubleValue];
    NSString *cat = seg[@"category"] ?: @"sponsor";
    NSString *actType = [seg[@"actionType"] isKindOfClass:NSString.class] ? seg[@"actionType"] : @"skip";
    NSString *uuid = seg[@"uuid"] ?: @"";

    NSString *title = [actType isEqualToString:@"full"]
        ? [NSString stringWithFormat:@"%@ (%@)", YTKACESponsorCategoryTitle(cat), YTKACELocalized(@"Full Video")]
        : [NSString stringWithFormat:@"%@ (%@ - %@)",
           YTKACESponsorCategoryTitle(cat),
           YTKACEFormatSponsorTime(start),
           YTKACEFormatSponsorTime(end)];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:YTKACELocalized(@"Choose an action for this segment:")
                  preferredStyle:UIAlertControllerStyleActionSheet];

    if (![actType isEqualToString:@"full"]) {
        [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Jump to Segment")
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *action) {
            YTKACESponsorSeek(start);
            YTKACEPlayYouTubePlayer();
            AudioServicesPlaySystemSound(1519);
        }]];
    }

    if (uuid.length > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Upvote Segment (Thumbs Up)")
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *action) {
            [YTKACESponsorClient.sharedClient voteForSegmentUUID:uuid type:1 completion:^(BOOL success, NSString *message) {
                AudioServicesPlaySystemSound(success ? 1519 : 1520);
                if (success) {
                    YTKACESponsorRefreshCurrentVideo();
                }
                YTKACEShowNotice(success ? YTKACELocalized(@"Upvote submitted!") : (message ?: YTKACELocalized(@"Voting failed")));
            }];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Downvote Segment (Thumbs Down)")
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(__unused UIAlertAction *action) {
            [YTKACESponsorClient.sharedClient voteForSegmentUUID:uuid type:0 completion:^(BOOL success, NSString *message) {
                AudioServicesPlaySystemSound(success ? 1519 : 1520);
                if (success) {
                    YTKACESponsorRefreshCurrentVideo();
                }
                YTKACEShowNotice(success ? YTKACELocalized(@"Downvote submitted!") : (message ?: YTKACELocalized(@"Voting failed")));
            }];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    if (alert.popoverPresentationController != nil) {
        if (self.presentationAnchor != nil && self.presentationAnchor.window != nil) {
            alert.popoverPresentationController.sourceView = self.presentationAnchor;
            alert.popoverPresentationController.sourceRect = self.presentationAnchor.bounds;
        } else if (presenter.view != nil) {
            alert.popoverPresentationController.sourceView = presenter.view;
            alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1.0, 1.0);
        }
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)handleButtonTap {
    NSString *videoID = YTKACESponsorCurrentVideoID();
    if (videoID.length == 0) {
        YTKACEShowNotice(YTKACELocalized(@"No active video"));
        return;
    }

    if (![self.draftVideoID isEqualToString:videoID]) {
        [self clearDraft];
        self.draftVideoID = videoID;
    }

    BOOL isShort = YTKACEResolveShortsPlayback(YTKACEActivePlayerViewController(), NULL);
    double dur = YTKACESponsorCurrentDuration();
    if (dur <= 0.0) {
        for (YTKACEVideoChapter *ch in YTKACESponsorCurrentChapters()) {
            if (ch.endTime > dur) dur = ch.endTime;
        }
    }
    double now = YTKACESponsorCurrentTime();
    if (dur > 0.0) {
        if (now > dur || now >= dur - (isShort ? 0.05 : 1.5) || (now < 1.0 && self.hasDraftStart && self.draftStartTime >= 1.0)) {
            now = dur;
        }
    }
    NSString *nowText = YTKACEFormatSponsorTime(now);
    __weak YTKACESponsorSubmitCoordinator *weakSelf = self;

    if (!self.hasDraftStart) {
        NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];

        NSArray *segments = YTKACESponsorCurrentSegments();
        NSDictionary *highlightSeg = nil;
        for (NSDictionary *seg in segments) {
            if ([seg[@"category"] isEqualToString:@"poi_highlight"] ||
                [seg[@"actionType"] isEqualToString:@"poi"]) {
                highlightSeg = seg;
                break;
            }
        }
        if (highlightSeg != nil) {
            double hlTime = [highlightSeg[@"start"] doubleValue];
            [actions addObject:@{
                @"title": [NSString stringWithFormat:@"%@ (%@)",
                           YTKACELocalized(@"Jump to Highlight"),
                           YTKACEFormatSponsorTime(hlTime)],
                @"icon": [UIImage systemImageNamed:@"scope"] ?: [UIImage new],
                @"handler": [^{
                    if (![videoID isEqualToString:YTKACESponsorCurrentVideoID()]) return;
                    YTKACESponsorSeek(hlTime);
                    YTKACEPlayYouTubePlayer();
                    AudioServicesPlaySystemSound(1519);
                } copy]
            }];
        }

        if (segments.count > 0) {
            [actions addObject:@{
                @"title": [NSString stringWithFormat:@"%@ (%lu)...",
                           YTKACELocalized(@"View Segments & Vote"), (unsigned long)segments.count],
                @"icon": [UIImage systemImageNamed:@"hand.thumbsup"] ?: [UIImage new],
                @"handler": [^{
                    YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                    if (strongSelf) {
                        [strongSelf presentSegmentsViewerForVideoID:videoID];
                    }
                } copy]
            }];
        }

        NSString *channelTitle = YTKACESponsorCurrentChannelTitle();
        if (channelTitle.length > 0) {
            BOOL whitelisted = YTKACESponsorIsChannelWhitelisted(channelTitle);
            NSString *wlTitle = whitelisted
                ? [NSString stringWithFormat:@"%@: \"%@\"", YTKACELocalized(@"Remove from Whitelist"), channelTitle]
                : [NSString stringWithFormat:@"%@: \"%@\"", YTKACELocalized(@"Whitelist Channel"), channelTitle];
            [actions addObject:@{
                @"title": wlTitle,
                @"icon": [UIImage systemImageNamed:whitelisted ? @"star.slash" : @"star.fill"] ?: [UIImage new],
                @"handler": [^{
                    YTKACESponsorSetChannelWhitelisted(channelTitle, !whitelisted);
                    AudioServicesPlaySystemSound(1519);
                    NSString *noticeMsg = !whitelisted
                        ? [NSString stringWithFormat:@"%@: %@", YTKACELocalized(@"Channel whitelisted"), channelTitle]
                        : [NSString stringWithFormat:@"%@: %@", YTKACELocalized(@"Channel removed from whitelist"), channelTitle];
                    YTKACEShowNotice(noticeMsg);
                } copy]
            }];
        }

        NSArray<YTKACEVideoChapter *> *chapters = YTKACESponsorCurrentChapters();
        YTKACEVideoChapter *sponsorChapter = nil;
        for (YTKACEVideoChapter *ch in chapters) {
            if (ch.isLikelySponsor) {
                sponsorChapter = ch;
                break;
            }
        }
        if (sponsorChapter != nil) {
            NSString *chTitle = sponsorChapter.title.length > 25
                ? [NSString stringWithFormat:@"%@...", [sponsorChapter.title substringToIndex:22]]
                : sponsorChapter.title;
            NSString *timeRange = [NSString stringWithFormat:@"%@ - %@",
                YTKACEFormatSponsorTime(sponsorChapter.startTime),
                YTKACEFormatSponsorTime(sponsorChapter.endTime)];
            [actions addObject:@{
                @"title": [NSString stringWithFormat:@"%@: \"%@\" (%@)",
                           YTKACELocalized(@"Sponsor Chapter"), chTitle, timeRange],
                @"icon": [UIImage systemImageNamed:@"sparkles"] ?: [UIImage new],
                @"handler": [^{
                    YTKACEPresentSponsorSubmitController(videoID,
                                                         sponsorChapter.startTime,
                                                         sponsorChapter.endTime,
                                                         nil);
                } copy]
            }];
        }
        if (chapters.count > 0) {
            [actions addObject:@{
                @"title": [NSString stringWithFormat:@"%@ (%lu)...",
                           YTKACELocalized(@"Select from Chapters"), (unsigned long)chapters.count],
                @"icon": [UIImage systemImageNamed:@"list.bullet.rectangle"] ?: [UIImage new],
                @"handler": [^{
                    YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                    if (strongSelf) {
                        [strongSelf presentChapterPickerForVideoID:videoID];
                    }
                } copy]
            }];
        }

        [actions addObject:@{
            @"title": [NSString stringWithFormat:@"%@ (%@)", YTKACELocalized(@"Set Start Time"), nowText],
            @"icon": [UIImage systemImageNamed:@"timer"] ?: [UIImage new],
            @"handler": [^{
                YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                if (!strongSelf || ![videoID isEqualToString:YTKACESponsorCurrentVideoID()]) return;
                strongSelf.draftVideoID = videoID;
                strongSelf.draftStartTime = now;
                strongSelf.hasDraftStart = YES;
                [strongSelf updateButton];
                AudioServicesPlaySystemSound(1519);
                [strongSelf showDraftStartBannerWithMessage:[NSString stringWithFormat:@"%@: %@",
                    YTKACELocalized(@"Segment start set"), nowText]];
            } copy]
        }];
        [actions addObject:@{
            @"title": YTKACELocalized(@"Open Segment Editor..."),
            @"icon": [UIImage systemImageNamed:@"square.and.pencil"] ?: [UIImage new],
            @"handler": [^{
                YTKACEPresentSponsorSubmitController(videoID, now, now, nil);
            } copy]
        }];
        [actions addObject:@{
            @"title": YTKACELocalized(isShort ? @"Label Entire Short..." : @"Mark Full Video..."),
            @"icon": [UIImage systemImageNamed:@"film.stack"] ?: [UIImage new],
            @"handler": [^{
                YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf presentFullVideoPickerForVideoID:videoID];
                }
            } copy]
        }];
        [actions addObject:@{
            @"title": YTKACELocalized(@"SponsorBlock Settings"),
            @"icon": [UIImage systemImageNamed:@"gearshape"] ?: [UIImage new],
            @"handler": [^{
                UIViewController *presenter = YTKACEFindTopController();
                UIViewController *settings = YTKACEMakeSponsorBlockController();
                if (presenter && settings) {
                    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
                    nav.modalPresentationStyle = UIModalPresentationPageSheet;
                    if (@available(iOS 15.0, *)) {
                        UISheetPresentationController *sheet = nav.sheetPresentationController;
                        sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
                        sheet.prefersGrabberVisible = YES;
                        sheet.prefersEdgeAttachedInCompactHeight = NO;
                        sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = YES;
                    }
                    if (YTKACELiquidGlassAvailable()) {
                        YTKACEApplyMenuGlassBackground(nav.view, 24.0);
                        nav.navigationBar.backgroundColor = UIColor.clearColor;
                        nav.navigationBar.translucent = YES;
                        [nav.navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
                        nav.navigationBar.shadowImage = [UIImage new];
                    }
                    [presenter presentViewController:nav animated:YES completion:nil];
                }
            } copy]
        }];
        YTKACEPresentNativeSheet(YTKACELocalized(@"SponsorBlock"),
                                 YTKACELocalized(@"Mark segment to submit"),
                                 self.presentationAnchor,
                                 actions);
    } else {
        [self dismissDraftBanner];
        NSString *startText = YTKACEFormatSponsorTime(self.draftStartTime);
        NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
        [actions addObject:@{
            @"title": [NSString stringWithFormat:@"%@ (%@ → %@)...",
                       YTKACELocalized(@"Set End Time & Review"), startText, nowText],
            @"icon": [UIImage systemImageNamed:@"checkmark.circle"] ?: [UIImage new],
            @"handler": [^{
                YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                if (!strongSelf || ![videoID isEqualToString:YTKACESponsorCurrentVideoID()]) return;
                strongSelf.draftEndTime = now;
                strongSelf.hasDraftEnd = YES;
                YTKACEPresentSponsorSubmitController(videoID, strongSelf.draftStartTime, now, nil);
            } copy]
        }];
        if (dur > self.draftStartTime) {
            [actions addObject:@{
                @"title": [NSString stringWithFormat:@"%@ (%@ → %@)...",
                           YTKACELocalized(@"Set End to Video End"), startText, YTKACEFormatSponsorTime(dur)],
                @"icon": [UIImage systemImageNamed:@"forward.end.alt"] ?: [UIImage new],
                @"handler": [^{
                    YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                    if (!strongSelf || ![videoID isEqualToString:YTKACESponsorCurrentVideoID()]) return;
                    strongSelf.draftEndTime = dur;
                    strongSelf.hasDraftEnd = YES;
                    YTKACEPresentSponsorSubmitController(videoID, strongSelf.draftStartTime, dur, nil);
                } copy]
            }];
        }
        [actions addObject:@{
            @"title": YTKACELocalized(@"Edit Segment..."),
            @"icon": [UIImage systemImageNamed:@"slider.horizontal.3"] ?: [UIImage new],
            @"handler": [^{
                YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                if (!strongSelf || ![videoID isEqualToString:YTKACESponsorCurrentVideoID()]) return;
                double end = strongSelf.hasDraftEnd ? strongSelf.draftEndTime : now;
                YTKACEPresentSponsorSubmitController(videoID, strongSelf.draftStartTime, end, nil);
            } copy]
        }];
        double rawCurTime = YTKACESponsorCurrentTime();
        if (dur > 0.0 && rawCurTime > dur) rawCurTime = dur;
        NSString *rawCurText = YTKACEFormatSponsorTime(rawCurTime);
        [actions addObject:@{
            @"title": [NSString stringWithFormat:@"%@ (%@)", YTKACELocalized(@"Update Start Time"), rawCurText],
            @"icon": [UIImage systemImageNamed:@"arrow.counterclockwise"] ?: [UIImage new],
            @"handler": [^{
                YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                if (!strongSelf || ![videoID isEqualToString:YTKACESponsorCurrentVideoID()]) return;
                double curTime = YTKACESponsorCurrentTime();
                double curDur = YTKACESponsorCurrentDuration();
                if (curDur > 0.0 && curTime > curDur) curTime = curDur;
                strongSelf.draftStartTime = curTime;
                [strongSelf updateButton];
                AudioServicesPlaySystemSound(1519);
                [strongSelf showDraftStartBannerWithMessage:[NSString stringWithFormat:@"%@: %@",
                    YTKACELocalized(@"Segment start updated"), YTKACEFormatSponsorTime(curTime)]];
            } copy]
        }];
        [actions addObject:@{
            @"title": YTKACELocalized(@"Cancel Segment"),
            @"icon": [UIImage systemImageNamed:@"xmark.circle"] ?: [UIImage new],
            @"handler": [^{
                YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                if (!strongSelf || ![videoID isEqualToString:YTKACESponsorCurrentVideoID()]) return;
                [strongSelf clearDraft];
                AudioServicesPlaySystemSound(1520);
                YTKACEShowNotice(YTKACELocalized(@"Draft discarded"));
            } copy]
        }];
        YTKACEPresentNativeSheet(YTKACELocalized(@"SponsorBlock Draft"),
                                 [NSString stringWithFormat:@"%@: %@", YTKACELocalized(@"Recording segment from"), startText],
                                 self.presentationAnchor,
                                 actions);
    }
}

- (void)presentFullVideoPickerForVideoID:(NSString *)videoID {
    BOOL isShort = YTKACEResolveShortsPlayback(YTKACEActivePlayerViewController(), NULL);
    void (^openFullEditor)(NSString *) = ^(NSString *categoryID) {
        if (![videoID isEqualToString:YTKACESponsorCurrentVideoID()]) return;
        UIViewController *presenter = YTKACEFindTopController();
        if (!presenter) return;
        YTKACESponsorSubmitController *controller = [YTKACESponsorSubmitController new];
        controller.videoID = videoID.length > 0 ? videoID : YTKACESponsorCurrentVideoID();
        controller.videoTitle = YTKACESponsorCurrentVideoTitle();
        controller.videoDuration = YTKACESponsorCurrentDuration();
        controller.startTime = 0.0;
        controller.endTime = controller.videoDuration;
        controller.selectedCategory = categoryID;
        controller.actionType = @"full";

        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sheet = nav.sheetPresentationController;
            sheet.detents = @[
                UISheetPresentationControllerDetent.mediumDetent,
                UISheetPresentationControllerDetent.largeDetent
            ];
            sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierMedium;
            sheet.largestUndimmedDetentIdentifier = UISheetPresentationControllerDetentIdentifierMedium;
            sheet.prefersGrabberVisible = YES;
            sheet.prefersEdgeAttachedInCompactHeight = NO;
            sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = YES;
        }
        if (YTKACELiquidGlassAvailable()) {
            YTKACEApplyMenuGlassBackground(nav.view, 24.0);
            nav.navigationBar.backgroundColor = UIColor.clearColor;
            nav.navigationBar.translucent = YES;
            [nav.navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
            nav.navigationBar.shadowImage = [UIImage new];
        }
        [presenter presentViewController:nav animated:YES completion:nil];
    };

    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    [actions addObject:@{
        @"title": [NSString stringWithFormat:@"%@: %@", YTKACELocalized(isShort ? @"Entire Short" : @"Full Video"), YTKACESponsorCategoryTitle(@"sponsor")],
        @"subtitle": YTKACESponsorCategoryDescription(@"sponsor"),
        @"icon": [UIImage systemImageNamed:@"dollarsign.circle.fill"] ?: [UIImage new],
        @"handler": [^{
            openFullEditor(@"sponsor");
        } copy]
    }];
    [actions addObject:@{
        @"title": [NSString stringWithFormat:@"%@: %@", YTKACELocalized(isShort ? @"Entire Short" : @"Full Video"), YTKACESponsorCategoryTitle(@"selfpromo")],
        @"subtitle": YTKACESponsorCategoryDescription(@"selfpromo"),
        @"icon": [UIImage systemImageNamed:@"megaphone.fill"] ?: [UIImage new],
        @"handler": [^{
            openFullEditor(@"selfpromo");
        } copy]
    }];

    YTKACEPresentNativeSheet(YTKACELocalized(isShort ? @"Label Entire Short..." : @"Mark Full Video..."),
                             YTKACELocalized(isShort ? @"Labels the entire Short without skipping it. Choose a category:" : @"Choose a category for the entire video:"),
                             self.presentationAnchor,
                             actions);
}

@end

typedef NS_ENUM(NSInteger, YTKACESponsorPreviewRequest) {
    YTKACESponsorPreviewRequestNone,
    YTKACESponsorPreviewRequestSeek,
    YTKACESponsorPreviewRequestPlay,
    YTKACESponsorPreviewRequestCut
};

static void *YTKACESponsorPreviewItemContext = &YTKACESponsorPreviewItemContext;

@interface YTKACESponsorSubmitController ()
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIView *contentView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *videoIDBadge;
@property(nonatomic, strong) UILabel *durationLabel;
@property(nonatomic, strong) UIView *videoPreviewContainer;
@property(nonatomic, strong) AVPlayer *previewPlayer;
@property(nonatomic, strong) AVPlayerLayer *previewPlayerLayer;
@property(nonatomic, strong) UIImageView *fallbackThumbnailView;
@property(nonatomic, strong) UIView *previewCategoryDot;
@property(nonatomic, strong) UILabel *previewCategoryLabel;
@property(nonatomic, strong) UILabel *previewTimeLabel;
@property(nonatomic, strong) UILabel *previewStatusLabel;
@property(nonatomic, strong) UIButton *previewPlayPauseButton;
@property(nonatomic, strong) UIButton *previewSeekStartButton;
@property(nonatomic, strong) UIButton *previewSeekEndButton;
@property(nonatomic, strong) UIButton *previewCutButton;
@property(nonatomic, assign) BOOL isPlaying;
@property(nonatomic, strong) AVURLAsset *previewVideoAsset;
@property(nonatomic, strong) AVURLAsset *previewAudioAsset;
@property(nonatomic, strong) id previewTimeObserver;
@property(nonatomic, strong) id previewBoundaryObserver;
@property(nonatomic, strong) NSTimer *previewWatchdog;
@property(nonatomic, assign) BOOL previewVisible;
@property(nonatomic, assign) BOOL previewLoading;
@property(nonatomic, assign) BOOL previewTriedFreshResponse;
@property(nonatomic, assign) BOOL previewSeeking;
@property(nonatomic, assign) NSUInteger previewLoadGeneration;
@property(nonatomic, assign) NSUInteger previewSeekGeneration;
@property(nonatomic, assign) YTKACESponsorPreviewRequest pendingPreviewRequest;
@property(nonatomic, assign) double previewSeekTime;
@property(nonatomic, assign) double previewLastMediaTime;
@property(nonatomic, assign) CFTimeInterval previewLastProgress;
@property(nonatomic, strong) UILabel *startTimeLabel;
@property(nonatomic, strong) UILabel *startSecLabel;
@property(nonatomic, strong) UILabel *endTimeLabel;
@property(nonatomic, strong) UILabel *endSecLabel;
@property(nonatomic, strong) UIView *lengthBadgeView;
@property(nonatomic, strong) UILabel *lengthBadgeLabel;
@property(nonatomic, strong) UILabel *categoryDescLabel;
@property(nonatomic, strong) UISegmentedControl *actionSegmentedControl;
@property(nonatomic, strong) UIButton *chapterButton;
@property(nonatomic, strong) UIButton *previewSkipButton;
@property(nonatomic, strong) UIButton *submitButton;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) NSMutableArray<UIButton *> *categoryButtons;
- (double)currentPreviewTime;
- (void)setupPreviewPlayer;
- (void)loadPreviewResponse:(id)response generation:(NSUInteger)generation;
- (void)installPreviewItem:(AVPlayerItem *)item;
- (void)tearDownPreviewPlayer;
- (void)previewFailed;
- (void)requestPreviewAt:(double)time play:(BOOL)play;
- (void)performPendingPreviewRequest;
- (void)seekPreviewTo:(double)time completion:(dispatch_block_t)completion;
- (void)playPreviewIfRequested;
- (void)updatePreviewPlayback;
- (void)playPreview;
- (void)pausePreview;
- (void)updatePlayPauseButtonUI;
- (void)stopCutPreview;
- (void)beginCutPreview;
- (void)handleCutPreviewAction:(YTKACESponsorPreview::Action)action;
- (void)finishCutPreview;
@end

@implementation YTKACESponsorSubmitController {
    YTKACESponsorPreview _cutPreview;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _selectedCategory = @"sponsor";
        _actionType = @"skip";
        _categoryButtons = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if ([self.videoID isEqualToString:YTKACESponsorCurrentVideoID()] &&
        YTKACEResolveShortsPlayback(YTKACEActivePlayerViewController(), NULL)) {
        // Keep Shorts auto-advance from replacing the clip while its editor is open.
        YTKACEPauseYouTubePlayer();
    }
    if (YTKACELiquidGlassAvailable()) {
        YTKACEApplyMenuGlassBackground(self.view, 0.0);
        self.view.backgroundColor = UIColor.clearColor;
    } else {
        self.view.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:0.08 alpha:1.0]
                : UIColor.systemBackgroundColor;
        }];
    }

    self.title = YTKACELocalized(@"Submit Segment");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:YTKACELocalized(@"Cancel")
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(cancelTapped)];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:YTKACELocalized(@"Submit")
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(submitTapped)];

    [self setupScrollView];
    [self buildUI];
    [self updateTimeLabels];
    [self updateCategorySelection];
    self.previewSeekTime = self.startTime;
    self.pendingPreviewRequest = YTKACESponsorPreviewRequestSeek;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(previewAppWillResignActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (YTKACELiquidGlassAvailable() && self.navigationController != nil) {
        self.navigationController.navigationBar.backgroundColor = UIColor.clearColor;
        self.navigationController.navigationBar.translucent = YES;
        [self.navigationController.navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
        self.navigationController.navigationBar.shadowImage = [UIImage new];
    }
    if (self.chapterButton != nil) {
        NSArray<YTKACEVideoChapter *> *chapters = YTKACESponsorCurrentChapters();
        NSString *btnTitle = chapters.count > 0
            ? [NSString stringWithFormat:@"%@ (%lu)", YTKACELocalized(@"Select from Video Chapters"), (unsigned long)chapters.count]
            : YTKACELocalized(@"Select from Video Chapters");
        [self.chapterButton setTitle:btnTitle forState:UIControlStateNormal];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.previewVisible = YES;
    [self setupPreviewPlayer];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.previewPlayerLayer != nil && self.videoPreviewContainer != nil) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.previewPlayerLayer.frame = self.videoPreviewContainer.bounds;
        [CATransaction commit];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.previewVisible = NO;
    self.previewSeekTime = [self currentPreviewTime];
    [self tearDownPreviewPlayer];
    self.pendingPreviewRequest = YTKACESponsorPreviewRequestSeek;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self tearDownPreviewPlayer];
}

- (void)setupPreviewPlayer {
    if (!self.previewVisible || self.previewLoading || self.previewPlayer != nil || self.videoID.length == 0) return;
    self.previewLoading = YES;
    self.previewStatusLabel.text = YTKACELocalized(@"Loading preview…");
    NSUInteger generation = ++self.previewLoadGeneration;
    __weak YTKACESponsorSubmitController *weakSelf = self;
    void (^configure)(id) = ^(id response) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACESponsorSubmitController *controller = weakSelf;
            if (!controller.previewVisible || controller.previewLoadGeneration != generation) return;
            if (response == nil) [controller previewFailed];
            else [controller loadPreviewResponse:response generation:generation];
        });
    };
    id cached = self.previewTriedFreshResponse ? nil : YTKACECachedPlayerResponse(self.videoID);
    if (cached != nil) configure(cached);
    else {
        self.previewTriedFreshResponse = YES;
        YTKACEResolveFreshPlayerResponse(self.videoID, ^(id response, __unused NSError *error) {
            configure(response);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTKACESponsorSubmitController *controller = weakSelf;
        if (controller.previewLoadGeneration == generation && controller.previewLoading) [controller previewFailed];
    });
}

- (void)loadPreviewResponse:(id)response generation:(NSUInteger)generation {
    YTKACEStreamOption *video = [YTKACEStreamResolver bestPiPVideoFromPlayerResponse:response];
    if (video.URL == nil) {
        // Adaptive streams have separate audio. Never play a video-only URL on its own.
        for (YTKACEStreamOption *option in [YTKACEStreamResolver videoOptionsFromPlayerResponse:response]) {
            if (option.URL != nil && [option.mimeType containsString:@"video/mp4"] && option.height <= 720) {
                video = option;
                break;
            }
        }
    }
    YTKACEStreamOption *audio = nil;
    if (video.isAdaptive) {
        for (YTKACEStreamOption *option in [YTKACEStreamResolver audioOptionsFromPlayerResponse:response]) {
            if (option.URL != nil && [option.mimeType containsString:@"mp4"]) { audio = option; break; }
        }
    }
    if (video.URL == nil || (video.isAdaptive && audio.URL == nil)) { [self previewFailed]; return; }

    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:video.URL options:nil];
    AVURLAsset *audioAsset = audio.URL != nil ? [AVURLAsset URLAssetWithURL:audio.URL options:nil] : nil;
    self.previewVideoAsset = videoAsset;
    self.previewAudioAsset = audioAsset;
    NSArray<NSString *> *keys = @[@"playable", @"tracks", @"duration"];
    dispatch_group_t group = dispatch_group_create();
    for (AVURLAsset *asset in audioAsset != nil ? @[videoAsset, audioAsset] : @[videoAsset]) {
        dispatch_group_enter(group);
        [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{ dispatch_group_leave(group); }];
    }
    __weak YTKACESponsorSubmitController *weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        YTKACESponsorSubmitController *controller = weakSelf;
        if (!controller.previewVisible || controller.previewLoadGeneration != generation) return;
        if (!videoAsset.playable || [videoAsset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
            [controller previewFailed]; return;
        }
        AVAsset *asset = videoAsset;
        if (audioAsset != nil) {
            AVAssetTrack *videoTrack = [videoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            AVAssetTrack *audioTrack = [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
            CMTime duration = CMTimeMinimum(videoAsset.duration, audioAsset.duration);
            if ([audioAsset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded ||
                !audioAsset.playable || videoTrack == nil || audioTrack == nil ||
                !CMTIME_IS_NUMERIC(duration) || CMTimeCompare(duration, kCMTimeZero) <= 0) {
                [controller previewFailed]; return;
            }
            AVMutableComposition *composition = [AVMutableComposition composition];
            AVMutableCompositionTrack *v = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
            AVMutableCompositionTrack *a = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            CMTimeRange range = CMTimeRangeMake(kCMTimeZero, duration);
            if (![v insertTimeRange:range ofTrack:videoTrack atTime:kCMTimeZero error:nil] ||
                ![a insertTimeRange:range ofTrack:audioTrack atTime:kCMTimeZero error:nil]) {
                [controller previewFailed]; return;
            }
            v.preferredTransform = videoTrack.preferredTransform;
            asset = composition;
        }
        [controller installPreviewItem:[AVPlayerItem playerItemWithAsset:asset]];
    });
}

- (void)installPreviewItem:(AVPlayerItem *)item {
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    player.automaticallyWaitsToMinimizeStalling = YES;
    player.allowsExternalPlayback = NO;
    self.previewPlayer = player;
    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.frame = self.videoPreviewContainer.bounds;
    self.previewPlayerLayer = layer;
    [self.videoPreviewContainer.layer insertSublayer:layer above:self.fallbackThumbnailView.layer];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(previewDidReachEnd:)
        name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(previewItemFailed:)
        name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    __weak YTKACESponsorSubmitController *weakSelf = self;
    self.previewTimeObserver = [player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.05, 600)
        queue:dispatch_get_main_queue() usingBlock:^(__unused CMTime time) { [weakSelf updatePreviewPlayback]; }];
    self.previewLastProgress = CACurrentMediaTime();
    self.previewLastMediaTime = -1.0;
    self.previewWatchdog = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
        YTKACESponsorSubmitController *controller = weakSelf;
        if (controller.isPlaying && CACurrentMediaTime() - controller.previewLastProgress > 30.0) [controller previewFailed];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.previewWatchdog forMode:NSRunLoopCommonModes];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
        context:YTKACESponsorPreviewItemContext];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                      change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if (context != YTKACESponsorPreviewItemContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    __weak YTKACESponsorSubmitController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACESponsorSubmitController *controller = weakSelf;
        if (!controller.previewVisible || controller.previewPlayer.currentItem != object) return;
        if (controller.previewPlayer.currentItem.status == AVPlayerItemStatusFailed) [controller previewFailed];
        else if (controller.previewPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay && controller.previewLoading) {
            controller.previewLoading = NO;
            [controller performPendingPreviewRequest];
        }
    });
}

- (void)tearDownPreviewPlayer {
    ++self.previewLoadGeneration;
    [self stopCutPreview];
    self.previewLoading = NO;
    [self.previewWatchdog invalidate];
    self.previewWatchdog = nil;
    if (self.previewTimeObserver != nil) [self.previewPlayer removeTimeObserver:self.previewTimeObserver];
    self.previewTimeObserver = nil;
    AVPlayerItem *item = self.previewPlayer.currentItem;
    if (item != nil) {
        [item removeObserver:self forKeyPath:@"status" context:YTKACESponsorPreviewItemContext];
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:item];
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    }
    [self.previewVideoAsset cancelLoading];
    [self.previewAudioAsset cancelLoading];
    self.previewVideoAsset = nil;
    self.previewAudioAsset = nil;
    self.previewPlayerLayer.player = nil;
    [self.previewPlayerLayer removeFromSuperlayer];
    self.previewPlayerLayer = nil;
    [self.previewPlayer replaceCurrentItemWithPlayerItem:nil];
    self.previewPlayer = nil;
}

- (void)previewFailed {
    YTKACESponsorPreviewRequest request = self.pendingPreviewRequest;
    BOOL retry = !self.previewTriedFreshResponse && self.previewVisible;
    [self tearDownPreviewPlayer];
    if (retry) {
        self.previewTriedFreshResponse = YES;
        self.pendingPreviewRequest = request;
        [self setupPreviewPlayer];
    } else {
        self.previewStatusLabel.text = YTKACELocalized(@"Preview unavailable. Tap Play to retry.");
    }
}

- (double)currentPreviewTime {
    double time = self.previewPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay && !self.previewSeeking
        ? CMTimeGetSeconds(self.previewPlayer.currentTime) : self.previewSeekTime;
    return isfinite(time) && time >= 0.0 ? time : MAX(0.0, self.previewSeekTime);
}

- (void)requestPreviewAt:(double)time play:(BOOL)play {
    [self stopCutPreview];
    double duration = self.videoDuration;
    self.previewSeekTime = MAX(0.0, isfinite(time) ? time : 0.0);
    if (duration > 0.0) self.previewSeekTime = MIN(self.previewSeekTime, MAX(0.0, duration - 0.05));
    self.pendingPreviewRequest = play ? YTKACESponsorPreviewRequestPlay : YTKACESponsorPreviewRequestSeek;
    [self performPendingPreviewRequest];
}

- (void)performPendingPreviewRequest {
    if (!self.previewVisible) return;
    if (self.previewPlayer.currentItem.status != AVPlayerItemStatusReadyToPlay || self.previewPlayer == nil) {
        self.isPlaying = self.pendingPreviewRequest == YTKACESponsorPreviewRequestPlay ||
            self.pendingPreviewRequest == YTKACESponsorPreviewRequestCut;
        [self updatePlayPauseButtonUI];
        [self setupPreviewPlayer]; return;
    }
    YTKACESponsorPreviewRequest request = self.pendingPreviewRequest;
    self.pendingPreviewRequest = YTKACESponsorPreviewRequestNone;
    if (request == YTKACESponsorPreviewRequestCut) { [self beginCutPreview]; return; }
    self.isPlaying = request == YTKACESponsorPreviewRequestPlay;
    [self updatePlayPauseButtonUI];
    self.previewStatusLabel.text = YTKACELocalized(@"Seeking preview…");
    __weak YTKACESponsorSubmitController *weakSelf = self;
    [self seekPreviewTo:self.previewSeekTime completion:^{
        YTKACESponsorSubmitController *controller = weakSelf;
        controller.previewStatusLabel.text = YTKACELocalized(@"Preview paused");
        [controller playPreviewIfRequested];
    }];
}

- (void)seekPreviewTo:(double)time completion:(dispatch_block_t)completion {
    NSUInteger generation = ++self.previewSeekGeneration;
    AVPlayer *player = self.previewPlayer;
    [player pause];
    [player.currentItem cancelPendingSeeks];
    self.previewSeekTime = time;
    self.previewSeeking = YES;
    self.previewLastProgress = CACurrentMediaTime();
    __weak YTKACESponsorSubmitController *weakSelf = self;
    [player seekToTime:CMTimeMakeWithSeconds(time, 60000) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
        completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACESponsorSubmitController *controller = weakSelf;
            if (!controller.previewVisible || controller.previewPlayer != player || controller.previewSeekGeneration != generation) return;
            controller.previewSeeking = NO;
            if (!finished) { [controller stopCutPreview]; return; }
            if (completion != nil) completion();
        });
    }];
}

- (void)playPreviewIfRequested {
    if (!self.isPlaying || self.previewSeeking || !self.previewVisible) return;
    YTKACEPauseYouTubePlayer();
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setActive:YES error:nil];
    self.previewPlayer.volume = 1.0;
    self.previewLastProgress = CACurrentMediaTime();
    [self.previewPlayer play];
}

- (void)updatePreviewPlayback {
    if (!self.previewVisible || self.previewSeeking || !self.isPlaying) return;
    double time = [self currentPreviewTime];
    if (fabs(time - self.previewLastMediaTime) > 0.01) {
        self.previewLastMediaTime = time;
        self.previewLastProgress = CACurrentMediaTime();
    }
    for (int i = 0; i < 2; ++i) {
        auto action = _cutPreview.advance(time);
        if (action == YTKACESponsorPreview::Action::None) break;
        [self handleCutPreviewAction:action];
        if (self.previewSeeking || !self.isPlaying) return;
    }
    NSString *status = YTKACELocalized(@"Playing preview");
    if (self.previewPlayer.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) status = YTKACELocalized(@"Buffering preview…");
    else if (_cutPreview.phase() == YTKACESponsorPreview::Phase::BeforeSegment) status = YTKACELocalized(@"Playing before cut");
    else if (_cutPreview.phase() == YTKACESponsorPreview::Phase::AfterSegment) status = YTKACELocalized(@"Playing after cut");
    else if (_cutPreview.phase() == YTKACESponsorPreview::Phase::Muting) status = YTKACELocalized(@"Previewing muted segment");
    self.previewStatusLabel.text = [NSString stringWithFormat:@"%@ · %@", status, YTKACEFormatSponsorTime(time)];
}

- (void)previewAppWillResignActive:(__unused NSNotification *)note { [self pausePreview]; }
- (void)previewItemFailed:(NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self previewItemFailed:note]; });
        return;
    }
    if (note.object == self.previewPlayer.currentItem) [self previewFailed];
}

- (void)previewDidReachEnd:(NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self previewDidReachEnd:note]; });
        return;
    }
    if (note.object != self.previewPlayer.currentItem || self.previewSeeking) return;
    double limit = _cutPreview.active() ? _cutPreview.targetEnd() : CMTimeGetSeconds(self.previewPlayer.currentItem.duration);
    if (isfinite(limit) && [self currentPreviewTime] < limit - 0.2) return;
    if (_cutPreview.phase() == YTKACESponsorPreview::Phase::AfterSegment ||
        (_cutPreview.phase() == YTKACESponsorPreview::Phase::Muting && _cutPreview.end() >= _cutPreview.targetEnd())) {
        [self finishCutPreview];
    } else {
        [self stopCutPreview];
        self.previewStatusLabel.text = YTKACELocalized(@"Preview finished");
    }
}

- (void)togglePlaybackTapped {
    if (self.isPlaying) {
        [self pausePreview];
    } else {
        [self playPreview];
    }
}

- (void)playPreview {
    if (_cutPreview.active() || self.previewSeeking) {
        self.isPlaying = YES;
        [self updatePlayPauseButtonUI];
        [self updatePreviewPlayback];
        [self playPreviewIfRequested];
    } else {
        double time = [self currentPreviewTime];
        if (self.videoDuration > 0.0 && time >= self.videoDuration - 0.1) time = self.startTime;
        [self requestPreviewAt:time play:YES];
    }
}

- (void)pausePreview {
    self.isPlaying = NO;
    [self updatePlayPauseButtonUI];
    if (self.previewPlayer != nil) {
        [self.previewPlayer pause];
    }
    if (self.pendingPreviewRequest == YTKACESponsorPreviewRequestPlay || self.pendingPreviewRequest == YTKACESponsorPreviewRequestCut)
        self.pendingPreviewRequest = YTKACESponsorPreviewRequestSeek;
    self.previewStatusLabel.text = YTKACELocalized(@"Preview paused");
}

- (void)updatePlayPauseButtonUI {
    if (self.previewPlayPauseButton == nil) return;
    if (self.isPlaying) {
        [self.previewPlayPauseButton setTitle:YTKACELocalized(@"Pause") forState:UIControlStateNormal];
        [self.previewPlayPauseButton setImage:[UIImage systemImageNamed:@"pause.fill"] forState:UIControlStateNormal];
    } else {
        [self.previewPlayPauseButton setTitle:YTKACELocalized(@"Play") forState:UIControlStateNormal];
        [self.previewPlayPauseButton setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    }
}

- (void)stopCutPreview {
    BOOL wasActive = self.isPlaying || self.previewSeeking || _cutPreview.active();
    _cutPreview.cancel();
    ++self.previewSeekGeneration;
    self.previewSeeking = NO;
    self.isPlaying = NO;
    self.pendingPreviewRequest = YTKACESponsorPreviewRequestNone;
    [self.previewPlayer pause];
    [self.previewPlayer.currentItem cancelPendingSeeks];
    self.previewPlayer.muted = NO;
    self.previewPlayer.currentItem.forwardPlaybackEndTime = kCMTimeInvalid;
    if (self.previewBoundaryObserver != nil) [self.previewPlayer removeTimeObserver:self.previewBoundaryObserver];
    self.previewBoundaryObserver = nil;
    [self updatePlayPauseButtonUI];
    if (wasActive) self.previewStatusLabel.text = YTKACELocalized(@"Preview paused");
}

- (void)setupScrollView {
    self.scrollView = [UIScrollView new];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = YES;
    [self.view addSubview:self.scrollView];

    self.contentView = [UIView new];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentView];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],

        [self.contentView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [self.contentView.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor]
    ]];
}

- (UIView *)buildCardView {
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    if (YTKACELiquidGlassAvailable()) {
        card.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.08]
                : [UIColor colorWithWhite:1.0 alpha:0.65];
        }];
        card.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.12]
                : [UIColor colorWithWhite:0.0 alpha:0.08];
        }].CGColor;
        card.layer.borderWidth = 0.5;
    } else {
        card.backgroundColor = YTKACESurfaceColor();
    }
    card.layer.cornerRadius = 14.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;
    return card;
}

- (UIView *)buildVideoPreviewCard {
    UIView *card = [self buildCardView];

    UILabel *header = [UILabel new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    header.textColor = YTKACESubtitleColor();
    header.text = YTKACELocalized(@"Video Preview");
    [card addSubview:header];

    // 16:9 Video container
    UIView *previewContainer = [UIView new];
    previewContainer.translatesAutoresizingMaskIntoConstraints = NO;
    previewContainer.backgroundColor = UIColor.blackColor;
    previewContainer.layer.cornerRadius = 10.0;
    previewContainer.layer.cornerCurve = kCACornerCurveContinuous;
    previewContainer.layer.masksToBounds = YES;
    previewContainer.clipsToBounds = YES;
    previewContainer.userInteractionEnabled = YES;
    UITapGestureRecognizer *tapPreview = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePlaybackTapped)];
    [previewContainer addGestureRecognizer:tapPreview];
    [card addSubview:previewContainer];
    self.videoPreviewContainer = previewContainer;

    // Fallback poster thumbnail
    UIImageView *fallback = [UIImageView new];
    fallback.translatesAutoresizingMaskIntoConstraints = NO;
    fallback.contentMode = UIViewContentModeScaleAspectFit;
    fallback.clipsToBounds = YES;
    fallback.backgroundColor = UIColor.blackColor;
    [previewContainer addSubview:fallback];
    self.fallbackThumbnailView = fallback;

    [NSLayoutConstraint activateConstraints:@[
        [fallback.topAnchor constraintEqualToAnchor:previewContainer.topAnchor],
        [fallback.leadingAnchor constraintEqualToAnchor:previewContainer.leadingAnchor],
        [fallback.trailingAnchor constraintEqualToAnchor:previewContainer.trailingAnchor],
        [fallback.bottomAnchor constraintEqualToAnchor:previewContainer.bottomAnchor]
    ]];

    if (self.videoID.length > 0) {
        NSString *thumbUrlStr = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", self.videoID];
        NSURL *thumbUrl = [NSURL URLWithString:thumbUrlStr];
        if (thumbUrl != nil) {
            __weak UIImageView *weakThumb = fallback;
            [[NSURLSession.sharedSession dataTaskWithURL:thumbUrl completionHandler:^(NSData * _Nullable data, __unused NSURLResponse * _Nullable response, NSError * _Nullable error) {
                if (data.length > 0 && error == nil) {
                    UIImage *img = [UIImage imageWithData:data];
                    if (img != nil) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            weakThumb.image = img;
                        });
                    }
                }
            }] resume];
        }
    }

    // Top-left category overlay pill
    UIView *categoryBadge = [UIView new];
    categoryBadge.translatesAutoresizingMaskIntoConstraints = NO;
    categoryBadge.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    categoryBadge.layer.cornerRadius = 11.0;
    categoryBadge.layer.masksToBounds = YES;
    [previewContainer addSubview:categoryBadge];

    UIView *catDot = [UIView new];
    catDot.translatesAutoresizingMaskIntoConstraints = NO;
    catDot.backgroundColor = YTKACESponsorCategoryColor(self.selectedCategory);
    catDot.layer.cornerRadius = 4.0;
    catDot.layer.masksToBounds = YES;
    [categoryBadge addSubview:catDot];
    self.previewCategoryDot = catDot;

    UILabel *catLabel = [UILabel new];
    catLabel.translatesAutoresizingMaskIntoConstraints = NO;
    catLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    catLabel.textColor = UIColor.whiteColor;
    catLabel.text = YTKACESponsorCategoryTitle(self.selectedCategory);
    [categoryBadge addSubview:catLabel];
    self.previewCategoryLabel = catLabel;

    // Top-right cut timing overlay pill
    UIView *timeBadge = [UIView new];
    timeBadge.translatesAutoresizingMaskIntoConstraints = NO;
    timeBadge.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    timeBadge.layer.cornerRadius = 11.0;
    timeBadge.layer.masksToBounds = YES;
    [previewContainer addSubview:timeBadge];

    UILabel *timeBadgeLabel = [UILabel new];
    timeBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    timeBadgeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightSemibold];
    timeBadgeLabel.textColor = UIColor.whiteColor;
    timeBadgeLabel.text = [NSString stringWithFormat:@"%@ → %@",
        YTKACEFormatSponsorTime(self.startTime),
        YTKACEFormatSponsorTime(self.endTime)];
    [timeBadge addSubview:timeBadgeLabel];
    self.previewTimeLabel = timeBadgeLabel;

    // Center/Bottom status label for cut playback state
    UILabel *statusLabel = [UILabel new];
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    statusLabel.textColor = UIColor.whiteColor;
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    statusLabel.layer.cornerRadius = 6.0;
    statusLabel.layer.masksToBounds = YES;
    statusLabel.text = YTKACELocalized(@"Loading preview…");
    [previewContainer addSubview:statusLabel];
    self.previewStatusLabel = statusLabel;

    // Controls Row below preview container: [▶ Play/Pause] [⏮ Start] [⏭ End] [✂ Cut]
    UIStackView *controlStack = [UIStackView new];
    controlStack.translatesAutoresizingMaskIntoConstraints = NO;
    controlStack.axis = UILayoutConstraintAxisHorizontal;
    controlStack.spacing = 8.0;
    controlStack.distribution = UIStackViewDistributionFillEqually;
    [card addSubview:controlStack];

    // 1. Play / Pause
    UIButton *playBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    if (YTKACELiquidGlassAvailable()) {
        playBtn.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.10]
                : [UIColor colorWithWhite:0.0 alpha:0.05];
        }];
        playBtn.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.12]
                : [UIColor colorWithWhite:0.0 alpha:0.08];
        }].CGColor;
        playBtn.layer.borderWidth = 0.5;
    } else {
        playBtn.backgroundColor = YTKACEButtonBgColor();
    }
    playBtn.layer.cornerRadius = 8.0;
    playBtn.layer.cornerCurve = kCACornerCurveContinuous;
    [playBtn setTitle:YTKACELocalized(@"Play") forState:UIControlStateNormal];
    [playBtn setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
    playBtn.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
    [playBtn setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    playBtn.tintColor = YTKACEAccentColor();
    playBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    [playBtn addTarget:self action:@selector(togglePlaybackTapped) forControlEvents:UIControlEventTouchUpInside];
    self.previewPlayPauseButton = playBtn;
    [controlStack addArrangedSubview:playBtn];

    // 2. Seek Start
    UIButton *seekStartBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    if (YTKACELiquidGlassAvailable()) {
        seekStartBtn.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.10]
                : [UIColor colorWithWhite:0.0 alpha:0.05];
        }];
        seekStartBtn.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.12]
                : [UIColor colorWithWhite:0.0 alpha:0.08];
        }].CGColor;
        seekStartBtn.layer.borderWidth = 0.5;
    } else {
        seekStartBtn.backgroundColor = YTKACEButtonBgColor();
    }
    seekStartBtn.layer.cornerRadius = 8.0;
    seekStartBtn.layer.cornerCurve = kCACornerCurveContinuous;
    [seekStartBtn setTitle:YTKACELocalized(@"⏮ Start") forState:UIControlStateNormal];
    [seekStartBtn setTitleColor:YTKACETitleColor() forState:UIControlStateNormal];
    seekStartBtn.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    [seekStartBtn addTarget:self action:@selector(seekToStart) forControlEvents:UIControlEventTouchUpInside];
    self.previewSeekStartButton = seekStartBtn;
    [controlStack addArrangedSubview:seekStartBtn];

    // 3. Seek End
    UIButton *seekEndBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    if (YTKACELiquidGlassAvailable()) {
        seekEndBtn.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.10]
                : [UIColor colorWithWhite:0.0 alpha:0.05];
        }];
        seekEndBtn.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.12]
                : [UIColor colorWithWhite:0.0 alpha:0.08];
        }].CGColor;
        seekEndBtn.layer.borderWidth = 0.5;
    } else {
        seekEndBtn.backgroundColor = YTKACEButtonBgColor();
    }
    seekEndBtn.layer.cornerRadius = 8.0;
    seekEndBtn.layer.cornerCurve = kCACornerCurveContinuous;
    [seekEndBtn setTitle:YTKACELocalized(@"⏭ End") forState:UIControlStateNormal];
    [seekEndBtn setTitleColor:YTKACETitleColor() forState:UIControlStateNormal];
    seekEndBtn.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    [seekEndBtn addTarget:self action:@selector(seekToEnd) forControlEvents:UIControlEventTouchUpInside];
    self.previewSeekEndButton = seekEndBtn;
    [controlStack addArrangedSubview:seekEndBtn];

    // 4. Test Cut Preview
    UIButton *cutBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    if (YTKACELiquidGlassAvailable()) {
        cutBtn.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.10]
                : [UIColor colorWithWhite:0.0 alpha:0.05];
        }];
        cutBtn.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.12]
                : [UIColor colorWithWhite:0.0 alpha:0.08];
        }].CGColor;
        cutBtn.layer.borderWidth = 0.5;
    } else {
        cutBtn.backgroundColor = YTKACEButtonBgColor();
    }
    cutBtn.layer.cornerRadius = 8.0;
    cutBtn.layer.cornerCurve = kCACornerCurveContinuous;
    [cutBtn setTitle:YTKACELocalized(@"↺ Replay") forState:UIControlStateNormal];
    [cutBtn setTitleColor:YTKACETitleColor() forState:UIControlStateNormal];
    cutBtn.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    [cutBtn setImage:[UIImage systemImageNamed:@"arrow.counterclockwise"] forState:UIControlStateNormal];
    cutBtn.tintColor = YTKACETitleColor();
    cutBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    [cutBtn addTarget:self action:@selector(previewSkipTapped) forControlEvents:UIControlEventTouchUpInside];
    self.previewCutButton = cutBtn;
    [controlStack addArrangedSubview:cutBtn];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:card.topAnchor constant:10.0],
        [header.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],

        [previewContainer.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8.0],
        [previewContainer.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [previewContainer.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [previewContainer.heightAnchor constraintEqualToAnchor:previewContainer.widthAnchor multiplier:(9.0 / 16.0)],

        [categoryBadge.topAnchor constraintEqualToAnchor:previewContainer.topAnchor constant:8.0],
        [categoryBadge.leadingAnchor constraintEqualToAnchor:previewContainer.leadingAnchor constant:8.0],
        [categoryBadge.heightAnchor constraintEqualToConstant:22.0],

        [catDot.centerYAnchor constraintEqualToAnchor:categoryBadge.centerYAnchor],
        [catDot.leadingAnchor constraintEqualToAnchor:categoryBadge.leadingAnchor constant:8.0],
        [catDot.widthAnchor constraintEqualToConstant:8.0],
        [catDot.heightAnchor constraintEqualToConstant:8.0],

        [catLabel.centerYAnchor constraintEqualToAnchor:categoryBadge.centerYAnchor],
        [catLabel.leadingAnchor constraintEqualToAnchor:catDot.trailingAnchor constant:6.0],
        [catLabel.trailingAnchor constraintEqualToAnchor:categoryBadge.trailingAnchor constant:-8.0],

        [timeBadge.topAnchor constraintEqualToAnchor:previewContainer.topAnchor constant:8.0],
        [timeBadge.trailingAnchor constraintEqualToAnchor:previewContainer.trailingAnchor constant:-8.0],
        [timeBadge.heightAnchor constraintEqualToConstant:22.0],

        [timeBadgeLabel.centerYAnchor constraintEqualToAnchor:timeBadge.centerYAnchor],
        [timeBadgeLabel.leadingAnchor constraintEqualToAnchor:timeBadge.leadingAnchor constant:8.0],
        [timeBadgeLabel.trailingAnchor constraintEqualToAnchor:timeBadge.trailingAnchor constant:-8.0],

        [statusLabel.bottomAnchor constraintEqualToAnchor:previewContainer.bottomAnchor constant:-8.0],
        [statusLabel.leadingAnchor constraintEqualToAnchor:previewContainer.leadingAnchor constant:12.0],
        [statusLabel.trailingAnchor constraintEqualToAnchor:previewContainer.trailingAnchor constant:-12.0],
        [statusLabel.heightAnchor constraintEqualToConstant:24.0],

        [controlStack.topAnchor constraintEqualToAnchor:previewContainer.bottomAnchor constant:10.0],
        [controlStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [controlStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [controlStack.heightAnchor constraintEqualToConstant:32.0],
        [controlStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12.0]
    ]];

    return card;
}

- (void)buildUI {
    // 1. Video Info Card
    UIView *infoCard = [self buildCardView];
    [self.contentView addSubview:infoCard];

    self.titleLabel = [UILabel new];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBold];
    self.titleLabel.textColor = YTKACETitleColor();
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.text = self.videoTitle.length > 0 ? self.videoTitle : YTKACELocalized(@"Current Video");
    [infoCard addSubview:self.titleLabel];

    self.videoIDBadge = [UILabel new];
    self.videoIDBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoIDBadge.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightMedium];
    self.videoIDBadge.textColor = YTKACESubtitleColor();
    self.videoIDBadge.text = [NSString stringWithFormat:@"ID: %@", self.videoID ?: @"--"];
    [infoCard addSubview:self.videoIDBadge];

    self.durationLabel = [UILabel new];
    self.durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.durationLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    self.durationLabel.textColor = YTKACESubtitleColor();
    if (self.videoDuration > 0.0) {
        self.durationLabel.text = [NSString stringWithFormat:@"%@: %@", YTKACELocalized(@"Duration"), YTKACEFormatSponsorTime(self.videoDuration)];
    }
    [infoCard addSubview:self.durationLabel];

    [NSLayoutConstraint activateConstraints:@[
        [infoCard.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12.0],
        [infoCard.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [infoCard.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],

        [self.titleLabel.topAnchor constraintEqualToAnchor:infoCard.topAnchor constant:12.0],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor constant:14.0],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:infoCard.trailingAnchor constant:-14.0],

        [self.videoIDBadge.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4.0],
        [self.videoIDBadge.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor constant:14.0],

        [self.durationLabel.centerYAnchor constraintEqualToAnchor:self.videoIDBadge.centerYAnchor],
        [self.durationLabel.trailingAnchor constraintEqualToAnchor:infoCard.trailingAnchor constant:-14.0],
        [self.durationLabel.bottomAnchor constraintEqualToAnchor:infoCard.bottomAnchor constant:-12.0]
    ]];

    // 1b. Video Preview Card
    UIView *previewCard = [self buildVideoPreviewCard];
    [self.contentView addSubview:previewCard];

    // 2. Select Video Chapter Button
    UIButton *chapterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    chapterButton.translatesAutoresizingMaskIntoConstraints = NO;
    if (YTKACELiquidGlassAvailable()) {
        chapterButton.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.08]
                : [UIColor colorWithWhite:1.0 alpha:0.65];
        }];
        chapterButton.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.12]
                : [UIColor colorWithWhite:0.0 alpha:0.08];
        }].CGColor;
        chapterButton.layer.borderWidth = 0.5;
    } else {
        chapterButton.backgroundColor = YTKACESurfaceColor();
    }
    chapterButton.layer.cornerRadius = 12.0;
    chapterButton.layer.cornerCurve = kCACornerCurveContinuous;
    chapterButton.layer.masksToBounds = YES;
    NSArray<YTKACEVideoChapter *> *chapters = YTKACESponsorCurrentChapters();
    NSString *btnTitle = chapters.count > 0
        ? [NSString stringWithFormat:@"%@ (%lu)", YTKACELocalized(@"Select from Video Chapters"), (unsigned long)chapters.count]
        : YTKACELocalized(@"Select from Video Chapters");
    [chapterButton setTitle:btnTitle forState:UIControlStateNormal];
    [chapterButton setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
    chapterButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    UIImage *listImg = [UIImage systemImageNamed:@"list.bullet.rectangle"];
    if (listImg != nil) {
        [chapterButton setImage:listImg forState:UIControlStateNormal];
        chapterButton.tintColor = YTKACEAccentColor();
        chapterButton.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 8);
    }
    [chapterButton addTarget:self action:@selector(chapterButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:chapterButton];
    self.chapterButton = chapterButton;

    // 3. Start Time Card
    UIView *startCard = [self buildTimeCardWithTitle:YTKACELocalized(@"START TIME")
                                             isStart:YES];
    [self.contentView addSubview:startCard];

    // 4. End Time Card
    UIView *endCard = [self buildTimeCardWithTitle:YTKACELocalized(@"END TIME")
                                           isStart:NO];
    [self.contentView addSubview:endCard];

    // 5. Length Indicator Badge
    self.lengthBadgeView = [UIView new];
    self.lengthBadgeView.translatesAutoresizingMaskIntoConstraints = NO;
    self.lengthBadgeView.layer.cornerRadius = 10.0;
    self.lengthBadgeView.layer.masksToBounds = YES;
    [self.contentView addSubview:self.lengthBadgeView];

    self.lengthBadgeLabel = [UILabel new];
    self.lengthBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.lengthBadgeLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.lengthBadgeLabel.textAlignment = NSTextAlignmentCenter;
    [self.lengthBadgeView addSubview:self.lengthBadgeLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.lengthBadgeView.topAnchor constraintEqualToAnchor:endCard.bottomAnchor constant:8.0],
        [self.lengthBadgeView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [self.lengthBadgeView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
        [self.lengthBadgeView.heightAnchor constraintEqualToConstant:32.0],

        [self.lengthBadgeLabel.centerXAnchor constraintEqualToAnchor:self.lengthBadgeView.centerXAnchor],
        [self.lengthBadgeLabel.centerYAnchor constraintEqualToAnchor:self.lengthBadgeView.centerYAnchor]
    ]];

    // 6. Category Selection Card
    UIView *categoryCard = [self buildCategoryCard];
    [self.contentView addSubview:categoryCard];

    // 7. Preview Skip Button
    self.previewSkipButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.previewSkipButton.translatesAutoresizingMaskIntoConstraints = NO;
    if (YTKACELiquidGlassAvailable()) {
        self.previewSkipButton.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.10]
                : [UIColor colorWithWhite:0.0 alpha:0.05];
        }];
        self.previewSkipButton.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.14]
                : [UIColor colorWithWhite:0.0 alpha:0.10];
        }].CGColor;
        self.previewSkipButton.layer.borderWidth = 0.5;
    } else {
        self.previewSkipButton.backgroundColor = YTKACEButtonBgColor();
    }
    self.previewSkipButton.layer.cornerRadius = 12.0;
    self.previewSkipButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.previewSkipButton.layer.masksToBounds = YES;
    [self.previewSkipButton setTitle:YTKACELocalized(@"Preview Cut") forState:UIControlStateNormal];
    [self.previewSkipButton setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
    self.previewSkipButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    UIImage *scissors = [UIImage systemImageNamed:@"scissors"];
    if (scissors != nil) {
        [self.previewSkipButton setImage:scissors forState:UIControlStateNormal];
        self.previewSkipButton.tintColor = YTKACEAccentColor();
        self.previewSkipButton.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 8);
    }
    [self.previewSkipButton addTarget:self action:@selector(previewSkipTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.previewSkipButton];

    // 8. Big Bottom Submit Button
    self.submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.submitButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.submitButton.backgroundColor = YTKACESponsorCategoryColor(@"sponsor");
    self.submitButton.layer.cornerRadius = 14.0;
    [self.submitButton setTitle:YTKACELocalized(@"Submit to SponsorBlock") forState:UIControlStateNormal];
    [self.submitButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.submitButton.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];
    UIImage *shield = YTKACEAssetImage(@"sponsorblock_shield_template", @"play.shield");
    if (shield != nil) {
        [self.submitButton setImage:[shield imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                           forState:UIControlStateNormal];
        self.submitButton.tintColor = UIColor.whiteColor;
        self.submitButton.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 8);
    }
    [self.submitButton addTarget:self action:@selector(submitTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.submitButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = UIColor.whiteColor;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidesWhenStopped = YES;
    [self.submitButton addSubview:self.spinner];

    [NSLayoutConstraint activateConstraints:@[
        [previewCard.topAnchor constraintEqualToAnchor:infoCard.bottomAnchor constant:10.0],
        [previewCard.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [previewCard.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],

        [chapterButton.topAnchor constraintEqualToAnchor:previewCard.bottomAnchor constant:10.0],
        [chapterButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [chapterButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
        [chapterButton.heightAnchor constraintEqualToConstant:42.0],

        [startCard.topAnchor constraintEqualToAnchor:chapterButton.bottomAnchor constant:10.0],
        [startCard.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [startCard.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],

        [endCard.topAnchor constraintEqualToAnchor:startCard.bottomAnchor constant:10.0],
        [endCard.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [endCard.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],

        [categoryCard.topAnchor constraintEqualToAnchor:self.lengthBadgeView.bottomAnchor constant:12.0],
        [categoryCard.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [categoryCard.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],

        [self.previewSkipButton.topAnchor constraintEqualToAnchor:categoryCard.bottomAnchor constant:12.0],
        [self.previewSkipButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [self.previewSkipButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
        [self.previewSkipButton.heightAnchor constraintEqualToConstant:44.0],

        [self.submitButton.topAnchor constraintEqualToAnchor:self.previewSkipButton.bottomAnchor constant:14.0],
        [self.submitButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [self.submitButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
        [self.submitButton.heightAnchor constraintEqualToConstant:50.0],
        [self.submitButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-24.0],

        [self.spinner.centerYAnchor constraintEqualToAnchor:self.submitButton.centerYAnchor],
        [self.spinner.trailingAnchor constraintEqualToAnchor:self.submitButton.trailingAnchor constant:-16.0]
    ]];
}

- (void)chapterButtonTapped {
    NSArray<YTKACEVideoChapter *> *chapters = YTKACESponsorCurrentChapters();
    if (chapters.count == 0) {
        AudioServicesPlaySystemSound(1520);
        YTKACEShowNotice(YTKACELocalized(@"No chapters found for this video"));
        return;
    }
    AudioServicesPlaySystemSound(1519);
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:YTKACELocalized(@"Select Video Chapter")
                         message:YTKACELocalized(@"Choose a chapter to automatically fill start time, end time, and category:")
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (YTKACEVideoChapter *ch in chapters) {
        NSString *categoryTitle = YTKACESponsorCategoryTitle(ch.suggestedCategory);
        NSString *prefix = ch.isLikelySponsor ? @"★ " : @"";
        NSString *actionTitle = [NSString stringWithFormat:@"%@%@ (%@ - %@) [%@]",
            prefix,
            ch.title,
            YTKACEFormatSponsorTime(ch.startTime),
            YTKACEFormatSponsorTime(ch.endTime),
            categoryTitle];

        UIAlertAction *action = [UIAlertAction actionWithTitle:actionTitle
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(__unused UIAlertAction *act) {
            self.startTime = ch.startTime;
            self.endTime = ch.endTime;
            self.selectedCategory = ch.suggestedCategory;
            if ([self.actionType isEqualToString:@"full"]) {
                self.actionType = @"skip";
                self.actionSegmentedControl.selectedSegmentIndex = 0;
            }
            [self updateTimeLabels];
            [self updateCategorySelection];
            [self requestPreviewAt:self.startTime play:NO];
            AudioServicesPlaySystemSound(1519);
            NSString *msg = [NSString stringWithFormat:@"%@: %@", YTKACELocalized(@"Selected chapter"), ch.title];
            YTKACEShowNotice(msg);
        }];
        [alert addAction:action];
    }

    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    if (alert.popoverPresentationController != nil) {
        alert.popoverPresentationController.sourceView = self.contentView;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.contentView.bounds), 100.0, 1.0, 1.0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIView *)buildTimeCardWithTitle:(NSString *)title
                           isStart:(BOOL)isStart {
    UIView *card = [self buildCardView];

    UILabel *header = [UILabel new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    header.textColor = YTKACESubtitleColor();
    header.text = title;
    [card addSubview:header];

    UILabel *timeLabel = [UILabel new];
    timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:22.0 weight:UIFontWeightBold];
    timeLabel.textColor = YTKACETitleColor();
    timeLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *tapTime = [[UITapGestureRecognizer alloc]
        initWithTarget:self
                action:isStart ? @selector(editStartTimeTapped) : @selector(editEndTimeTapped)];
    [timeLabel addGestureRecognizer:tapTime];
    [card addSubview:timeLabel];
    
    UILabel *secLabel = [UILabel new];
    secLabel.translatesAutoresizingMaskIntoConstraints = NO;
    secLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    secLabel.textColor = YTKACESubtitleColor();
    [card addSubview:secLabel];
    
    if (isStart) {
        self.startTimeLabel = timeLabel;
        self.startSecLabel = secLabel;
    } else {
        self.endTimeLabel = timeLabel;
        self.endSecLabel = secLabel;
    }

    UIStackView *actionStack = [UIStackView new];
    actionStack.translatesAutoresizingMaskIntoConstraints = NO;
    actionStack.axis = UILayoutConstraintAxisHorizontal;
    actionStack.spacing = 6.0;
    actionStack.alignment = UIStackViewAlignmentCenter;
    [card addSubview:actionStack];

    UIButton *nowBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    nowBtn.translatesAutoresizingMaskIntoConstraints = NO;
    if (YTKACELiquidGlassAvailable()) {
        nowBtn.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.10]
                : [UIColor colorWithWhite:0.0 alpha:0.05];
        }];
        nowBtn.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.12]
                : [UIColor colorWithWhite:0.0 alpha:0.08];
        }].CGColor;
        nowBtn.layer.borderWidth = 0.5;
    } else {
        nowBtn.backgroundColor = YTKACEButtonBgColor();
    }
    nowBtn.layer.cornerRadius = 8.0;
    nowBtn.layer.cornerCurve = kCACornerCurveContinuous;
    [nowBtn setTitle:YTKACELocalized(@"Now") forState:UIControlStateNormal];
    [nowBtn setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
    nowBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    [nowBtn setImage:[UIImage systemImageNamed:@"record.circle"] forState:UIControlStateNormal];
    nowBtn.tintColor = YTKACEAccentColor();
    nowBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -3, 0, 3);
    if (isStart) {
        [nowBtn addTarget:self action:@selector(setStartToNow) forControlEvents:UIControlEventTouchUpInside];
    } else {
        [nowBtn addTarget:self action:@selector(setEndToNow) forControlEvents:UIControlEventTouchUpInside];
    }
    [actionStack addArrangedSubview:nowBtn];

    if (!isStart) {
        UIButton *endBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        endBtn.translatesAutoresizingMaskIntoConstraints = NO;
        if (YTKACELiquidGlassAvailable()) {
            endBtn.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [UIColor colorWithWhite:1.0 alpha:0.10]
                    : [UIColor colorWithWhite:0.0 alpha:0.05];
            }];
            endBtn.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [UIColor colorWithWhite:1.0 alpha:0.12]
                    : [UIColor colorWithWhite:0.0 alpha:0.08];
            }].CGColor;
            endBtn.layer.borderWidth = 0.5;
        } else {
            endBtn.backgroundColor = YTKACEButtonBgColor();
        }
        endBtn.layer.cornerRadius = 8.0;
        endBtn.layer.cornerCurve = kCACornerCurveContinuous;
        [endBtn setTitle:YTKACELocalized(@"End") forState:UIControlStateNormal];
        [endBtn setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
        endBtn.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        [endBtn setImage:[UIImage systemImageNamed:@"forward.end.alt"] forState:UIControlStateNormal];
        endBtn.tintColor = YTKACEAccentColor();
        endBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -3, 0, 3);
        [endBtn addTarget:self action:@selector(setEndToDuration) forControlEvents:UIControlEventTouchUpInside];
        [actionStack addArrangedSubview:endBtn];
        [NSLayoutConstraint activateConstraints:@[
            [endBtn.widthAnchor constraintEqualToConstant:60.0],
            [endBtn.heightAnchor constraintEqualToConstant:30.0]
        ]];
    }

    UIButton *seekBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    seekBtn.translatesAutoresizingMaskIntoConstraints = NO;
    if (YTKACELiquidGlassAvailable()) {
        seekBtn.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.10]
                : [UIColor colorWithWhite:0.0 alpha:0.05];
        }];
        seekBtn.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.12]
                : [UIColor colorWithWhite:0.0 alpha:0.08];
        }].CGColor;
        seekBtn.layer.borderWidth = 0.5;
    } else {
        seekBtn.backgroundColor = YTKACEButtonBgColor();
    }
    seekBtn.layer.cornerRadius = 8.0;
    seekBtn.layer.cornerCurve = kCACornerCurveContinuous;
    [seekBtn setTitle:YTKACELocalized(@"Seek") forState:UIControlStateNormal];
    [seekBtn setTitleColor:YTKACETitleColor() forState:UIControlStateNormal];
    seekBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    [seekBtn setImage:[UIImage systemImageNamed:@"play.circle"] forState:UIControlStateNormal];
    seekBtn.tintColor = YTKACETitleColor();
    seekBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -3, 0, 3);
    if (isStart) {
        [seekBtn addTarget:self action:@selector(seekToStart) forControlEvents:UIControlEventTouchUpInside];
    } else {
        [seekBtn addTarget:self action:@selector(seekToEnd) forControlEvents:UIControlEventTouchUpInside];
    }
    [actionStack addArrangedSubview:seekBtn];

    // Stepper row: -1s, -0.1s, +0.1s, +1s
    UIStackView *stepStack = [UIStackView new];
    stepStack.translatesAutoresizingMaskIntoConstraints = NO;
    stepStack.axis = UILayoutConstraintAxisHorizontal;
    stepStack.spacing = 8.0;
    stepStack.distribution = UIStackViewDistributionFillEqually;
    [card addSubview:stepStack];

    NSArray *deltas = @[@(-1.0), @(-0.1), @(0.1), @(1.0)];
    NSArray *titles = @[@"-1s", @"-0.1s", @"+0.1s", @"+1s"];
    for (NSUInteger i = 0; i < 4; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        if (YTKACELiquidGlassAvailable()) {
            btn.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [UIColor colorWithWhite:1.0 alpha:0.10]
                    : [UIColor colorWithWhite:0.0 alpha:0.05];
            }];
            btn.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [UIColor colorWithWhite:1.0 alpha:0.12]
                    : [UIColor colorWithWhite:0.0 alpha:0.08];
            }].CGColor;
            btn.layer.borderWidth = 0.5;
        } else {
            btn.backgroundColor = YTKACEButtonBgColor();
        }
        btn.layer.cornerRadius = 8.0;
        btn.layer.cornerCurve = kCACornerCurveContinuous;
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        [btn setTitleColor:YTKACETitleColor() forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightSemibold];
        double delta = [deltas[i] doubleValue];
        if (isStart) {
            btn.tag = (NSInteger)(delta * 10.0);
            [btn addTarget:self action:@selector(stepStart:) forControlEvents:UIControlEventTouchUpInside];
        } else {
            btn.tag = (NSInteger)(delta * 10.0);
            [btn addTarget:self action:@selector(stepEnd:) forControlEvents:UIControlEventTouchUpInside];
        }
        [stepStack addArrangedSubview:btn];
    }

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:card.topAnchor constant:10.0],
        [header.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],

        [timeLabel.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:4.0],
        [timeLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],

        [secLabel.centerYAnchor constraintEqualToAnchor:timeLabel.centerYAnchor],
        [secLabel.leadingAnchor constraintEqualToAnchor:timeLabel.trailingAnchor constant:8.0],

        [actionStack.centerYAnchor constraintEqualToAnchor:timeLabel.centerYAnchor],
        [actionStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [actionStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:secLabel.trailingAnchor constant:6.0],
        [actionStack.heightAnchor constraintEqualToConstant:30.0],

        [nowBtn.widthAnchor constraintEqualToConstant:isStart ? 66.0 : 60.0],
        [nowBtn.heightAnchor constraintEqualToConstant:30.0],

        [seekBtn.widthAnchor constraintEqualToConstant:isStart ? 66.0 : 60.0],
        [seekBtn.heightAnchor constraintEqualToConstant:30.0],

        [stepStack.topAnchor constraintEqualToAnchor:timeLabel.bottomAnchor constant:10.0],
        [stepStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [stepStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [stepStack.heightAnchor constraintEqualToConstant:32.0],
        [stepStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12.0]
    ]];

    return card;
}

- (void)presentCategoryPicker {
    AudioServicesPlaySystemSound(1519);
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:YTKACELocalized(@"Select Category")
        message:YTKACELocalized(@"Choose a SponsorBlock category:")
        preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *definitions = YTKACESponsorCategoryDefinitions();
    for (NSDictionary *def in definitions) {
        NSString *catID = def[@"id"];
        NSString *catTitle = def[@"title"];
        NSString *catDesc = def[@"description"];
        BOOL isSelected = [catID isEqualToString:self.selectedCategory];

        NSString *actionTitle = isSelected
            ? [NSString stringWithFormat:@"✓ %@", catTitle]
            : catTitle;

        if (catDesc.length > 0) {
            actionTitle = [actionTitle stringByAppendingFormat:@" (%@)", catDesc];
        }

        UIAlertAction *action = [UIAlertAction
            actionWithTitle:actionTitle
                      style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *act) {
            self.selectedCategory = catID;
            if ([self.actionType isEqualToString:@"full"] &&
                ![catID isEqualToString:@"sponsor"] &&
                ![catID isEqualToString:@"selfpromo"]) {
                self.actionType = @"skip";
            }
            if ([self.actionType isEqualToString:@"mute"] &&
                [catID isEqualToString:@"music_offtopic"]) {
                self.actionType = @"skip";
            }
            AudioServicesPlaySystemSound(1519);
            [self updateCategorySelection];
        }];
        [sheet addAction:action];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UIView *)buildCategoryCard {
    UIView *card = [self buildCardView];

    UILabel *header = [UILabel new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    header.textColor = YTKACESubtitleColor();
    header.text = YTKACELocalized(@"CATEGORY");
    [card addSubview:header];

    UIButton *pickerBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    pickerBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [pickerBtn setTitle:YTKACELocalized(@"Choose List ▾") forState:UIControlStateNormal];
    [pickerBtn setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
    pickerBtn.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    [pickerBtn addTarget:self action:@selector(presentCategoryPicker) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:pickerBtn];

    UIStackView *gridStack = [UIStackView new];
    gridStack.translatesAutoresizingMaskIntoConstraints = NO;
    gridStack.axis = UILayoutConstraintAxisVertical;
    gridStack.spacing = 6.0;
    gridStack.distribution = UIStackViewDistributionFillEqually;
    [card addSubview:gridStack];

    NSArray *definitions = YTKACESponsorCategoryDefinitions();
    UIStackView *currentRowStack = nil;
    for (NSUInteger i = 0; i < definitions.count; i++) {
        if (i % 3 == 0) {
            currentRowStack = [UIStackView new];
            currentRowStack.translatesAutoresizingMaskIntoConstraints = NO;
            currentRowStack.axis = UILayoutConstraintAxisHorizontal;
            currentRowStack.spacing = 6.0;
            currentRowStack.distribution = UIStackViewDistributionFillEqually;
            [gridStack addArrangedSubview:currentRowStack];
        }

        NSDictionary *def = definitions[i];
        NSString *catID = def[@"id"];
        NSString *catTitle = def[@"title"];
        UIColor *color = YTKACESponsorCategoryColor(catID);

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        btn.layer.cornerRadius = 10.0;
        btn.layer.cornerCurve = kCACornerCurveContinuous;
        btn.layer.borderWidth = 0.5;
        if (YTKACELiquidGlassAvailable()) {
            btn.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [UIColor colorWithWhite:1.0 alpha:0.10]
                    : [UIColor colorWithWhite:0.0 alpha:0.05];
            }];
            btn.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [UIColor colorWithWhite:1.0 alpha:0.12]
                    : [UIColor colorWithWhite:0.0 alpha:0.08];
            }].CGColor;
        } else {
            btn.layer.borderColor = UIColor.clearColor.CGColor;
            btn.backgroundColor = YTKACEButtonBgColor();
        }
        btn.tag = (NSInteger)i;

        // Custom chip content with dot + label
        UIStackView *chipContent = [UIStackView new];
        chipContent.userInteractionEnabled = NO;
        chipContent.axis = UILayoutConstraintAxisHorizontal;
        chipContent.spacing = 5.0;
        chipContent.alignment = UIStackViewAlignmentCenter;
        chipContent.translatesAutoresizingMaskIntoConstraints = NO;
        [btn addSubview:chipContent];

        UIView *dot = [UIView new];
        dot.backgroundColor = color;
        dot.layer.cornerRadius = 4.0;
        dot.layer.masksToBounds = YES;
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        [dot.widthAnchor constraintEqualToConstant:8.0].active = YES;
        [dot.heightAnchor constraintEqualToConstant:8.0].active = YES;
        [chipContent addArrangedSubview:dot];

        UILabel *label = [UILabel new];
        label.text = catTitle;
        label.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
        label.textColor = YTKACETitleColor();
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.70;
        label.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
        [chipContent addArrangedSubview:label];

        [NSLayoutConstraint activateConstraints:@[
            [chipContent.leadingAnchor constraintEqualToAnchor:btn.leadingAnchor constant:6.0],
            [chipContent.trailingAnchor constraintEqualToAnchor:btn.trailingAnchor constant:-6.0],
            [chipContent.centerYAnchor constraintEqualToAnchor:btn.centerYAnchor],
            [btn.heightAnchor constraintEqualToConstant:32.0]
        ]];

        [btn addTarget:self action:@selector(categorySelected:) forControlEvents:UIControlEventTouchUpInside];
        [currentRowStack addArrangedSubview:btn];
        [self.categoryButtons addObject:btn];
    }

    self.categoryDescLabel = [UILabel new];
    self.categoryDescLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.categoryDescLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    self.categoryDescLabel.textColor = YTKACESubtitleColor();
    self.categoryDescLabel.numberOfLines = 2;
    [card addSubview:self.categoryDescLabel];

    UISegmentedControl *actionSeg = [[UISegmentedControl alloc]
        initWithItems:@[
            YTKACELocalized(@"Skip (Cut)"),
            YTKACELocalized(@"Mute Audio"),
            YTKACELocalized(@"Full Video")
        ]];
    actionSeg.translatesAutoresizingMaskIntoConstraints = NO;
    if ([self.actionType isEqualToString:@"full"]) {
        actionSeg.selectedSegmentIndex = 2;
    } else if ([self.actionType isEqualToString:@"mute"]) {
        actionSeg.selectedSegmentIndex = 1;
    } else {
        actionSeg.selectedSegmentIndex = 0;
    }
    [actionSeg addTarget:self action:@selector(actionTypeChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:actionSeg];
    self.actionSegmentedControl = actionSeg;

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:card.topAnchor constant:10.0],
        [header.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],

        [pickerBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [pickerBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [pickerBtn.heightAnchor constraintEqualToConstant:24.0],

        [gridStack.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8.0],
        [gridStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [gridStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],

        [self.categoryDescLabel.topAnchor constraintEqualToAnchor:gridStack.bottomAnchor constant:8.0],
        [self.categoryDescLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [self.categoryDescLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],

        [actionSeg.topAnchor constraintEqualToAnchor:self.categoryDescLabel.bottomAnchor constant:10.0],
        [actionSeg.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [actionSeg.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [actionSeg.heightAnchor constraintEqualToConstant:32.0],
        [actionSeg.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12.0]
    ]];

    return card;
}

- (void)actionTypeChanged:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex == 2) {
        self.actionType = @"full";
        if (![self.selectedCategory isEqualToString:@"sponsor"] &&
            ![self.selectedCategory isEqualToString:@"selfpromo"]) {
            self.selectedCategory = @"sponsor";
        }
    } else if (sender.selectedSegmentIndex == 1) {
        if ([self.selectedCategory isEqualToString:@"music_offtopic"]) {
            self.actionType = @"skip";
            sender.selectedSegmentIndex = 0;
            YTKACEShowNotice(YTKACELocalized(@"Non-Music section only supports Skip"));
        } else {
            self.actionType = @"mute";
        }
    } else {
        self.actionType = @"skip";
    }
    AudioServicesPlaySystemSound(1519);
    [self updateCategorySelection];
}

- (void)categorySelected:(UIButton *)sender {
    NSArray *definitions = YTKACESponsorCategoryDefinitions();
    NSUInteger index = (NSUInteger)sender.tag;
    if (index < definitions.count) {
        NSString *newCat = definitions[index][@"id"];
        self.selectedCategory = newCat;
        if ([self.actionType isEqualToString:@"full"] &&
            ![newCat isEqualToString:@"sponsor"] &&
            ![newCat isEqualToString:@"selfpromo"]) {
            self.actionType = @"skip";
        }
        if ([self.actionType isEqualToString:@"mute"] &&
            [newCat isEqualToString:@"music_offtopic"]) {
            self.actionType = @"skip";
        }
        AudioServicesPlaySystemSound(1519);
        [self updateCategorySelection];
    }
}

- (void)updateCategorySelection {
    NSArray *definitions = YTKACESponsorCategoryDefinitions();
    for (NSUInteger i = 0; i < self.categoryButtons.count && i < definitions.count; i++) {
        UIButton *btn = self.categoryButtons[i];
        NSString *catID = definitions[i][@"id"];
        BOOL isSelected = [catID isEqualToString:self.selectedCategory];
        UIColor *catColor = YTKACESponsorCategoryColor(catID);
        if (isSelected) {
            btn.layer.borderColor = catColor.CGColor;
            btn.layer.borderWidth = 1.5;
            btn.backgroundColor = [catColor colorWithAlphaComponent:0.25];
        } else {
            btn.layer.borderWidth = 0.5;
            if (YTKACELiquidGlassAvailable()) {
                btn.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                    return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                        ? [UIColor colorWithWhite:1.0 alpha:0.10]
                        : [UIColor colorWithWhite:0.0 alpha:0.05];
                }];
                btn.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                    return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                        ? [UIColor colorWithWhite:1.0 alpha:0.12]
                        : [UIColor colorWithWhite:0.0 alpha:0.08];
                }].CGColor;
            } else {
                btn.layer.borderColor = UIColor.clearColor.CGColor;
                btn.layer.borderWidth = 0.0;
                btn.backgroundColor = YTKACEButtonBgColor();
            }
        }
    }
    if (self.previewCategoryDot != nil) {
        self.previewCategoryDot.backgroundColor = YTKACESponsorCategoryColor(self.selectedCategory);
    }
    if (self.previewCategoryLabel != nil) {
        self.previewCategoryLabel.text = YTKACESponsorCategoryTitle(self.selectedCategory);
    }
    self.categoryDescLabel.text = YTKACESponsorCategoryDescription(self.selectedCategory);
    self.submitButton.backgroundColor = YTKACESponsorCategoryColor(self.selectedCategory);

    BOOL isPOI = [self.selectedCategory isEqualToString:@"poi_highlight"];
    BOOL supportsFull = [self.selectedCategory isEqualToString:@"sponsor"] ||
                        [self.selectedCategory isEqualToString:@"selfpromo"];
    BOOL supportsMute = ![self.selectedCategory isEqualToString:@"music_offtopic"] && !isPOI;

    if (isPOI) {
        self.actionType = @"poi";
        self.actionSegmentedControl.enabled = NO;
        self.actionSegmentedControl.alpha = 0.4;
    } else {
        self.actionSegmentedControl.enabled = YES;
        self.actionSegmentedControl.alpha = 1.0;
        if ([self.actionType isEqualToString:@"poi"]) self.actionType = @"skip";
        if (self.actionSegmentedControl.numberOfSegments >= 3) {
            [self.actionSegmentedControl setEnabled:supportsMute forSegmentAtIndex:1];
            [self.actionSegmentedControl setEnabled:supportsFull forSegmentAtIndex:2];
        }
        if ([self.actionType isEqualToString:@"full"] && !supportsFull) {
            self.actionType = @"skip";
            self.actionSegmentedControl.selectedSegmentIndex = 0;
        } else if ([self.actionType isEqualToString:@"mute"] && !supportsMute) {
            self.actionType = @"skip";
            self.actionSegmentedControl.selectedSegmentIndex = 0;
        } else if ([self.actionType isEqualToString:@"full"]) {
            self.actionSegmentedControl.selectedSegmentIndex = 2;
        } else if ([self.actionType isEqualToString:@"mute"]) {
            self.actionSegmentedControl.selectedSegmentIndex = 1;
        } else {
            self.actionSegmentedControl.selectedSegmentIndex = 0;
        }
    }
    [self updateTimeLabels];
}

- (void)updateTimeLabels {
    [self stopCutPreview];
    BOOL isFull = [self.actionType isEqualToString:@"full"];
    BOOL isPOI = [self.selectedCategory isEqualToString:@"poi_highlight"];
    YTKACESponsorPreview check;
    BOOL canPreviewCut = !isFull && !isPOI && check.begin(self.startTime, self.endTime, self.videoDuration, false);
    BOOL isMute = [self.actionType isEqualToString:@"mute"];
    for (UIButton *button in @[self.previewCutButton, self.previewSkipButton]) {
        button.enabled = canPreviewCut;
        button.alpha = canPreviewCut ? 1.0 : 0.4;
        NSString *title = button == self.previewCutButton ? (isMute ? @"Mute" : @"Cut") : (isMute ? @"Preview Mute" : @"Preview Cut");
        [button setTitle:YTKACELocalized(title) forState:UIControlStateNormal];
        [button setImage:[UIImage systemImageNamed:isMute ? @"speaker.slash.fill" : @"scissors"] forState:UIControlStateNormal];
    }

    if (self.previewTimeLabel != nil) {
        self.previewTimeLabel.text = [NSString stringWithFormat:@"%@ → %@",
            YTKACEFormatSponsorTime(isFull ? 0.0 : self.startTime),
            YTKACEFormatSponsorTime(isFull ? (self.videoDuration > 0.0 ? self.videoDuration : 0.0) : self.endTime)];
    }

    if (isFull) {
        double dur = self.videoDuration > 0.0 ? self.videoDuration :
        ([self.videoID isEqualToString:YTKACESponsorCurrentVideoID()] ? YTKACESponsorCurrentDuration() : 0.0);
        self.startTimeLabel.text = YTKACEFormatSponsorTime(0.0);
        self.startSecLabel.text = @"(0.00s)";
        self.endTimeLabel.text = dur > 0.0 ? YTKACEFormatSponsorTime(dur) : YTKACELocalized(@"Full Video");
        self.endSecLabel.text = dur > 0.0 ? [NSString stringWithFormat:@"(%.2fs)", dur] : @"";

        self.lengthBadgeView.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.18];
        self.lengthBadgeLabel.textColor = UIColor.systemGreenColor;
        self.lengthBadgeLabel.text = [NSString stringWithFormat:@"%@: %@",
            YTKACELocalized(@"Full Video"),
            YTKACESponsorCategoryTitle(self.selectedCategory)];
        self.navigationItem.rightBarButtonItem.enabled = YES;
        self.submitButton.enabled = YES;
        self.submitButton.alpha = 1.0;
        self.previewSkipButton.enabled = NO;
        self.previewSkipButton.alpha = 0.4;
        return;
    }

    self.startTimeLabel.text = YTKACEFormatSponsorTime(self.startTime);
    self.startSecLabel.text = [NSString stringWithFormat:@"(%.2fs)", self.startTime];

    self.endTimeLabel.text = YTKACEFormatSponsorTime(self.endTime);
    self.endSecLabel.text = [NSString stringWithFormat:@"(%.2fs)", self.endTime];

    double diff = self.endTime - self.startTime;

    if (diff > 0.0 || (isPOI && diff >= 0.0)) {
        self.lengthBadgeView.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.18];
        self.lengthBadgeLabel.textColor = UIColor.systemGreenColor;
        self.lengthBadgeLabel.text = [NSString stringWithFormat:@"%@: %.2f %@",
            YTKACELocalized(@"Segment Length"), diff, YTKACELocalized(@"seconds")];
        self.navigationItem.rightBarButtonItem.enabled = YES;
        self.submitButton.enabled = YES;
        self.submitButton.alpha = 1.0;
        self.previewSkipButton.enabled = canPreviewCut;
        self.previewSkipButton.alpha = canPreviewCut ? 1.0 : 0.4;
    } else {
        self.lengthBadgeView.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.18];
        self.lengthBadgeLabel.textColor = UIColor.systemRedColor;
        self.lengthBadgeLabel.text = YTKACELocalized(@"End time must be after start time");
        self.navigationItem.rightBarButtonItem.enabled = NO;
        self.submitButton.enabled = NO;
        self.submitButton.alpha = 0.5;
        self.previewSkipButton.enabled = NO;
        self.previewSkipButton.alpha = 0.4;
    }
}

- (void)setStartToNow {
    if ([self.actionType isEqualToString:@"full"]) {
        self.actionType = @"skip";
        self.actionSegmentedControl.selectedSegmentIndex = 0;
    }
    double now = [self currentPreviewTime];
    if (self.videoDuration > 0.0) now = MIN(now, self.videoDuration);
    self.startTime = now;
    if (self.endTime <= now) self.endTime = self.videoDuration > now ? MIN(now + 5.0, self.videoDuration) : now;
    AudioServicesPlaySystemSound(1519);
    [self updateTimeLabels];
    [self requestPreviewAt:now play:NO];
}

- (void)setEndToNow {
    if ([self.actionType isEqualToString:@"full"]) {
        self.actionType = @"skip";
        self.actionSegmentedControl.selectedSegmentIndex = 0;
    }
    double now = [self currentPreviewTime];
    if (self.videoDuration > 0.0) now = MIN(now, self.videoDuration);
    self.endTime = now;
    AudioServicesPlaySystemSound(1519);
    [self updateTimeLabels];
    [self requestPreviewAt:now play:NO];
}

- (void)setEndToDuration {
    if ([self.actionType isEqualToString:@"full"]) {
        self.actionType = @"skip";
        self.actionSegmentedControl.selectedSegmentIndex = 0;
    }
    double dur = self.videoDuration > 0.0 ? self.videoDuration :
        ([self.videoID isEqualToString:YTKACESponsorCurrentVideoID()] ? YTKACESponsorCurrentDuration() : 0.0);
    if (dur <= 0.0) {
        for (YTKACEVideoChapter *ch in ([self.videoID isEqualToString:YTKACESponsorCurrentVideoID()] ? YTKACESponsorCurrentChapters() : @[])) {
            if (ch.endTime > dur) dur = ch.endTime;
        }
        if (dur > 0.0) self.videoDuration = dur;
    }
    if (dur > 0.0) {
        self.endTime = dur;
    } else {
        self.endTime = self.startTime + 5.0;
    }
    AudioServicesPlaySystemSound(1519);
    [self updateTimeLabels];
    [self requestPreviewAt:self.endTime play:NO];
}

- (void)seekToStart {
    [self requestPreviewAt:self.startTime play:YES];
}

- (void)seekToEnd {
    [self requestPreviewAt:self.endTime play:YES];
}

- (void)stepStart:(UIButton *)sender {
    if ([self.actionType isEqualToString:@"full"]) {
        self.actionType = @"skip";
        self.actionSegmentedControl.selectedSegmentIndex = 0;
    }
    double delta = (double)sender.tag / 10.0;
    double dur = self.videoDuration > 0.0 ? self.videoDuration :
        ([self.videoID isEqualToString:YTKACESponsorCurrentVideoID()] ? YTKACESponsorCurrentDuration() : 0.0);
    if (dur <= 0.0) {
        for (YTKACEVideoChapter *ch in ([self.videoID isEqualToString:YTKACESponsorCurrentVideoID()] ? YTKACESponsorCurrentChapters() : @[])) {
            if (ch.endTime > dur) dur = ch.endTime;
        }
        if (dur > 0.0) self.videoDuration = dur;
    }
    double newStart = MAX(0.0, self.startTime + delta);
    if (dur > 0.0 && newStart > dur) newStart = dur;
    self.startTime = newStart;
    AudioServicesPlaySystemSound(1519);
    [self updateTimeLabels];
    [self requestPreviewAt:self.startTime play:NO];
}

- (void)stepEnd:(UIButton *)sender {
    if ([self.actionType isEqualToString:@"full"]) {
        self.actionType = @"skip";
        self.actionSegmentedControl.selectedSegmentIndex = 0;
    }
    double delta = (double)sender.tag / 10.0;
    double dur = self.videoDuration > 0.0 ? self.videoDuration :
        ([self.videoID isEqualToString:YTKACESponsorCurrentVideoID()] ? YTKACESponsorCurrentDuration() : 0.0);
    if (dur <= 0.0) {
        for (YTKACEVideoChapter *ch in ([self.videoID isEqualToString:YTKACESponsorCurrentVideoID()] ? YTKACESponsorCurrentChapters() : @[])) {
            if (ch.endTime > dur) dur = ch.endTime;
        }
        if (dur > 0.0) self.videoDuration = dur;
    }
    double newEnd = MAX(0.0, self.endTime + delta);
    if (dur > 0.0 && newEnd > dur) newEnd = dur;
    self.endTime = newEnd;
    AudioServicesPlaySystemSound(1519);
    [self updateTimeLabels];
    [self requestPreviewAt:self.endTime play:NO];
}

static double YTKACEParseManualTimestamp(NSString *raw) {
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return YTKACEMedia::parseTimestamp(trimmed.UTF8String ?: "");
}

- (void)promptManualTimestampForStart:(BOOL)isStart {
    double currentVal = isStart ? self.startTime : self.endTime;
    NSString *alertTitle = isStart ? YTKACELocalized(@"Set Start Time") : YTKACELocalized(@"END TIME");
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:alertTitle
                          message:YTKACELocalized(@"Enter exact timestamp (mm:ss.SS or seconds):")
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = YTKACEFormatSponsorTime(currentVal);
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    __weak YTKACESponsorSubmitController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"OK")
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *act) {
        YTKACESponsorSubmitController *strongSelf = weakSelf;
        if (!strongSelf) return;
        double parsed = YTKACEParseManualTimestamp(alert.textFields.firstObject.text);
        if (parsed >= 0.0) {
            if ([strongSelf.actionType isEqualToString:@"full"]) {
                strongSelf.actionType = @"skip";
                strongSelf.actionSegmentedControl.selectedSegmentIndex = 0;
            }
            double dur = strongSelf.videoDuration > 0.0 ? strongSelf.videoDuration :
                ([strongSelf.videoID isEqualToString:YTKACESponsorCurrentVideoID()] ? YTKACESponsorCurrentDuration() : 0.0);
            if (dur <= 0.0) {
                for (YTKACEVideoChapter *ch in ([strongSelf.videoID isEqualToString:YTKACESponsorCurrentVideoID()] ? YTKACESponsorCurrentChapters() : @[])) {
                    if (ch.endTime > dur) dur = ch.endTime;
                }
                if (dur > 0.0) strongSelf.videoDuration = dur;
            }
            if (dur > 0.0 && parsed > dur) parsed = dur;
            if (isStart) {
                strongSelf.startTime = parsed;
            } else {
                strongSelf.endTime = parsed;
            }
            AudioServicesPlaySystemSound(1519);
            [strongSelf updateTimeLabels];
            [strongSelf requestPreviewAt:parsed play:NO];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editStartTimeTapped {
    [self promptManualTimestampForStart:YES];
}

- (void)editEndTimeTapped {
    [self promptManualTimestampForStart:NO];
}

- (void)previewSkipTapped {
    if ([self.actionType isEqualToString:@"full"] || [self.selectedCategory isEqualToString:@"poi_highlight"]) return;
    double duration = self.videoDuration;
    YTKACESponsorPreview check;
    if (!check.begin(self.startTime, self.endTime, duration, [self.actionType isEqualToString:@"mute"])) {
        YTKACEShowNotice(YTKACELocalized(@"End time must be after start time"));
        return;
    }
    [self stopCutPreview];
    self.previewSeekTime = check.leadIn();
    self.pendingPreviewRequest = YTKACESponsorPreviewRequestCut;
    [self performPendingPreviewRequest];
}

- (void)beginCutPreview {
    [self stopCutPreview];
    double duration = self.videoDuration;
    double itemDuration = CMTimeGetSeconds(self.previewPlayer.currentItem.duration);
    if (isfinite(itemDuration) && itemDuration > 0.0) duration = duration > 0.0 ? MIN(duration, itemDuration) : itemDuration;
    if (!_cutPreview.begin(self.startTime, self.endTime, duration, [self.actionType isEqualToString:@"mute"])) return;
    self.isPlaying = YES;
    [self updatePlayPauseButtonUI];
    self.previewStatusLabel.text = YTKACELocalized(@"Seeking preview…");
    self.previewPlayer.currentItem.forwardPlaybackEndTime = CMTimeMakeWithSeconds(_cutPreview.targetEnd(), 60000);
    NSMutableArray<NSValue *> *times = [NSMutableArray array];
    double previous = -1.0;
    for (double time : {_cutPreview.start(), _cutPreview.end(), _cutPreview.targetEnd()}) {
        if (time > previous) [times addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(time, 60000)]];
        previous = time;
    }
    __weak YTKACESponsorSubmitController *weakSelf = self;
    self.previewBoundaryObserver = [self.previewPlayer addBoundaryTimeObserverForTimes:times
        queue:dispatch_get_main_queue() usingBlock:^{ [weakSelf updatePreviewPlayback]; }];
    [self seekPreviewTo:_cutPreview.leadIn() completion:^{
        YTKACESponsorSubmitController *controller = weakSelf;
        if (controller == nil) return;
        controller->_cutPreview.seekCompleted(true);
        // A segment at 0 must cut before any of its audio is played.
        [controller updatePreviewPlayback];
        [controller playPreviewIfRequested];
    }];
}

- (void)handleCutPreviewAction:(YTKACESponsorPreview::Action)action {
    switch (action) {
        case YTKACESponsorPreview::Action::SeekToEnd: {
            self.previewStatusLabel.text = YTKACELocalized(@"Seeking preview…");
            __weak YTKACESponsorSubmitController *weakSelf = self;
            [self seekPreviewTo:_cutPreview.end() completion:^{
                YTKACESponsorSubmitController *controller = weakSelf;
                if (controller == nil) return;
                auto next = controller->_cutPreview.seekCompleted(true);
                [controller handleCutPreviewAction:next];
                [controller updatePreviewPlayback];
                [controller playPreviewIfRequested];
            }];
            break;
        }
        case YTKACESponsorPreview::Action::Mute: self.previewPlayer.muted = YES; break;
        case YTKACESponsorPreview::Action::Unmute: self.previewPlayer.muted = NO; break;
        case YTKACESponsorPreview::Action::Finish: [self finishCutPreview]; break;
        case YTKACESponsorPreview::Action::None: break;
    }
}

- (void)finishCutPreview {
    [self stopCutPreview];
    self.previewStatusLabel.text = YTKACELocalized(@"Preview finished");
}

- (void)cancelTapped {
    BOOL hadDraft = YTKACESponsorSubmitCoordinator.sharedCoordinator.hasDraftStart;
    [YTKACESponsorSubmitCoordinator.sharedCoordinator clearDraft];
    if (self.onDismiss) self.onDismiss();
    [self dismissViewControllerAnimated:YES completion:^{
        if (hadDraft) {
            AudioServicesPlaySystemSound(1520);
            YTKACEShowNotice(YTKACELocalized(@"Draft discarded"));
        }
    }];
}

- (void)submitTapped {
    if (self.videoID.length == 0) {
        YTKACEShowNotice(YTKACELocalized(@"No active video"));
        return;
    }
    BOOL isPOI = [self.selectedCategory isEqualToString:@"poi_highlight"];
    BOOL isFull = [self.actionType isEqualToString:@"full"];
    if (!isFull && (self.endTime < self.startTime || (!isPOI && self.endTime <= self.startTime))) {
        YTKACEShowNotice(YTKACELocalized(@"End time must be after start time"));
        return;
    }

    [self stopCutPreview];
    self.submitButton.enabled = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self.spinner startAnimating];
    [self.submitButton setTitle:@"" forState:UIControlStateNormal];

    NSString *actionType = isPOI ? @"poi" : (self.actionType.length > 0 ? self.actionType : @"skip");
    if ([self.selectedCategory isEqualToString:@"music_offtopic"]) {
        actionType = @"skip";
    }
    if ([actionType isEqualToString:@"full"] &&
        ![self.selectedCategory isEqualToString:@"sponsor"] &&
        ![self.selectedCategory isEqualToString:@"selfpromo"]) {
        actionType = @"skip";
    }

    double duration = self.videoDuration > 0.0 ? self.videoDuration :
        ([self.videoID isEqualToString:YTKACESponsorCurrentVideoID()] ? YTKACESponsorCurrentDuration() : 0.0);
    double submitStart = isFull ? 0.0 : self.startTime;
    double submitEnd = isFull ? 0.0 : (isPOI ? submitStart : self.endTime);
    if (duration > 0.0 && !isFull && !isPOI) {
        if (submitEnd > duration) submitEnd = duration;
        if (submitStart > duration) submitStart = duration;
    }

    __weak YTKACESponsorSubmitController *weakSelf = self;
    [YTKACESponsorClient.sharedClient submitSegmentForVideoID:self.videoID
                                                        start:submitStart
                                                          end:submitEnd
                                                     category:self.selectedCategory
                                                   actionType:actionType
                                                videoDuration:duration
                                                   completion:^(BOOL success, NSString *message) {
        YTKACESponsorSubmitController *strongSelf = weakSelf;
        if (!strongSelf) return;

        [strongSelf.spinner stopAnimating];
        [strongSelf.submitButton setTitle:YTKACELocalized(@"Submit to SponsorBlock") forState:UIControlStateNormal];
        strongSelf.submitButton.enabled = YES;
        strongSelf.navigationItem.rightBarButtonItem.enabled = YES;

        if (success) {
            AudioServicesPlaySystemSound(1057);
            UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
            [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];

            NSInteger curSubs = YTKACESponsorSubmissionsCount();
            YTKACESetPreferenceObject(YTKACESponsorSubmissionsCountKey, @(curSubs + 1));
            YTKACESponsorFetchUserInfo(nil);

            [YTKACESponsorSubmitCoordinator.sharedCoordinator clearDraft];

            // Enable the submitted category so the new segment takes effect.
            if (YTKACESponsorCategoryBehavior(strongSelf.selectedCategory) == 2) {
                NSInteger newBehavior = [strongSelf.selectedCategory isEqualToString:@"poi_highlight"] ? 1 : 0;
                YTKACESetPreferenceObject(YTKACESponsorBehaviorKey(strongSelf.selectedCategory), @(newBehavior));
            }

            NSDictionary *submittedSeg = @{
                @"start": @(submitStart),
                @"end": @(submitEnd),
                @"category": strongSelf.selectedCategory ?: @"sponsor",
                @"actionType": actionType ?: @"skip",
                @"uuid": @""
            };
            for (NSDictionary *local in [YTKACESponsorClient.sharedClient localSegmentsForVideoID:strongSelf.videoID]) {
                if ([local[@"category"] isEqualToString:submittedSeg[@"category"]] &&
                    [local[@"actionType"] isEqualToString:submittedSeg[@"actionType"]] &&
                    fabs([local[@"start"] doubleValue] - submitStart) < 0.002 &&
                    fabs([local[@"end"] doubleValue] - submitEnd) < 0.002) {
                    submittedSeg = local;
                    break;
                }
            }
            YTKACESponsorAddActiveSegment(strongSelf.videoID, submittedSeg);

            YTKACEShowNotice(YTKACELocalized(@"Segment submitted to SponsorBlock!"));
            if (strongSelf.onDismiss) strongSelf.onDismiss();
            [strongSelf dismissViewControllerAnimated:YES completion:nil];
        } else {
            UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
            [feedback notificationOccurred:UINotificationFeedbackTypeError];

            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:YTKACELocalized(@"Submission Failed")
                                 message:message ?: YTKACELocalized(@"An unknown error occurred.")
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"OK")
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil]];
            [strongSelf presentViewController:alert animated:YES completion:nil];
        }
    }];
}

@end

void YTKACEPresentSponsorSubmitController(NSString *videoID,
                                          double startTime,
                                          double endTime,
                                          UIViewController *presenter) {
    if (videoID.length > 0 && ![videoID isEqualToString:YTKACESponsorCurrentVideoID()]) {
        YTKACEShowNotice(YTKACELocalized(@"No active video"));
        return;
    }
    [YTKACESponsorSubmitCoordinator.sharedCoordinator dismissDraftBanner];
    if (presenter == nil) {
        presenter = YTKACEFindTopController();
    }
    if (presenter == nil) return;

    YTKACESponsorSubmitController *controller = [YTKACESponsorSubmitController new];
    controller.videoID = videoID.length > 0 ? videoID : YTKACESponsorCurrentVideoID();
    controller.videoTitle = YTKACESponsorCurrentVideoTitle();
    controller.videoDuration = YTKACESponsorCurrentDuration();
    double dur = controller.videoDuration;
    if (dur <= 0.0) {
        for (YTKACEVideoChapter *ch in YTKACESponsorCurrentChapters()) {
            if (ch.endTime > dur) dur = ch.endTime;
        }
        controller.videoDuration = dur;
    }

    if (dur > 0.0) {
        if (startTime >= dur) {
            startTime = MAX(0.0, dur - 10.0);
            endTime = dur;
        } else {
            BOOL isShort = YTKACEResolveShortsPlayback(YTKACEActivePlayerViewController(), NULL);
            if (endTime >= dur - (isShort ? 0.05 : 1.5) || endTime > dur) endTime = dur;
            if ((endTime <= 0.0 || endTime <= startTime) && dur > startTime) {
                endTime = dur;
            }
        }
    } else {
        if (endTime <= startTime) {
            endTime = startTime + 5.0;
        }
    }
    if (startTime < 0.0) startTime = 0.0;
    if (endTime < 0.0) endTime = 0.0;

    controller.startTime = startTime;
    controller.endTime = endTime > startTime ? endTime : (startTime + 1.0);

    for (YTKACEVideoChapter *ch in YTKACESponsorCurrentChapters()) {
        if (fabs(ch.startTime - startTime) < 0.25 && fabs(ch.endTime - endTime) < 0.25) {
            controller.selectedCategory = ch.suggestedCategory;
            break;
        }
    }

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[
            UISheetPresentationControllerDetent.mediumDetent,
            UISheetPresentationControllerDetent.largeDetent
        ];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierMedium;
        sheet.largestUndimmedDetentIdentifier = UISheetPresentationControllerDetentIdentifierMedium;
        sheet.prefersGrabberVisible = YES;
        sheet.prefersEdgeAttachedInCompactHeight = NO;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
        sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = YES;
    }
    if (YTKACELiquidGlassAvailable()) {
        YTKACEApplyMenuGlassBackground(nav.view, 24.0);
        nav.navigationBar.backgroundColor = UIColor.clearColor;
        nav.navigationBar.translucent = YES;
        [nav.navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
        nav.navigationBar.shadowImage = [UIImage new];
    }
    [presenter presentViewController:nav animated:YES completion:nil];
}

void YTKACEConfigureShortsSponsorSubmit(UIView *host, UIButton *downloadButton, UIView *railAction) {
    static const void *key = &key;
    YTKACESponsorSubmitCoordinator *coordinator = YTKACESponsorSubmitCoordinator.sharedCoordinator;
    UIButton *button = objc_getAssociatedObject(host, key);
    BOOL enabled = YTKACESponsorBlockEnabled() && YTKACESponsorSubmitButtonEnabled() &&
        YTKACEFeatureEnabled(YTKACESponsorShortsKey);
    if (button == nil && enabled) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.accessibilityIdentifier = @"YTKACE Shorts SponsorBlock Submit";
        button.accessibilityLabel = YTKACELocalized(@"SponsorBlock");
        button.accessibilityHint = YTKACELocalized(@"Mark segment to submit");
        button.backgroundColor = UIColor.clearColor;
        button.layer.shadowColor = UIColor.blackColor.CGColor;
        button.layer.shadowOpacity = 0.55;
        button.layer.shadowRadius = 4.0;
        button.layer.shadowOffset = CGSizeMake(0.0, 2.0);
        [button setImage:[YTKACEAssetImage(@"sponsorblock_shield_template", @"play.shield")
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                forState:UIControlStateNormal];
        [button setPreferredSymbolConfiguration:[UIImageSymbolConfiguration
            configurationWithPointSize:21.0 weight:UIImageSymbolWeightMedium]
            forImageInState:UIControlStateNormal];
        [button addTarget:coordinator action:@selector(handleShortsButtonTap:)
            forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
            initWithTarget:coordinator action:@selector(handleButtonLongPress:)];
        press.minimumPressDuration = 0.5;
        [button addGestureRecognizer:press];
        [host addSubview:button];
        objc_setAssociatedObject(host, key, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [coordinator.shortsButtons addObject:button];
    }
    if (button == nil) return;
    if (button.superview != host) [host addSubview:button];
    button.hidden = !enabled;
    button.backgroundColor = UIColor.clearColor;
    button.tintColor = coordinator.hasDraftStart ? YTKACEAccentColor() : UIColor.whiteColor;
    UIEdgeInsets safe = host.safeAreaInsets;
    BOOL hasDownload = downloadButton != nil && !downloadButton.hidden &&
        !CGRectIsEmpty(downloadButton.frame);
    CGRect anchor = CGRectZero;
    if (hasDownload) {
        anchor = [downloadButton convertRect:downloadButton.bounds toView:host];
    } else if (railAction != nil) {
        anchor = [railAction convertRect:railAction.bounds toView:host];
    }
    BOOL topDownload = hasDownload && [NSUserDefaults.standardUserDefaults
        integerForKey:@"YTKACE.Preference.Shorts.DownloadPosition"] == 0;
    auto frame = YTKACEShorts::submitFrame(
        {safe.left + 8.0, safe.top + 8.0,
         CGRectGetWidth(host.bounds) - safe.left - safe.right - 16.0,
         CGRectGetHeight(host.bounds) - safe.top - safe.bottom - 16.0},
        {anchor.origin.x, anchor.origin.y, anchor.size.width, anchor.size.height},
        hasDownload || railAction != nil, topDownload);
    button.frame = CGRectMake(round(frame.x), round(frame.y), frame.width, frame.height);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        (topDownload ? UIViewAutoresizingFlexibleBottomMargin : UIViewAutoresizingFlexibleTopMargin);
    [host bringSubviewToFront:button];
    // Container and overlay layouts can both run for the same visible Short.
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:host];
    while (pending.count > 0) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        for (UIView *child in view.subviews) {
            if (child != button && [child.accessibilityIdentifier isEqualToString:button.accessibilityIdentifier]) {
                [child removeFromSuperview];
            } else {
                [pending addObject:child];
            }
        }
    }
}

void YTKACEInstallSponsorSubmitControls(void) {
    YTKACERegisterOverlayConfigurator(@"sponsorblock_submit", ^(UIView *overlay, UIStackView *stack) {
        YTKACESponsorSubmitCoordinator *coordinator = YTKACESponsorSubmitCoordinator.sharedCoordinator;
        coordinator.overlay = overlay;

        UIButton *button = YTKACEOverlayButton(
            stack,
            @"YTKACE SponsorBlock Submit",
            @"play.shield",
            coordinator,
            @selector(handleRegularButtonTap)
        );

        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:21.0
                                                            weight:UIImageSymbolWeightMedium];
        UIImage *shield = YTKACEAssetImage(@"sponsorblock_shield_template", @"play.shield");
        if (shield != nil) {
            [button setImage:[[shield imageByApplyingSymbolConfiguration:configuration]
                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                      forState:UIControlStateNormal];
        }

        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:coordinator action:@selector(handleButtonLongPress:)];
        longPress.minimumPressDuration = 0.5;
        [button addGestureRecognizer:longPress];

        coordinator.button = button;
        [coordinator updateButton];
    });
}

#pragma clang diagnostic pop
