#import "SponsorSubmitController.h"
#import "SponsorClient.h"
#import "SponsorPreferences.h"
#import "SponsorHooks.h"
#import "../../YTKACE.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Assets.h"
#import "../../UI/Notice.h"
#import "../../UI/OverlayButtonHost.h"
#import "../../Settings/YTKACESettingsPages.h"

#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
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

- (void)updateButton {
    if (self.button == nil) return;
    BOOL enabled = YTKACESponsorBlockEnabled() && YTKACESponsorSubmitButtonEnabled();
    self.button.hidden = !enabled;
    if (!enabled) return;

    if (self.hasDraftStart) {
        self.button.tintColor = YTKACEAccentColor();
    } else {
        self.button.tintColor = UIColor.whiteColor;
    }
}

- (void)handleButtonLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    AudioServicesPlaySystemSound(1519);
    NSString *videoID = YTKACESponsorCurrentVideoID();
    if (videoID.length == 0) {
        YTKACEShowNotice(YTKACELocalized(@"No active video"));
        return;
    }
    double start = self.hasDraftStart ? self.draftStartTime : YTKACESponsorCurrentTime();
    double end = self.hasDraftEnd ? self.draftEndTime : (self.hasDraftStart ? YTKACESponsorCurrentTime() : start);
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
        if (self.button != nil && self.button.window != nil) {
            alert.popoverPresentationController.sourceView = self.button;
            alert.popoverPresentationController.sourceRect = self.button.bounds;
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
        if (self.button != nil && self.button.window != nil) {
            alert.popoverPresentationController.sourceView = self.button;
            alert.popoverPresentationController.sourceRect = self.button.bounds;
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
        if (self.button != nil && self.button.window != nil) {
            alert.popoverPresentationController.sourceView = self.button;
            alert.popoverPresentationController.sourceRect = self.button.bounds;
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

    double now = YTKACESponsorCurrentTime();
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
                if (!strongSelf) return;
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
            @"title": YTKACELocalized(@"Mark Full Video..."),
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
                                 self.button,
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
                if (!strongSelf) return;
                strongSelf.draftEndTime = now;
                strongSelf.hasDraftEnd = YES;
                YTKACEPresentSponsorSubmitController(videoID, strongSelf.draftStartTime, now, nil);
            } copy]
        }];
        [actions addObject:@{
            @"title": YTKACELocalized(@"Edit Segment..."),
            @"icon": [UIImage systemImageNamed:@"slider.horizontal.3"] ?: [UIImage new],
            @"handler": [^{
                YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                if (!strongSelf) return;
                double end = strongSelf.hasDraftEnd ? strongSelf.draftEndTime : now;
                YTKACEPresentSponsorSubmitController(videoID, strongSelf.draftStartTime, end, nil);
            } copy]
        }];
        [actions addObject:@{
            @"title": [NSString stringWithFormat:@"%@ (%@)", YTKACELocalized(@"Update Start Time"), nowText],
            @"icon": [UIImage systemImageNamed:@"arrow.counterclockwise"] ?: [UIImage new],
            @"handler": [^{
                YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.draftStartTime = now;
                [strongSelf updateButton];
                AudioServicesPlaySystemSound(1519);
                [strongSelf showDraftStartBannerWithMessage:[NSString stringWithFormat:@"%@: %@",
                    YTKACELocalized(@"Segment start updated"), nowText]];
            } copy]
        }];
        [actions addObject:@{
            @"title": YTKACELocalized(@"Cancel Segment"),
            @"icon": [UIImage systemImageNamed:@"xmark.circle"] ?: [UIImage new],
            @"handler": [^{
                YTKACESponsorSubmitCoordinator *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf clearDraft];
                AudioServicesPlaySystemSound(1520);
                YTKACEShowNotice(YTKACELocalized(@"Draft discarded"));
            } copy]
        }];
        YTKACEPresentNativeSheet(YTKACELocalized(@"SponsorBlock Draft"),
                                 [NSString stringWithFormat:@"%@: %@", YTKACELocalized(@"Recording segment from"), startText],
                                 self.button,
                                 actions);
    }
}

- (void)presentFullVideoPickerForVideoID:(NSString *)videoID {
    void (^openFullEditor)(NSString *) = ^(NSString *categoryID) {
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
            nav.sheetPresentationController.detents = @[
                UISheetPresentationControllerDetent.largeDetent
            ];
            nav.sheetPresentationController.prefersGrabberVisible = YES;
            nav.sheetPresentationController.prefersEdgeAttachedInCompactHeight = NO;
            nav.sheetPresentationController.widthFollowsPreferredContentSizeWhenEdgeAttached = YES;
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
        @"title": [NSString stringWithFormat:@"%@: %@", YTKACELocalized(@"Full Video"), YTKACESponsorCategoryTitle(@"sponsor")],
        @"subtitle": YTKACESponsorCategoryDescription(@"sponsor"),
        @"icon": [UIImage systemImageNamed:@"dollarsign.circle.fill"] ?: [UIImage new],
        @"handler": [^{
            openFullEditor(@"sponsor");
        } copy]
    }];
    [actions addObject:@{
        @"title": [NSString stringWithFormat:@"%@: %@", YTKACELocalized(@"Full Video"), YTKACESponsorCategoryTitle(@"selfpromo")],
        @"subtitle": YTKACESponsorCategoryDescription(@"selfpromo"),
        @"icon": [UIImage systemImageNamed:@"megaphone.fill"] ?: [UIImage new],
        @"handler": [^{
            openFullEditor(@"selfpromo");
        } copy]
    }];

    YTKACEPresentNativeSheet(YTKACELocalized(@"Mark Full Video..."),
                             YTKACELocalized(@"Choose a category for the entire video:"),
                             self.button,
                             actions);
}

@end

@interface YTKACESponsorSubmitController ()
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIView *contentView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *videoIDBadge;
@property(nonatomic, strong) UILabel *durationLabel;
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
@end

@implementation YTKACESponsorSubmitController

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

    // 1b. Select Video Chapter Button
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

    // 2. Start Time Card
    UIView *startCard = [self buildTimeCardWithTitle:YTKACELocalized(@"START TIME")
                                             isStart:YES];
    [self.contentView addSubview:startCard];

    // 3. End Time Card
    UIView *endCard = [self buildTimeCardWithTitle:YTKACELocalized(@"END TIME")
                                           isStart:NO];
    [self.contentView addSubview:endCard];

    // 4. Length Indicator Badge
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

    // 5. Category Selection Card
    UIView *categoryCard = [self buildCategoryCard];
    [self.contentView addSubview:categoryCard];

    // 6. Preview Skip Button
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
    [self.previewSkipButton setTitle:YTKACELocalized(@"Preview Skip (Hear Cut)") forState:UIControlStateNormal];
    [self.previewSkipButton setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
    self.previewSkipButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [self.previewSkipButton setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    self.previewSkipButton.tintColor = YTKACEAccentColor();
    self.previewSkipButton.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 8);
    [self.previewSkipButton addTarget:self action:@selector(previewSkipTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.previewSkipButton];

    // 7. Big Bottom Submit Button
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
        [chapterButton.topAnchor constraintEqualToAnchor:infoCard.bottomAnchor constant:10.0],
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
    nowBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    if (isStart) {
        [nowBtn addTarget:self action:@selector(setStartToNow) forControlEvents:UIControlEventTouchUpInside];
    } else {
        [nowBtn addTarget:self action:@selector(setEndToNow) forControlEvents:UIControlEventTouchUpInside];
    }
    [card addSubview:nowBtn];

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
    seekBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    if (isStart) {
        [seekBtn addTarget:self action:@selector(seekToStart) forControlEvents:UIControlEventTouchUpInside];
    } else {
        [seekBtn addTarget:self action:@selector(seekToEnd) forControlEvents:UIControlEventTouchUpInside];
    }
    [card addSubview:seekBtn];

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

        [seekBtn.centerYAnchor constraintEqualToAnchor:timeLabel.centerYAnchor],
        [seekBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [seekBtn.widthAnchor constraintEqualToConstant:70.0],
        [seekBtn.heightAnchor constraintEqualToConstant:30.0],

        [nowBtn.centerYAnchor constraintEqualToAnchor:timeLabel.centerYAnchor],
        [nowBtn.trailingAnchor constraintEqualToAnchor:seekBtn.leadingAnchor constant:-8.0],
        [nowBtn.widthAnchor constraintEqualToConstant:70.0],
        [nowBtn.heightAnchor constraintEqualToConstant:30.0],

        [stepStack.topAnchor constraintEqualToAnchor:timeLabel.bottomAnchor constant:10.0],
        [stepStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [stepStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [stepStack.heightAnchor constraintEqualToConstant:32.0],
        [stepStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12.0]
    ]];

    return card;
}

- (UIView *)buildCategoryCard {
    UIView *card = [self buildCardView];

    UILabel *header = [UILabel new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    header.textColor = YTKACESubtitleColor();
    header.text = YTKACELocalized(@"CATEGORY");
    [card addSubview:header];

    UIScrollView *catScroll = [UIScrollView new];
    catScroll.translatesAutoresizingMaskIntoConstraints = NO;
    catScroll.showsHorizontalScrollIndicator = NO;
    [card addSubview:catScroll];

    UIStackView *catStack = [UIStackView new];
    catStack.translatesAutoresizingMaskIntoConstraints = NO;
    catStack.axis = UILayoutConstraintAxisHorizontal;
    catStack.spacing = 8.0;
    catStack.alignment = UIStackViewAlignmentCenter;
    [catScroll addSubview:catStack];

    [NSLayoutConstraint activateConstraints:@[
        [catStack.topAnchor constraintEqualToAnchor:catScroll.contentLayoutGuide.topAnchor],
        [catStack.bottomAnchor constraintEqualToAnchor:catScroll.contentLayoutGuide.bottomAnchor],
        [catStack.leadingAnchor constraintEqualToAnchor:catScroll.contentLayoutGuide.leadingAnchor constant:14.0],
        [catStack.trailingAnchor constraintEqualToAnchor:catScroll.contentLayoutGuide.trailingAnchor constant:-14.0],
        [catStack.heightAnchor constraintEqualToAnchor:catScroll.frameLayoutGuide.heightAnchor]
    ]];

    NSArray *definitions = YTKACESponsorCategoryDefinitions();
    for (NSUInteger i = 0; i < definitions.count; i++) {
        NSDictionary *def = definitions[i];
        NSString *catID = def[@"id"];
        NSString *catTitle = def[@"title"];
        UIColor *color = YTKACESponsorCategoryColor(catID);

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        btn.layer.cornerRadius = 16.0;
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
        btn.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
        btn.tag = (NSInteger)i;

        // Custom chip view with colored dot and label
        UIStackView *chipContent = [UIStackView new];
        chipContent.userInteractionEnabled = NO;
        chipContent.axis = UILayoutConstraintAxisHorizontal;
        chipContent.spacing = 6.0;
        chipContent.alignment = UIStackViewAlignmentCenter;
        chipContent.translatesAutoresizingMaskIntoConstraints = NO;
        [btn addSubview:chipContent];

        UIView *dot = [UIView new];
        dot.backgroundColor = color;
        dot.layer.cornerRadius = 5.0;
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        [dot.widthAnchor constraintEqualToConstant:10.0].active = YES;
        [dot.heightAnchor constraintEqualToConstant:10.0].active = YES;
        [chipContent addArrangedSubview:dot];

        UILabel *label = [UILabel new];
        label.text = catTitle;
        label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        label.textColor = YTKACETitleColor();
        [chipContent addArrangedSubview:label];

        [NSLayoutConstraint activateConstraints:@[
            [chipContent.centerXAnchor constraintEqualToAnchor:btn.centerXAnchor],
            [chipContent.centerYAnchor constraintEqualToAnchor:btn.centerYAnchor],
            [btn.heightAnchor constraintEqualToConstant:32.0],
            [btn.widthAnchor constraintGreaterThanOrEqualToAnchor:chipContent.widthAnchor constant:24.0]
        ]];

        [btn addTarget:self action:@selector(categorySelected:) forControlEvents:UIControlEventTouchUpInside];
        [catStack addArrangedSubview:btn];
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

        [catScroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8.0],
        [catScroll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [catScroll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [catScroll.heightAnchor constraintEqualToConstant:36.0],

        [self.categoryDescLabel.topAnchor constraintEqualToAnchor:catScroll.bottomAnchor constant:8.0],
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
        self.actionType = @"mute";
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
            self.actionSegmentedControl.selectedSegmentIndex = 0;
        }
        AudioServicesPlaySystemSound(1519);
        [self updateCategorySelection];
    }
}

- (void)updateCategorySelection {
    NSArray *definitions = YTKACESponsorCategoryDefinitions();
    for (NSUInteger i = 0; i < self.categoryButtons.count; i++) {
        UIButton *btn = self.categoryButtons[i];
        NSString *catID = definitions[i][@"id"];
        BOOL isSelected = [catID isEqualToString:self.selectedCategory];
        UIColor *catColor = YTKACESponsorCategoryColor(catID);
        if (isSelected) {
            btn.layer.borderColor = catColor.CGColor;
            btn.layer.borderWidth = 1.5;
            btn.backgroundColor = [catColor colorWithAlphaComponent:0.25];
        } else {
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
                btn.layer.borderColor = UIColor.clearColor.CGColor;
                btn.layer.borderWidth = 0.0;
                btn.backgroundColor = YTKACEButtonBgColor();
            }
        }
    }
    self.categoryDescLabel.text = YTKACESponsorCategoryDescription(self.selectedCategory);
    self.submitButton.backgroundColor = YTKACESponsorCategoryColor(self.selectedCategory);
    BOOL isPOI = [self.selectedCategory isEqualToString:@"poi_highlight"];
    BOOL supportsFull = [self.selectedCategory isEqualToString:@"sponsor"] ||
                        [self.selectedCategory isEqualToString:@"selfpromo"];
    if (self.actionSegmentedControl.numberOfSegments >= 3) {
        [self.actionSegmentedControl setEnabled:supportsFull forSegmentAtIndex:2];
    }
    self.actionSegmentedControl.enabled = !isPOI;
    self.actionSegmentedControl.alpha = isPOI ? 0.4 : 1.0;
    [self updateTimeLabels];
}

- (void)updateTimeLabels {
    BOOL isFull = [self.actionType isEqualToString:@"full"];
    BOOL isPOI = [self.selectedCategory isEqualToString:@"poi_highlight"];

    if (isFull) {
        double dur = self.videoDuration > 0.0 ? self.videoDuration : YTKACESponsorCurrentDuration();
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

    self.previewSkipButton.enabled = YES;
    self.previewSkipButton.alpha = 1.0;

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
    } else {
        self.lengthBadgeView.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.18];
        self.lengthBadgeLabel.textColor = UIColor.systemRedColor;
        self.lengthBadgeLabel.text = YTKACELocalized(@"End time must be after start time");
        self.navigationItem.rightBarButtonItem.enabled = NO;
        self.submitButton.enabled = NO;
        self.submitButton.alpha = 0.5;
    }
}

- (void)setStartToNow {
    if ([self.actionType isEqualToString:@"full"]) {
        self.actionType = @"skip";
        self.actionSegmentedControl.selectedSegmentIndex = 0;
    }
    self.startTime = YTKACESponsorCurrentTime();
    AudioServicesPlaySystemSound(1519);
    [self updateTimeLabels];
}

- (void)setEndToNow {
    if ([self.actionType isEqualToString:@"full"]) {
        self.actionType = @"skip";
        self.actionSegmentedControl.selectedSegmentIndex = 0;
    }
    self.endTime = YTKACESponsorCurrentTime();
    AudioServicesPlaySystemSound(1519);
    [self updateTimeLabels];
}

- (void)seekToStart {
    YTKACESponsorSeek(self.startTime);
    YTKACEPlayYouTubePlayer();
}

- (void)seekToEnd {
    YTKACESponsorSeek(self.endTime);
    YTKACEPlayYouTubePlayer();
}

- (void)stepStart:(UIButton *)sender {
    if ([self.actionType isEqualToString:@"full"]) {
        self.actionType = @"skip";
        self.actionSegmentedControl.selectedSegmentIndex = 0;
    }
    double delta = (double)sender.tag / 10.0;
    self.startTime = MAX(0.0, self.startTime + delta);
    AudioServicesPlaySystemSound(1519);
    [self updateTimeLabels];
}

- (void)stepEnd:(UIButton *)sender {
    if ([self.actionType isEqualToString:@"full"]) {
        self.actionType = @"skip";
        self.actionSegmentedControl.selectedSegmentIndex = 0;
    }
    double delta = (double)sender.tag / 10.0;
    self.endTime = MAX(0.0, self.endTime + delta);
    AudioServicesPlaySystemSound(1519);
    [self updateTimeLabels];
}

static double YTKACEParseManualTimestamp(NSString *raw) {
    if (raw.length == 0) return -1.0;
    NSString *trimmed = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        stringByReplacingOccurrencesOfString:@"," withString:@"."];
    if (trimmed.length == 0) return -1.0;
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@":"];
    if (parts.count == 1) {
        NSScanner *sc = [NSScanner scannerWithString:parts[0]];
        double val = -1.0;
        if ([sc scanDouble:&val] && sc.isAtEnd && isfinite(val) && val >= 0.0) {
            return val;
        }
        return -1.0;
    } else if (parts.count == 2) {
        double m = [parts[0] doubleValue];
        double s = [parts[1] doubleValue];
        if (m >= 0.0 && s >= 0.0 && s < 60.0) {
            return m * 60.0 + s;
        }
    } else if (parts.count == 3) {
        double h = [parts[0] doubleValue];
        double m = [parts[1] doubleValue];
        double s = [parts[2] doubleValue];
        if (h >= 0.0 && m >= 0.0 && m < 60.0 && s >= 0.0 && s < 60.0) {
            return h * 3600.0 + m * 60.0 + s;
        }
    }
    return -1.0;
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
            double dur = strongSelf.videoDuration > 0.0 ? strongSelf.videoDuration : YTKACESponsorCurrentDuration();
            if (dur > 0.0 && parsed > dur) parsed = dur;
            if (isStart) {
                strongSelf.startTime = parsed;
            } else {
                strongSelf.endTime = parsed;
            }
            AudioServicesPlaySystemSound(1519);
            [strongSelf updateTimeLabels];
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
    if (self.endTime <= self.startTime) {
        YTKACEShowNotice(YTKACELocalized(@"End time must be after start time"));
        return;
    }
    double previewStart = MAX(0.0, self.startTime - 2.0);
    YTKACESetTestSkip(self.startTime, self.endTime);
    YTKACESponsorSeek(previewStart);
    YTKACEPlayYouTubePlayer();
    YTKACEShowNotice(YTKACELocalized(@"Previewing skip..."));
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

    self.submitButton.enabled = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self.spinner startAnimating];
    [self.submitButton setTitle:@"" forState:UIControlStateNormal];

    NSString *actionType = isPOI ? @"poi" : (self.actionType.length > 0 ? self.actionType : @"skip");
    double duration = self.videoDuration > 0.0 ? self.videoDuration : YTKACESponsorCurrentDuration();
    double submitStart = isFull ? 0.0 : self.startTime;
    double submitEnd = isFull ? 0.0 : self.endTime;

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
            YTKACESponsorRefreshCurrentVideo();

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
    [YTKACESponsorSubmitCoordinator.sharedCoordinator dismissDraftBanner];
    if (presenter == nil) {
        presenter = YTKACEFindTopController();
    }
    if (presenter == nil) return;

    YTKACESponsorSubmitController *controller = [YTKACESponsorSubmitController new];
    controller.videoID = videoID.length > 0 ? videoID : YTKACESponsorCurrentVideoID();
    controller.videoTitle = YTKACESponsorCurrentVideoTitle();
    controller.videoDuration = YTKACESponsorCurrentDuration();
    controller.startTime = startTime;
    controller.endTime = endTime >= startTime ? endTime : startTime;

    for (YTKACEVideoChapter *ch in YTKACESponsorCurrentChapters()) {
        if (fabs(ch.startTime - startTime) < 0.25 && fabs(ch.endTime - endTime) < 0.25) {
            controller.selectedCategory = ch.suggestedCategory;
            break;
        }
    }

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        nav.sheetPresentationController.detents = @[
            UISheetPresentationControllerDetent.largeDetent
        ];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
        nav.sheetPresentationController.prefersEdgeAttachedInCompactHeight = NO;
        nav.sheetPresentationController.widthFollowsPreferredContentSizeWhenEdgeAttached = YES;
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

void YTKACEInstallSponsorSubmitControls(void) {
    YTKACERegisterOverlayConfigurator(@"sponsorblock_submit", ^(UIView *overlay, UIStackView *stack) {
        YTKACESponsorSubmitCoordinator *coordinator = YTKACESponsorSubmitCoordinator.sharedCoordinator;
        coordinator.overlay = overlay;

        UIButton *button = YTKACEOverlayButton(
            stack,
            @"YTKACE SponsorBlock Submit",
            @"play.shield",
            coordinator,
            @selector(handleButtonTap)
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
