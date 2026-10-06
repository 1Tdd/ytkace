#import "DownloadOptionsSheet.h"
#import "../SponsorBlock/SponsorPreferences.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../YTKACE.h"
#import <UIKit/UIKit.h>

static BOOL YTKACEDownloadSheetGlassEnabled(void) {
    return YTKACELiquidGlassAvailable() && YTKACEFeatureEnabled(@"YTKACE.Preference.Glass.Menus");
}

static NSString *YTKACEFormatDuration(double seconds) {
    if (seconds < 0) seconds = 0;
    NSInteger totalSec = (NSInteger)round(seconds);
    NSInteger h = totalSec / 3600;
    NSInteger m = (totalSec % 3600) / 60;
    NSInteger s = totalSec % 60;
    if (h > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)m, (long)s];
}

static UIImage *YTKACERowIcon(NSString *symbol, CGFloat size) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:size
                                                           weight:UIImageSymbolWeightRegular];
        UIImage *img = [UIImage systemImageNamed:symbol withConfiguration:config];
        if (img) return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return [UIImage new];
}

@interface YTKACEDownloadOptionsController ()

@property(nonatomic, strong) UIView *backdropView;
@property(nonatomic, strong) UIView *sheetContainer;
@property(nonatomic, strong) UIView *grabberView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIView *cardView;
@property(nonatomic, strong) UIStackView *cardStackView;

// Rows
@property(nonatomic, strong) UIView *qualityRow;
@property(nonatomic, strong) UILabel *qualityDetailLabel;

@property(nonatomic, strong) UIView *audioRow;
@property(nonatomic, strong) UILabel *audioDetailLabel;

@property(nonatomic, strong) UIView *captionsRow;
@property(nonatomic, strong) UILabel *captionsDetailLabel;

@property(nonatomic, strong) UIView *segmentsHeaderRow;
@property(nonatomic, strong) UILabel *segmentsBadgeLabel;
@property(nonatomic, strong) UIImageView *segmentsChevronView;
@property(nonatomic, strong) UIStackView *segmentsContentView;
@property(nonatomic, assign) BOOL segmentsExpanded;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *selectedSegmentIndices;

@property(nonatomic, strong) UIView *destinationRow;
@property(nonatomic, strong) UILabel *destinationDetailLabel;

// Bottom Download Button
@property(nonatomic, strong) UIButton *downloadButton;
@property(nonatomic, strong) UILabel *downloadSizeLabel;

// Selections
@property(nonatomic, strong, nullable) YTKACEStreamOption *selectedVideo;
@property(nonatomic, strong, nullable) YTKACEStreamOption *selectedAudio;
@property(nonatomic, strong, nullable) NSDictionary *selectedCaption;
@property(nonatomic, assign) YTKACEDownloadDestination destination;
@property(nonatomic, assign) BOOL destinationManuallyChanged;

@end

static YTKACEDownloadDestination YTKACEDefaultDownloadDestination(BOOL audioOnly) {
    NSString *key = audioOnly ? @"YTKACE.Preference.Downloads.AudioSaveLocation"
                              : @"YTKACE.Preference.Downloads.SaveLocation";
    id val = YTKACEPreferenceObject(key);
    NSInteger mode = [val respondsToSelector:@selector(integerValue)] ? [val integerValue] : 0;
    switch (mode) {
        case 1:
            return YTKACEDownloadDestinationPhotos;
        case 3:
            return YTKACEDownloadDestinationShare;
        case 0:
        case 2:
        default:
            return YTKACEDownloadDestinationDownloads;
    }
}

@implementation YTKACEDownloadOptionsController

- (instancetype)initWithTitle:(NSString *)title
                 videoOptions:(NSArray<YTKACEStreamOption *> *)videoOptions
                 audioOptions:(NSArray<YTKACEStreamOption *> *)audioOptions
               captionChoices:(NSArray<NSDictionary *> *)captionChoices
              sponsorSegments:(NSArray<NSDictionary *> *)sponsorSegments
                    audioOnly:(BOOL)audioOnly
                   completion:(YTKACEDownloadOptionsCompletion)completion {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _videoTitle = [title copy] ?: @"";
        _videoOptions = [videoOptions copy] ?: @[];
        _audioOptions = [audioOptions copy] ?: @[];
        _captionChoices = [captionChoices copy] ?: @[];
        _sponsorSegments = [sponsorSegments copy] ?: @[];
        _isAudioOnly = audioOnly;
        _completion = [completion copy];
        _destination = YTKACEDefaultDownloadDestination(audioOnly);
        _destinationManuallyChanged = NO;

        // Default selections
        if (!_isAudioOnly && _videoOptions.count > 0) {
            _selectedVideo = _videoOptions.firstObject;
        }
        if (_audioOptions.count > 0) {
            for (YTKACEStreamOption *opt in _audioOptions) {
                if (opt.isDefaultAudio) {
                    _selectedAudio = opt;
                    break;
                }
            }
            if (!_selectedAudio) {
                _selectedAudio = _audioOptions.firstObject;
            }
        }

        // Subtitles: Pre-select subtitle if enabled in settings
        if (YTKACEFeatureEnabled(@"YTKACE.Preference.Downloads.Subtitles") && _captionChoices.count > 0) {
            NSString *deviceLang = [NSLocale.preferredLanguages.firstObject componentsSeparatedByString:@"-"].firstObject.lowercaseString;
            for (NSDictionary *choice in _captionChoices) {
                NSString *lang = [choice[@"language"] lowercaseString];
                if (deviceLang.length > 0 && [lang hasPrefix:deviceLang]) {
                    _selectedCaption = choice;
                    break;
                }
            }
            if (!_selectedCaption) {
                _selectedCaption = _captionChoices.firstObject;
            }
        }

        // Segments to remove: filter out POI markers and pre-select auto-skip or sponsor categories
        NSMutableArray<NSDictionary *> *cuttable = [NSMutableArray array];
        for (NSDictionary *seg in _sponsorSegments) {
            if (![seg isKindOfClass:NSDictionary.class]) continue;
            NSString *cat = [seg[@"category"] isKindOfClass:NSString.class] ? seg[@"category"] : @"sponsor";
            NSString *act = [seg[@"actionType"] isKindOfClass:NSString.class] ? seg[@"actionType"] : @"skip";
            double s = [seg[@"start"] doubleValue];
            double e = [seg[@"end"] doubleValue];
            if ([cat isEqualToString:@"poi_highlight"] ||
                [act isEqualToString:@"poi"] ||
                [act isEqualToString:@"full"] ||
                e <= s) {
                continue;
            }
            [cuttable addObject:seg];
        }
        _sponsorSegments = [cuttable copy];
        _selectedSegmentIndices = [NSMutableSet set];
        for (NSUInteger i = 0; i < _sponsorSegments.count; i++) {
            NSDictionary *seg = _sponsorSegments[i];
            NSString *category = seg[@"category"];
            if ([category isKindOfClass:NSString.class]) {
                NSInteger behavior = YTKACESponsorCategoryBehavior(category);
                if (behavior == 0 || [category isEqualToString:@"sponsor"]) {
                    [_selectedSegmentIndices addObject:@(i)];
                }
            }
        }

        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    [self setupBackdrop];
    [self setupSheetContainer];
    [self setupGrabberAndTitle];
    [self setupCard];
    [self setupDownloadButton];
    [self updateUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.isBeingPresented) {
        self.backdropView.alpha = 0.0;
        self.sheetContainer.transform = CGAffineTransformMakeTranslation(0, 600);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.backdropView.alpha = 1.0;
        self.sheetContainer.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)setupBackdrop {
    self.backdropView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.backdropView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backdropView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:YTKACEDownloadSheetGlassEnabled() ? 0.40 : 0.60];
    [self.view addSubview:self.backdropView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleBackdropTap)];
    [self.backdropView addGestureRecognizer:tap];
}

- (void)setupSheetContainer {
    self.sheetContainer = [UIView new];
    self.sheetContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sheetContainer.layer.cornerRadius = 24.0;
    self.sheetContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.sheetContainer.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.sheetContainer.layer.masksToBounds = YES;

    if (YTKACEDownloadSheetGlassEnabled()) {
        self.sheetContainer.backgroundColor = UIColor.clearColor;
        YTKACEApplyMenuGlassBackground(self.sheetContainer, 24.0);
    } else {
        self.sheetContainer.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.13 alpha:1.0];
    }

    [self.view addSubview:self.sheetContainer];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.sheetContainer addGestureRecognizer:pan];

    NSLayoutConstraint *widthConstraint = [self.sheetContainer.widthAnchor constraintEqualToAnchor:self.view.widthAnchor];
    widthConstraint.priority = 750;
    CGFloat maxWidth = 460.0;
    [NSLayoutConstraint activateConstraints:@[
        [self.sheetContainer.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor],
        [self.sheetContainer.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor],
        [self.sheetContainer.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        widthConstraint,
        [self.sheetContainer.widthAnchor constraintLessThanOrEqualToConstant:maxWidth],
        [self.sheetContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.sheetContainer.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:40.0]
    ]];
}

- (void)setupGrabberAndTitle {
    self.grabberView = [UIView new];
    self.grabberView.translatesAutoresizingMaskIntoConstraints = NO;
    self.grabberView.backgroundColor = [UIColor colorWithWhite:0.4 alpha:1.0];
    self.grabberView.layer.cornerRadius = 2.5;
    [self.sheetContainer addSubview:self.grabberView];

    self.titleLabel = [UILabel new];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = self.videoTitle;
    self.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    self.titleLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.sheetContainer addSubview:self.titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.grabberView.topAnchor constraintEqualToAnchor:self.sheetContainer.topAnchor constant:10.0],
        [self.grabberView.centerXAnchor constraintEqualToAnchor:self.sheetContainer.centerXAnchor],
        [self.grabberView.widthAnchor constraintEqualToConstant:38.0],
        [self.grabberView.heightAnchor constraintEqualToConstant:5.0],

        [self.titleLabel.topAnchor constraintEqualToAnchor:self.grabberView.bottomAnchor constant:12.0],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.sheetContainer.leadingAnchor constant:20.0],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.sheetContainer.trailingAnchor constant:-20.0]
    ]];
}

- (void)setupCard {
    self.scrollView = [UIScrollView new];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.sheetContainer addSubview:self.scrollView];

    self.cardView = [UIView new];
    self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardView.layer.cornerRadius = 16.0;
    self.cardView.layer.cornerCurve = kCACornerCurveContinuous;
    self.cardView.layer.masksToBounds = YES;

    if (YTKACEDownloadSheetGlassEnabled()) {
        self.cardView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        self.cardView.layer.borderWidth = 0.5;
        self.cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    } else {
        self.cardView.backgroundColor = [UIColor colorWithRed:0.16 green:0.16 blue:0.17 alpha:1.0];
        self.cardView.layer.borderWidth = 0.0;
    }

    [self.scrollView addSubview:self.cardView];

    self.cardStackView = [UIStackView new];
    self.cardStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardStackView.axis = UILayoutConstraintAxisVertical;
    self.cardStackView.spacing = 0;
    [self.cardView addSubview:self.cardStackView];

    NSLayoutConstraint *scrollCardHeight = [self.scrollView.heightAnchor constraintEqualToAnchor:self.cardView.heightAnchor];
    scrollCardHeight.priority = 750;

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:14.0],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.sheetContainer.leadingAnchor constant:16.0],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.sheetContainer.trailingAnchor constant:-16.0],
        scrollCardHeight,
        [self.scrollView.heightAnchor constraintLessThanOrEqualToConstant:520.0],

        [self.cardView.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor],
        [self.cardView.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor],
        [self.cardView.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor],
        [self.cardView.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor],
        [self.cardView.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor],

        [self.cardStackView.topAnchor constraintEqualToAnchor:self.cardView.topAnchor],
        [self.cardStackView.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor],
        [self.cardStackView.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor],
        [self.cardStackView.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor]
    ]];

    [self buildCardRows];
}

- (UIView *)createSeparator {
    UIView *sep = [UIView new];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    if (YTKACEDownloadSheetGlassEnabled()) {
        sep.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    } else {
        sep.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.5];
    }
    [sep.heightAnchor constraintEqualToConstant:0.5].active = YES;
    return sep;
}

- (UIView *)createRowWithIcon:(NSString *)iconName
                        title:(NSString *)title
                  detailLabel:(UILabel **)outDetail
                       action:(SEL)action {
    UIView *row = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:52.0].active = YES;

    UIImageView *iconView = [UIImageView new];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    iconView.image = YTKACERowIcon(iconName, 18.0);
    [row addSubview:iconView];

    UILabel *titleLbl = [UILabel new];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    titleLbl.text = title;
    titleLbl.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    titleLbl.textColor = UIColor.whiteColor;
    [row addSubview:titleLbl];

    UILabel *detailLbl = [UILabel new];
    detailLbl.translatesAutoresizingMaskIntoConstraints = NO;
    detailLbl.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    detailLbl.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
    detailLbl.textAlignment = NSTextAlignmentRight;
    detailLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    [row addSubview:detailLbl];
    if (outDetail) *outDetail = detailLbl;

    UIImageView *chevronView = [UIImageView new];
    chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    chevronView.contentMode = UIViewContentModeScaleAspectFit;
    chevronView.tintColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    chevronView.image = YTKACERowIcon(@"chevron.down", 13.0);
    [row addSubview:chevronView];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16.0],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:24.0],
        [iconView.heightAnchor constraintEqualToConstant:24.0],

        [titleLbl.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14.0],
        [titleLbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [chevronView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16.0],
        [chevronView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevronView.widthAnchor constraintEqualToConstant:14.0],
        [chevronView.heightAnchor constraintEqualToConstant:14.0],

        [detailLbl.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-8.0],
        [detailLbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [detailLbl.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLbl.trailingAnchor constant:12.0]
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:action];
    [row addGestureRecognizer:tap];
    row.userInteractionEnabled = YES;

    return row;
}

- (void)buildCardRows {
    // 1. Quality
    UILabel *qDetail = nil;
    self.qualityRow = [self createRowWithIcon:@"play.rectangle"
                                        title:YTKACELocalized(@"Quality")
                                  detailLabel:&qDetail
                                       action:@selector(handleQualityTap)];
    self.qualityDetailLabel = qDetail;
    [self.cardStackView addArrangedSubview:self.qualityRow];
    [self.cardStackView addArrangedSubview:[self createSeparator]];

    // 2. Audio track
    UILabel *aDetail = nil;
    self.audioRow = [self createRowWithIcon:@"waveform"
                                      title:YTKACELocalized(@"Audio track")
                                detailLabel:&aDetail
                                     action:@selector(handleAudioTap)];
    self.audioDetailLabel = aDetail;
    [self.cardStackView addArrangedSubview:self.audioRow];
    [self.cardStackView addArrangedSubview:[self createSeparator]];

    // 3. Captions
    UILabel *cDetail = nil;
    self.captionsRow = [self createRowWithIcon:@"captions.bubble"
                                         title:YTKACELocalized(@"Captions")
                                   detailLabel:&cDetail
                                        action:@selector(handleCaptionsTap)];
    self.captionsDetailLabel = cDetail;
    [self.cardStackView addArrangedSubview:self.captionsRow];
    [self.cardStackView addArrangedSubview:[self createSeparator]];

    // 4. Remove segments (Expandable)
    if (YTKACESponsorBlockEnabled()) {
        [self buildSegmentsRow];
    }

    // 5. Save in...
    UILabel *dDetail = nil;
    self.destinationRow = [self createRowWithIcon:@"square.and.arrow.down"
                                            title:YTKACELocalized(@"Save in...")
                                      detailLabel:&dDetail
                                           action:@selector(handleDestinationTap)];
    self.destinationDetailLabel = dDetail;
    [self.cardStackView addArrangedSubview:self.destinationRow];
}

- (void)buildSegmentsRow {
    self.segmentsHeaderRow = [UIView new];
    self.segmentsHeaderRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.segmentsHeaderRow.heightAnchor constraintEqualToConstant:52.0].active = YES;

    UIImageView *iconView = [UIImageView new];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    iconView.image = YTKACERowIcon(@"shield", 18.0);
    [self.segmentsHeaderRow addSubview:iconView];

    UILabel *titleLbl = [UILabel new];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    titleLbl.text = YTKACELocalized(@"Remove segments");
    titleLbl.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    titleLbl.textColor = UIColor.whiteColor;
    [self.segmentsHeaderRow addSubview:titleLbl];

    self.segmentsBadgeLabel = [UILabel new];
    self.segmentsBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.segmentsBadgeLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    self.segmentsBadgeLabel.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
    self.segmentsBadgeLabel.textAlignment = NSTextAlignmentRight;
    [self.segmentsHeaderRow addSubview:self.segmentsBadgeLabel];

    self.segmentsChevronView = [UIImageView new];
    self.segmentsChevronView.translatesAutoresizingMaskIntoConstraints = NO;
    self.segmentsChevronView.contentMode = UIViewContentModeScaleAspectFit;
    self.segmentsChevronView.tintColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    self.segmentsChevronView.image = YTKACERowIcon(@"chevron.down", 13.0);
    [self.segmentsHeaderRow addSubview:self.segmentsChevronView];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:self.segmentsHeaderRow.leadingAnchor constant:16.0],
        [iconView.centerYAnchor constraintEqualToAnchor:self.segmentsHeaderRow.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:24.0],
        [iconView.heightAnchor constraintEqualToConstant:24.0],

        [titleLbl.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14.0],
        [titleLbl.centerYAnchor constraintEqualToAnchor:self.segmentsHeaderRow.centerYAnchor],

        [self.segmentsChevronView.trailingAnchor constraintEqualToAnchor:self.segmentsHeaderRow.trailingAnchor constant:-16.0],
        [self.segmentsChevronView.centerYAnchor constraintEqualToAnchor:self.segmentsHeaderRow.centerYAnchor],
        [self.segmentsChevronView.widthAnchor constraintEqualToConstant:14.0],
        [self.segmentsChevronView.heightAnchor constraintEqualToConstant:14.0],

        [self.segmentsBadgeLabel.trailingAnchor constraintEqualToAnchor:self.segmentsChevronView.leadingAnchor constant:-8.0],
        [self.segmentsBadgeLabel.centerYAnchor constraintEqualToAnchor:self.segmentsHeaderRow.centerYAnchor]
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleSegmentsExpanded)];
    [self.segmentsHeaderRow addGestureRecognizer:tap];
    self.segmentsHeaderRow.userInteractionEnabled = YES;

    [self.cardStackView addArrangedSubview:self.segmentsHeaderRow];

    // Segments content list
    self.segmentsContentView = [UIStackView new];
    self.segmentsContentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.segmentsContentView.axis = UILayoutConstraintAxisVertical;
    self.segmentsContentView.spacing = 0;
    self.segmentsContentView.hidden = YES;
    [self.cardStackView addArrangedSubview:self.segmentsContentView];

    [self rebuildSegmentItems];

    [self.cardStackView addArrangedSubview:[self createSeparator]];
}

- (void)rebuildSegmentItems {
    for (UIView *view in self.segmentsContentView.arrangedSubviews) {
        [self.segmentsContentView removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    if (self.sponsorSegments.count == 0) {
        UIView *emptyRow = [UIView new];
        emptyRow.translatesAutoresizingMaskIntoConstraints = NO;
        [emptyRow.heightAnchor constraintEqualToConstant:44.0].active = YES;

        UILabel *emptyLabel = [UILabel new];
        emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        emptyLabel.text = YTKACELocalized(@"No SponsorBlock segments found for this video");
        emptyLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        emptyLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
        [emptyRow addSubview:emptyLabel];

        [NSLayoutConstraint activateConstraints:@[
            [emptyLabel.leadingAnchor constraintEqualToAnchor:emptyRow.leadingAnchor constant:54.0],
            [emptyLabel.trailingAnchor constraintEqualToAnchor:emptyRow.trailingAnchor constant:-16.0],
            [emptyLabel.centerYAnchor constraintEqualToAnchor:emptyRow.centerYAnchor]
        ]];
        [self.segmentsContentView addArrangedSubview:emptyRow];
        return;
    }

    for (NSUInteger i = 0; i < self.sponsorSegments.count; i++) {
        NSDictionary *seg = self.sponsorSegments[i];
        NSString *category = seg[@"category"] ?: @"sponsor";
        double start = [seg[@"start"] doubleValue];
        double end = [seg[@"end"] doubleValue];

        UIView *itemRow = [UIView new];
        itemRow.translatesAutoresizingMaskIntoConstraints = NO;
        [itemRow.heightAnchor constraintEqualToConstant:50.0].active = YES;
        itemRow.tag = (NSInteger)i;

        UILabel *categoryLabel = [UILabel new];
        categoryLabel.translatesAutoresizingMaskIntoConstraints = NO;
        categoryLabel.text = YTKACESponsorCategoryTitle(category);
        categoryLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        categoryLabel.textColor = YTKACESponsorCategoryColor(category);
        [itemRow addSubview:categoryLabel];

        UILabel *timeLabel = [UILabel new];
        timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        timeLabel.text = [NSString stringWithFormat:@"%@ – %@",
            YTKACEFormatDuration(start), YTKACEFormatDuration(end)];
        timeLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        timeLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        [itemRow addSubview:timeLabel];

        UILabel *checkView = [UILabel new];
        checkView.translatesAutoresizingMaskIntoConstraints = NO;
        checkView.text = @"✓";
        checkView.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        checkView.textColor = [UIColor colorWithRed:0.75 green:0.52 blue:0.98 alpha:1.0];
        checkView.tag = 100;
        checkView.hidden = ![self.selectedSegmentIndices containsObject:@(i)];
        [itemRow addSubview:checkView];

        [NSLayoutConstraint activateConstraints:@[
            [categoryLabel.leadingAnchor constraintEqualToAnchor:itemRow.leadingAnchor constant:54.0],
            [categoryLabel.topAnchor constraintEqualToAnchor:itemRow.topAnchor constant:8.0],

            [timeLabel.leadingAnchor constraintEqualToAnchor:categoryLabel.leadingAnchor],
            [timeLabel.topAnchor constraintEqualToAnchor:categoryLabel.bottomAnchor constant:2.0],

            [checkView.trailingAnchor constraintEqualToAnchor:itemRow.trailingAnchor constant:-20.0],
            [checkView.centerYAnchor constraintEqualToAnchor:itemRow.centerYAnchor]
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSegmentItemTap:)];
        [itemRow addGestureRecognizer:tap];
        itemRow.userInteractionEnabled = YES;

        [self.segmentsContentView addArrangedSubview:itemRow];
    }
}

- (void)setupDownloadButton {
    self.downloadButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadButton.layer.cornerRadius = 25.0;
    self.downloadButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.downloadButton.layer.masksToBounds = YES;

    if (YTKACEDownloadSheetGlassEnabled()) {
        self.downloadButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
        self.downloadButton.layer.borderWidth = 0.5;
        self.downloadButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
    } else {
        self.downloadButton.backgroundColor = [UIColor colorWithRed:0.22 green:0.22 blue:0.24 alpha:1.0];
        self.downloadButton.layer.borderWidth = 0.0;
    }
    [self.sheetContainer addSubview:self.downloadButton];

    UIImageView *iconView = [UIImageView new];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = UIColor.whiteColor;
    iconView.image = YTKACERowIcon(@"arrow.down", 18.0);
    iconView.userInteractionEnabled = NO;
    [self.downloadButton addSubview:iconView];

    UILabel *btnTitle = [UILabel new];
    btnTitle.translatesAutoresizingMaskIntoConstraints = NO;
    btnTitle.text = YTKACELocalized(@"Download");
    btnTitle.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    btnTitle.textColor = UIColor.whiteColor;
    btnTitle.userInteractionEnabled = NO;
    [self.downloadButton addSubview:btnTitle];

    self.downloadSizeLabel = [UILabel new];
    self.downloadSizeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadSizeLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    self.downloadSizeLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    self.downloadSizeLabel.textAlignment = NSTextAlignmentRight;
    self.downloadSizeLabel.userInteractionEnabled = NO;
    [self.downloadButton addSubview:self.downloadSizeLabel];

    [self.downloadButton addTarget:self action:@selector(handleDownloadTapped) forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [self.downloadButton.topAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor constant:14.0],
        [self.downloadButton.leadingAnchor constraintEqualToAnchor:self.sheetContainer.leadingAnchor constant:16.0],
        [self.downloadButton.trailingAnchor constraintEqualToAnchor:self.sheetContainer.trailingAnchor constant:-16.0],
        [self.downloadButton.bottomAnchor constraintEqualToAnchor:self.sheetContainer.safeAreaLayoutGuide.bottomAnchor constant:-14.0],
        [self.downloadButton.heightAnchor constraintEqualToConstant:50.0],

        [iconView.leadingAnchor constraintEqualToAnchor:self.downloadButton.leadingAnchor constant:20.0],
        [iconView.centerYAnchor constraintEqualToAnchor:self.downloadButton.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:20.0],
        [iconView.heightAnchor constraintEqualToConstant:20.0],

        [btnTitle.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12.0],
        [btnTitle.centerYAnchor constraintEqualToAnchor:self.downloadButton.centerYAnchor],

        [self.downloadSizeLabel.trailingAnchor constraintEqualToAnchor:self.downloadButton.trailingAnchor constant:-20.0],
        [self.downloadSizeLabel.centerYAnchor constraintEqualToAnchor:self.downloadButton.centerYAnchor]
    ]];
}

#pragma mark - UI Updates

- (NSString *)sizeTextForBytes:(int64_t)bytes {
    if (bytes <= 0) return @"";
    return [NSByteCountFormatter stringFromByteCount:bytes
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

- (int64_t)estimatedTotalBytes {
    int64_t bytes = 0;
    if (!self.isAudioOnly && self.selectedVideo) {
        bytes += self.selectedVideo.contentLength;
    }
    if (self.selectedAudio) {
        bytes += self.selectedAudio.contentLength;
    }
    return bytes;
}

- (void)updateUI {
    // Quality
    if (self.isAudioOnly) {
        NSString *size = [self sizeTextForBytes:self.selectedAudio.contentLength];
        self.qualityDetailLabel.text = size.length > 0
            ? [NSString stringWithFormat:@"%@ · %@", YTKACELocalized(@"Audio only"), size]
            : YTKACELocalized(@"Audio only");
    } else if (self.selectedVideo) {
        NSString *size = [self sizeTextForBytes:self.selectedVideo.contentLength];
        NSString *quality = self.selectedVideo.qualityLabel.length != 0
            ? self.selectedVideo.qualityLabel : YTKACELocalized(@"Video");
        self.qualityDetailLabel.text = size.length > 0
            ? [NSString stringWithFormat:@"%@ · %@", quality, size] : quality;
    } else if (self.videoOptions.count > 0) {
        self.selectedVideo = self.videoOptions.firstObject;
        NSString *size = [self sizeTextForBytes:self.selectedVideo.contentLength];
        NSString *quality = self.selectedVideo.qualityLabel.length != 0
            ? self.selectedVideo.qualityLabel : YTKACELocalized(@"Video");
        self.qualityDetailLabel.text = size.length > 0
            ? [NSString stringWithFormat:@"%@ · %@", quality, size] : quality;
    } else {
        self.qualityDetailLabel.text = @"-";
    }

    // Audio
    if (self.selectedAudio == nil && self.audioOptions.count > 0) {
        self.selectedAudio = self.audioOptions.firstObject;
        for (YTKACEStreamOption *opt in self.audioOptions) {
            if (opt.isDefaultAudio) {
                self.selectedAudio = opt;
                break;
            }
        }
    }
    self.audioDetailLabel.text = self.selectedAudio.languageLabel ?: YTKACELocalized(@"Default");

    // Captions
    if (self.isAudioOnly) {
        self.captionsRow.alpha = 0.4;
        self.captionsDetailLabel.text = @"-";
    } else {
        self.captionsRow.alpha = 1.0;
        if (self.captionChoices.count == 0) {
            self.captionsDetailLabel.text = YTKACELocalized(@"None available");
        } else {
            self.captionsDetailLabel.text = self.selectedCaption
                ? self.selectedCaption[@"label"] : YTKACELocalized(@"Don't add captions");
        }
    }

    // Segments count badge
    if (self.sponsorSegments.count == 0) {
        self.segmentsBadgeLabel.text = @"0";
    } else {
        double cutDuration = 0.0;
        for (NSNumber *idx in self.selectedSegmentIndices) {
            NSUInteger i = idx.unsignedIntegerValue;
            if (i < self.sponsorSegments.count) {
                NSDictionary *seg = self.sponsorSegments[i];
                double s = [seg[@"start"] doubleValue];
                double e = [seg[@"end"] doubleValue];
                if (e > s) cutDuration += (e - s);
            }
        }
        if (cutDuration > 0.0) {
            self.segmentsBadgeLabel.text = [NSString stringWithFormat:@"%lu (-%@)",
                (unsigned long)self.selectedSegmentIndices.count,
                YTKACEFormatDuration(cutDuration)];
        } else {
            self.segmentsBadgeLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)self.selectedSegmentIndices.count];
        }
    }

    // Destination
    switch (self.destination) {
        case YTKACEDownloadDestinationPhotos:
            self.destinationDetailLabel.text = YTKACELocalized(@"Photos");
            break;
        case YTKACEDownloadDestinationShare:
            self.destinationDetailLabel.text = YTKACELocalized(@"Share Sheet");
            break;
        default:
            self.destinationDetailLabel.text = YTKACELocalized(@"YTKACE Library");
            break;
    }

    // Bottom size
    self.downloadSizeLabel.text = [self sizeTextForBytes:[self estimatedTotalBytes]];
}

- (void)updateVideoOptions:(NSArray<YTKACEStreamOption *> *)videoOptions
              audioOptions:(NSArray<YTKACEStreamOption *> *)audioOptions {
    if (videoOptions.count > 0) {
        self.videoOptions = [videoOptions copy];
        if (!self.isAudioOnly) {
            YTKACEStreamOption *matching = nil;
            for (YTKACEStreamOption *opt in self.videoOptions) {
                if (self.selectedVideo && (opt.itag == self.selectedVideo.itag ||
                    (opt.height == self.selectedVideo.height && [opt.qualityLabel isEqualToString:self.selectedVideo.qualityLabel]))) {
                    matching = opt;
                    break;
                }
            }
            self.selectedVideo = matching ?: self.videoOptions.firstObject;
        }
    }
    if (audioOptions.count > 0) {
        self.audioOptions = [audioOptions copy];
        YTKACEStreamOption *matching = nil;
        for (YTKACEStreamOption *opt in self.audioOptions) {
            if (self.selectedAudio && (opt.itag == self.selectedAudio.itag ||
                [opt.languageLabel isEqualToString:self.selectedAudio.languageLabel])) {
                matching = opt;
                break;
            }
        }
        if (matching != nil) {
            self.selectedAudio = matching;
        } else {
            self.selectedAudio = self.audioOptions.firstObject;
            for (YTKACEStreamOption *opt in self.audioOptions) {
                if (opt.isDefaultAudio) {
                    self.selectedAudio = opt;
                    break;
                }
            }
        }
    }
    [self updateUI];
}

- (void)updateSponsorSegments:(NSArray<NSDictionary *> *)segments {
    NSMutableArray<NSDictionary *> *cuttable = [NSMutableArray array];
    for (NSDictionary *seg in (segments ?: @[])) {
        if (![seg isKindOfClass:NSDictionary.class]) continue;
        NSString *cat = [seg[@"category"] isKindOfClass:NSString.class] ? seg[@"category"] : @"sponsor";
        NSString *act = [seg[@"actionType"] isKindOfClass:NSString.class] ? seg[@"actionType"] : @"skip";
        double s = [seg[@"start"] doubleValue];
        double e = [seg[@"end"] doubleValue];
        if ([cat isEqualToString:@"poi_highlight"] || [act isEqualToString:@"poi"] || e <= s) {
            continue;
        }
        [cuttable addObject:seg];
    }
    self.sponsorSegments = [cuttable copy];
    [self.selectedSegmentIndices removeAllObjects];
    for (NSUInteger i = 0; i < self.sponsorSegments.count; i++) {
        NSDictionary *seg = self.sponsorSegments[i];
        NSString *category = seg[@"category"];
        if ([category isKindOfClass:NSString.class]) {
            NSInteger behavior = YTKACESponsorCategoryBehavior(category);
            if (behavior == 0 || [category isEqualToString:@"sponsor"]) {
                [self.selectedSegmentIndices addObject:@(i)];
            }
        }
    }
    [self rebuildSegmentItems];
    [self updateUI];
}

- (void)updateCaptionChoices:(NSArray<NSDictionary *> *)choices {
    if (choices.count == 0) return;
    self.captionChoices = [choices copy];
    if (self.selectedCaption == nil && YTKACEFeatureEnabled(@"YTKACE.Preference.Downloads.Subtitles")) {
        NSString *deviceLang = [NSLocale.preferredLanguages.firstObject componentsSeparatedByString:@"-"].firstObject.lowercaseString;
        for (NSDictionary *choice in self.captionChoices) {
            NSString *lang = [choice[@"language"] lowercaseString];
            if (deviceLang.length > 0 && [lang hasPrefix:deviceLang]) {
                self.selectedCaption = choice;
                break;
            }
        }
        if (!self.selectedCaption) {
            self.selectedCaption = self.captionChoices.firstObject;
        }
    }
    [self updateUI];
}

#pragma mark - Actions

- (void)toggleSegmentsExpanded {
    self.segmentsExpanded = !self.segmentsExpanded;
    self.segmentsChevronView.image = YTKACERowIcon(self.segmentsExpanded ? @"chevron.up" : @"chevron.down", 13.0);
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.segmentsContentView.hidden = !self.segmentsExpanded;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)handleSegmentItemTap:(UITapGestureRecognizer *)gesture {
    UIView *row = gesture.view;
    NSNumber *idx = @(row.tag);
    if ([self.selectedSegmentIndices containsObject:idx]) {
        [self.selectedSegmentIndices removeObject:idx];
    } else {
        [self.selectedSegmentIndices addObject:idx];
    }
    UIView *check = [row viewWithTag:100];
    if (check) {
        check.hidden = ![self.selectedSegmentIndices containsObject:idx];
    }
    [self updateUI];
}

- (void)handleQualityTap {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTKACELocalized(@"Quality")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak YTKACEDownloadOptionsController *weakSelf = self;
    for (YTKACEStreamOption *opt in self.videoOptions) {
        NSString *size = [self sizeTextForBytes:opt.contentLength];
        NSString *label = opt.qualityLabel.length != 0 ? opt.qualityLabel : YTKACELocalized(@"Video");
        NSString *title = size.length > 0
            ? [NSString stringWithFormat:@"%@ · %@", label, size]
            : label;
        if ([opt isEqual:self.selectedVideo] && !self.isAudioOnly) {
            title = [NSString stringWithFormat:@"✓ %@", title];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            weakSelf.selectedVideo = opt;
            weakSelf.isAudioOnly = NO;
            if (!weakSelf.destinationManuallyChanged) {
                weakSelf.destination = YTKACEDefaultDownloadDestination(NO);
            }
            [weakSelf updateUI];
        }]];
    }

    NSString *audioOnlyTitle = self.isAudioOnly ? [NSString stringWithFormat:@"✓ %@", YTKACELocalized(@"Audio only")] : YTKACELocalized(@"Audio only");
    [alert addAction:[UIAlertAction actionWithTitle:audioOnlyTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        weakSelf.selectedVideo = nil;
        weakSelf.isAudioOnly = YES;
        if (!weakSelf.destinationManuallyChanged) {
            weakSelf.destination = YTKACEDefaultDownloadDestination(YES);
        }
        [weakSelf updateUI];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentPickerAlert:alert fromView:self.qualityRow];
}

- (void)handleAudioTap {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTKACELocalized(@"Audio track")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak YTKACEDownloadOptionsController *weakSelf = self;
    for (YTKACEStreamOption *opt in self.audioOptions) {
        NSString *size = [self sizeTextForBytes:opt.contentLength];
        NSString *label = opt.languageLabel ?: YTKACELocalized(@"Default");
        NSString *title = size.length > 0
            ? [NSString stringWithFormat:@"%@ · %@", label, size] : label;
        if ([opt isEqual:self.selectedAudio]) {
            title = [NSString stringWithFormat:@"✓ %@", title];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            weakSelf.selectedAudio = opt;
            [weakSelf updateUI];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentPickerAlert:alert fromView:self.audioRow];
}

- (void)handleCaptionsTap {
    if (self.isAudioOnly) return;
    if (self.captionChoices.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTKACELocalized(@"Captions")
                                                                       message:YTKACELocalized(@"No subtitles or captions available for this video.")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"OK") style:UIAlertActionStyleCancel handler:nil]];
        [self presentPickerAlert:alert fromView:self.captionsRow];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTKACELocalized(@"Captions")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak YTKACEDownloadOptionsController *weakSelf = self;
    NSString *noneTitle = self.selectedCaption == nil ? [NSString stringWithFormat:@"✓ %@", YTKACELocalized(@"Don't add captions")] : YTKACELocalized(@"Don't add captions");
    [alert addAction:[UIAlertAction actionWithTitle:noneTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        weakSelf.selectedCaption = nil;
        [weakSelf updateUI];
    }]];

    for (NSDictionary *choice in self.captionChoices) {
        NSString *label = choice[@"label"] ?: @"Subtitle";
        NSString *title = [choice isEqual:self.selectedCaption] ? [NSString stringWithFormat:@"✓ %@", label] : label;
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            weakSelf.selectedCaption = choice;
            [weakSelf updateUI];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentPickerAlert:alert fromView:self.captionsRow];
}

- (void)handleDestinationTap {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTKACELocalized(@"Save in...")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak YTKACEDownloadOptionsController *weakSelf = self;
    NSString *dTitle = self.destination == YTKACEDownloadDestinationDownloads ? [NSString stringWithFormat:@"✓ %@", YTKACELocalized(@"YTKACE Library")] : YTKACELocalized(@"YTKACE Library");
    [alert addAction:[UIAlertAction actionWithTitle:dTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        weakSelf.destinationManuallyChanged = YES;
        weakSelf.destination = YTKACEDownloadDestinationDownloads;
        [weakSelf updateUI];
    }]];
    NSString *pTitle = self.destination == YTKACEDownloadDestinationPhotos ? [NSString stringWithFormat:@"✓ %@", YTKACELocalized(@"Photos")] : YTKACELocalized(@"Photos");
    [alert addAction:[UIAlertAction actionWithTitle:pTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        weakSelf.destinationManuallyChanged = YES;
        weakSelf.destination = YTKACEDownloadDestinationPhotos;
        [weakSelf updateUI];
    }]];
    NSString *sTitle = self.destination == YTKACEDownloadDestinationShare ? [NSString stringWithFormat:@"✓ %@", YTKACELocalized(@"Share Sheet")] : YTKACELocalized(@"Share Sheet");
    [alert addAction:[UIAlertAction actionWithTitle:sTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        weakSelf.destinationManuallyChanged = YES;
        weakSelf.destination = YTKACEDownloadDestinationShare;
        [weakSelf updateUI];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentPickerAlert:alert fromView:self.destinationRow];
}

- (void)presentPickerAlert:(UIAlertController *)alert fromView:(UIView *)sourceView {
    if (alert.popoverPresentationController != nil) {
        alert.popoverPresentationController.sourceView = sourceView;
        alert.popoverPresentationController.sourceRect = sourceView.bounds;
    }
    if (self.presentedViewController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:NO completion:^{
            [self presentViewController:alert animated:YES completion:nil];
        }];
        return;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleDownloadTapped {
    self.downloadButton.enabled = NO;

    NSMutableArray<NSDictionary *> *removed = [NSMutableArray array];
    for (NSNumber *idx in self.selectedSegmentIndices) {
        NSUInteger i = idx.unsignedIntegerValue;
        if (i < self.sponsorSegments.count) {
            [removed addObject:self.sponsorSegments[i]];
        }
    }

    BOOL isAudioOnly = self.isAudioOnly;
    YTKACEStreamOption *video = isAudioOnly ? nil : (self.selectedVideo ?: self.videoOptions.firstObject);
    YTKACEStreamOption *audio = self.selectedAudio ?: self.audioOptions.firstObject;
    if (audio == nil && self.audioOptions.count > 0) {
        for (YTKACEStreamOption *opt in self.audioOptions) {
            if (opt.isDefaultAudio) {
                audio = opt;
                break;
            }
        }
    }
    NSDictionary *caption = isAudioOnly ? nil : self.selectedCaption;
    YTKACEDownloadDestination dest = self.destination;
    YTKACEDownloadOptionsCompletion comp = self.completion;

    [self dismissWithCompletion:^{
        if (comp) {
            comp(video, audio, caption, dest, removed, isAudioOnly);
        }
    }];
}

- (void)handleBackdropTap {
    [self dismissWithCompletion:nil];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.view];
    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (translation.y > 0) {
            self.sheetContainer.transform = CGAffineTransformMakeTranslation(0, translation.y);
        }
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        CGPoint velocity = [gesture velocityInView:self.view];
        if (translation.y > 150 || velocity.y > 800) {
            [self dismissWithCompletion:nil];
        } else {
            [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                self.sheetContainer.transform = CGAffineTransformIdentity;
            } completion:nil];
        }
    }
}

- (void)dismissWithCompletion:(void (^ _Nullable)(void))completion {
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.backdropView.alpha = 0.0;
        self.sheetContainer.transform = CGAffineTransformMakeTranslation(0, self.sheetContainer.bounds.size.height + 60);
    } completion:^(BOOL finished) {
        (void)finished;
        [self dismissViewControllerAnimated:NO completion:completion];
    }];
}

@end
