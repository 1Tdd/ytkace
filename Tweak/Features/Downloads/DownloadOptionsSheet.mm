#import "DownloadOptionsSheet.h"
#include "DownloadFormatPolicy.h"
#import "../SponsorBlock/SponsorPreferences.h"
#import "../SponsorBlock/SponsorTimeline.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../YTKACE.h"
#import <VideoToolbox/VideoToolbox.h>
#include <cmath>
#include <cstdint>
#include <cstdlib>

static YTKACEDownloadDestination YTKACEDefaultDestination(BOOL audioOnly) {
    NSString *key = audioOnly ? @"YTKACE.Preference.Downloads.AudioSaveLocation" : @"YTKACE.Preference.Downloads.SaveLocation";
    NSInteger value = [YTKACEPreferenceObject(key) integerValue];
    return value == 1 ? YTKACEDownloadDestinationPhotos : (value == 3 ? YTKACEDownloadDestinationShare : YTKACEDownloadDestinationDownloads);
}

@interface YTKACEDownloadOptionsController ()
@property(nonatomic, strong) YTKACEStreamOption *selectedVideo;
@property(nonatomic, strong) YTKACEStreamOption *selectedAudio;
@property(nonatomic, copy) NSDictionary *selectedCaption;
@property(nonatomic, copy) NSString *selectedCodec;
@property(nonatomic, assign) YTKACEDownloadDestination destination;
@property(nonatomic, assign) BOOL destinationManuallyChanged;
@property(nonatomic, assign) BOOL submitted;
@property(nonatomic, assign) BOOL captionManuallyChanged;
@property(nonatomic, strong) NSMutableSet<NSString *> *selectedSegments;
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *allSponsorSegments;
@end

@implementation YTKACEDownloadOptionsController
- (instancetype)initWithTitle:(NSString *)title videoOptions:(NSArray *)videoOptions
                 audioOptions:(NSArray *)audioOptions captionChoices:(NSArray *)captionChoices
              sponsorSegments:(NSArray *)sponsorSegments audioOnly:(BOOL)audioOnly
                   completion:(YTKACEDownloadOptionsCompletion)completion {
    self = [super init];
    if (self) {
        _videoTitle = [title copy] ?: @"";
        _metadata = @{@"title": _videoTitle, @"artist": @""};
        _videoOptions = [videoOptions copy] ?: @[];
        _audioOptions = [audioOptions copy] ?: @[];
        _captionChoices = [captionChoices copy] ?: @[];
        _sponsorSegments = @[];
        _isAudioOnly = audioOnly;
        _completion = [completion copy];
        _destination = YTKACEDefaultDestination(audioOnly);
        _selectedSegments = [NSMutableSet set];
        _selectedAudio = [self preferredAudioIn:_audioOptions matching:nil];
        _selectedVideo = _videoOptions.firstObject;
        _selectedCodec = _selectedVideo.codecIdentifier ?: @"avc1";
        [self updateSponsorSegments:sponsorSegments];
        [self chooseDefaultCaption];
    }
    return self;
}

- (void)viewDidLoad {
    [self rebuildForm];
    [super viewDidLoad];
}

- (void)chooseDefaultCaption {
    if (self.captionManuallyChanged || self.selectedCaption || !YTKACEFeatureEnabled(@"YTKACE.Preference.Downloads.Subtitles")) return;
    NSString *language = [NSLocale.preferredLanguages.firstObject componentsSeparatedByString:@"-"].firstObject.lowercaseString;
    for (NSDictionary *choice in self.captionChoices) {
        if (language.length && [choice[@"language"] hasPrefix:language]) {
            self.selectedCaption = choice;
            return;
        }
    }
    self.selectedCaption = self.captionChoices.firstObject;
}

- (YTKACEStreamOption *)preferredAudioIn:(NSArray<YTKACEStreamOption *> *)options matching:(YTKACEStreamOption *)previous {
    for (YTKACEStreamOption *option in options) if (previous && [option isEqual:previous]) return option;
    if (!previous) {
        for (YTKACEStreamOption *option in options) if (option.defaultAudio) { previous = option; break; }
        previous = previous ?: options.firstObject;
    }
    YTKACEStreamOption *best = nil;
    for (YTKACEStreamOption *option in options) {
        if (previous && ![option.audioTrackKey isEqual:previous.audioTrackKey]) continue;
        if (best == nil || option.bitrate > best.bitrate) best = option;
    }
    if (best) return best;
    for (YTKACEStreamOption *option in options) if (option.defaultAudio) return option;
    return options.firstObject;
}

- (int64_t)bytesForOption:(YTKACEStreamOption *)option {
    return YTKACEDownloadFormats::estimatedBytes(option.contentLength, option.bitrate, self.duration);
}

- (NSString *)sizeForVideo:(YTKACEStreamOption *)video audio:(YTKACEStreamOption *)audio {
    int64_t videoSize = [self bytesForOption:video], audioSize = [self bytesForOption:audio];
    if ((video && videoSize <= 0) || (audio && audioSize <= 0) || videoSize > INT64_MAX - audioSize) return @"";
    int64_t total = videoSize + audioSize;
    if (total <= 0) return @"";
    NSString *size = [NSByteCountFormatter stringFromByteCount:total countStyle:NSByteCountFormatterCountStyleFile];
    BOOL estimated = (video && video.contentLength <= 0) || (audio && audio.contentLength <= 0);
    return estimated ? [@"~" stringByAppendingString:size] : size;
}

- (NSString *)qualityTitle:(YTKACEStreamOption *)option {
    if (option.audioOnly) return [NSString stringWithFormat:@"%ld kbps", (long)MAX(1, lround(option.bitrate / 1000.0))];
    return option.qualityLabel.length ? option.qualityLabel : [NSString stringWithFormat:@"%ldp", (long)option.height];
}

- (NSString *)segmentKey:(NSDictionary *)segment {
    return [NSString stringWithFormat:@"%@|%@|%@", segment[@"category"] ?: @"sponsor", segment[@"start"], segment[@"end"]];
}

- (NSArray<NSString *> *)codecs {
    NSMutableArray *codecs = [NSMutableArray array];
    for (NSString *codec in @[@"avc1", @"av01", @"vp9", @"hevc"]) {
        if ([codec isEqual:@"av01"] && !VTIsHardwareDecodeSupported('av01')) continue;
        if ([codec isEqual:@"vp9"] && !VTIsHardwareDecodeSupported('vp09')) continue;
        for (YTKACEStreamOption *option in self.videoOptions) {
            if ([option.codecIdentifier isEqual:codec]) { [codecs addObject:codec]; break; }
        }
    }
    [codecs addObject:@"audio"];
    return codecs;
}

- (YTKACEMediaAction *)choice:(NSString *)identifier title:(NSString *)title selected:(BOOL)selected handler:(dispatch_block_t)handler {
    YTKACEMediaAction *action = [YTKACEMediaAction action:identifier title:title symbol:nil handler:handler];
    action.selected = selected;
    action.dismissesSheet = NO;
    return action;
}

- (void)rebuildForm {
    NSString *artist = self.metadata[@"artist"];
    NSString *title = self.metadata[@"title"] ?: self.videoTitle;
    self.heading = artist.length ? [NSString stringWithFormat:@"%@ — %@", artist, title] : title;
    __weak YTKACEDownloadOptionsController *weakSelf = self;
    NSMutableArray<YTKACEMediaAction *> *rows = [NSMutableArray array];
    NSArray *codecs = [self codecs];
    NSMutableArray *titles = [codecs mutableCopy];
    NSUInteger audioIndex = [titles indexOfObject:@"audio"];
    if (audioIndex != NSNotFound) titles[audioIndex] = YTKACELocalized(@"Audio only");
    UISegmentedControl *tabs = [[UISegmentedControl alloc] initWithItems:titles];
    tabs.selectedSegmentIndex = [codecs indexOfObject:self.isAudioOnly ? @"audio" : self.selectedCodec];
    [tabs addTarget:self action:@selector(codecChanged:) forControlEvents:UIControlEventValueChanged];
    tabs.accessibilityLabel = YTKACELocalized(@"Quality");
    YTKACEMediaAction *tabRow = [YTKACEMediaAction action:@"download.codec" title:@"" symbol:nil handler:nil];
    tabRow.customView = tabs;
    NSMutableArray *qualities = [NSMutableArray arrayWithObject:tabRow];
    NSArray *formats = self.isAudioOnly ? self.audioOptions : self.videoOptions;
    for (YTKACEStreamOption *option in formats) {
        if (self.isAudioOnly) {
            if (self.selectedAudio && ![option.audioTrackKey isEqual:self.selectedAudio.audioTrackKey]) continue;
        } else if (![option.codecIdentifier isEqual:self.selectedCodec]) continue;
        NSString *size = [self sizeForVideo:self.isAudioOnly ? nil : option audio:self.isAudioOnly ? option : self.selectedAudio];
        NSString *title = size.length ? [NSString stringWithFormat:@"%@ · %@", [self qualityTitle:option], size] : [self qualityTitle:option];
        YTKACEMediaAction *choice = [self choice:[NSString stringWithFormat:@"download.quality.%ld.%@", (long)option.itag, option.audioTrackKey]
            title:title selected:[option isEqual:self.isAudioOnly ? self.selectedAudio : self.selectedVideo] handler:^{
                if (weakSelf.isAudioOnly) weakSelf.selectedAudio = option;
                else weakSelf.selectedVideo = option;
                [weakSelf rebuildForm];
            }];
        [qualities addObject:choice];
    }
    YTKACEMediaAction *quality = [YTKACEMediaAction group:@"download.quality" title:YTKACELocalized(@"Quality")
        symbol:self.isAudioOnly ? @"music.note" : @"play.rectangle" children:qualities];
    YTKACEStreamOption *selected = self.isAudioOnly ? self.selectedAudio : self.selectedVideo;
    NSString *size = [self sizeForVideo:self.isAudioOnly ? nil : self.selectedVideo audio:self.selectedAudio];
    quality.detail = selected ? (size.length ? [NSString stringWithFormat:@"%@ · %@", [self qualityTitle:selected], size] : [self qualityTitle:selected]) : YTKACELocalized(@"None available");
    [rows addObject:quality];
    if (self.isAudioOnly) {
        YTKACEMediaAction *format = [YTKACEMediaAction action:@"download.format" title:YTKACELocalized(@"Format") symbol:@"music.note" handler:nil];
        format.detail = @"m4a";
        [rows addObject:format];
        YTKACEMediaAction *metadata = [YTKACEMediaAction action:@"download.metadata" title:YTKACELocalized(@"Edit metadata") symbol:@"square.and.pencil" handler:^{ [weakSelf editMetadata]; }];
        metadata.dismissesSheet = NO;
        [rows addObject:metadata];
    }
    NSMutableArray *tracks = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (YTKACEStreamOption *option in self.audioOptions) {
        if ([seen containsObject:option.audioTrackKey]) continue;
        [seen addObject:option.audioTrackKey];
        [tracks addObject:[self choice:[@"download.track." stringByAppendingString:option.audioTrackKey]
            title:option.languageLabel.length ? option.languageLabel : YTKACELocalized(@"Original audio")
            selected:[option.audioTrackKey isEqual:self.selectedAudio.audioTrackKey] handler:^{
                weakSelf.selectedAudio = [weakSelf preferredAudioIn:weakSelf.audioOptions matching:option];
                [weakSelf rebuildForm];
            }]];
    }
    YTKACEMediaAction *audio = [YTKACEMediaAction group:@"download.audio" title:YTKACELocalized(@"Audio track") symbol:@"person.wave.2" children:tracks];
    audio.detail = self.selectedAudio.languageLabel.length ? self.selectedAudio.languageLabel : YTKACELocalized(@"Original audio");
    audio.enabled = tracks.count > 0;
    [rows addObject:audio];
    if (!self.isAudioOnly) {
        NSMutableArray *captions = [NSMutableArray arrayWithObject:[self choice:@"download.caption.none"
            title:YTKACELocalized(@"Don't add captions") selected:self.selectedCaption == nil handler:^{
                weakSelf.captionManuallyChanged = YES; weakSelf.selectedCaption = nil; [weakSelf rebuildForm];
            }]];
        for (NSDictionary *caption in self.captionChoices) {
            [captions addObject:[self choice:[@"download.caption." stringByAppendingString:caption[@"language"] ?: @""]
                title:caption[@"label"] ?: @"" selected:[caption isEqual:self.selectedCaption] handler:^{
                    weakSelf.captionManuallyChanged = YES; weakSelf.selectedCaption = caption; [weakSelf rebuildForm];
                }]];
        }
        YTKACEMediaAction *caption = [YTKACEMediaAction group:@"download.captions" title:YTKACELocalized(@"Captions") symbol:@"captions.bubble" children:captions];
        caption.detail = self.selectedCaption[@"label"] ?: YTKACELocalized(@"Don't add captions");
        [rows addObject:caption];
    }
    if (YTKACESponsorBlockEnabled()) {
        NSMutableArray *segments = [NSMutableArray array];
        for (NSDictionary *segment in self.sponsorSegments) {
            NSString *key = [self segmentKey:segment];
            double start = [segment[@"start"] doubleValue], end = [segment[@"end"] doubleValue];
            NSString *title = [NSString stringWithFormat:@"%@ · %ld:%02ld – %ld:%02ld", YTKACESponsorCategoryTitle(segment[@"category"] ?: @"sponsor"),
                (long)start / 60, (long)start % 60, (long)end / 60, (long)end % 60];
            [segments addObject:[self choice:[@"download.segment." stringByAppendingString:key] title:title selected:[self.selectedSegments containsObject:key] handler:^{
                if ([weakSelf.selectedSegments containsObject:key]) [weakSelf.selectedSegments removeObject:key];
                else [weakSelf.selectedSegments addObject:key];
                [weakSelf rebuildForm];
            }]];
        }
        YTKACEMediaAction *segment = [YTKACEMediaAction group:@"download.segments" title:YTKACELocalized(@"Remove segments") symbol:@"shield" children:segments];
        segment.detail = self.selectedSegments.count ? [NSString stringWithFormat:@"%lu", (unsigned long)self.selectedSegments.count] : YTKACELocalized(@"None");
        segment.enabled = segments.count > 0;
        [rows addObject:segment];
    }
    NSArray *destinations = @[YTKACELocalized(@"Downloads"), YTKACELocalized(@"Photos"), YTKACELocalized(@"Share Sheet")];
    NSMutableArray *saves = [NSMutableArray array];
    for (NSUInteger i = 0; i < destinations.count; ++i) {
        [saves addObject:[self choice:[NSString stringWithFormat:@"download.destination.%lu", (unsigned long)i]
            title:destinations[i] selected:self.destination == (NSInteger)i handler:^{
                weakSelf.destination = (YTKACEDownloadDestination)i;
                weakSelf.destinationManuallyChanged = YES;
                [weakSelf rebuildForm];
            }]];
    }
    YTKACEMediaAction *destination = [YTKACEMediaAction group:@"download.destination" title:YTKACELocalized(@"Save in...") symbol:@"square.and.arrow.down" children:saves];
    destination.detail = destinations[self.destination];
    [rows addObject:destination];
    YTKACEMediaAction *download = [YTKACEMediaAction action:@"download.start" title:YTKACELocalized(@"Download") symbol:@"arrow.down.to.line" handler:^{ [weakSelf startDownload]; }];
    download.enabled = !self.submitted && self.selectedAudio != nil && (self.isAudioOnly || self.selectedVideo != nil);
    download.detail = size;
    download.dismissesSheet = NO;
    self.actionSections = @[rows, @[download]];
}

- (void)codecChanged:(UISegmentedControl *)control {
    NSArray *codecs = [self codecs];
    NSInteger index = control.selectedSegmentIndex;
    if (index < 0 || index >= (NSInteger)codecs.count) return;
    NSString *codec = codecs[index];
    self.isAudioOnly = [codec isEqual:@"audio"];
    if (!self.isAudioOnly) {
        self.selectedCodec = codec;
        NSInteger height = self.selectedVideo.height;
        YTKACEStreamOption *best = nil;
        for (YTKACEStreamOption *option in self.videoOptions) {
            if (![option.codecIdentifier isEqual:codec]) continue;
            if (!best || labs(option.height - height) < labs(best.height - height)) best = option;
        }
        self.selectedVideo = best;
    }
    if (!self.destinationManuallyChanged) self.destination = YTKACEDefaultDestination(self.isAudioOnly);
    [self rebuildForm];
}

- (void)editMetadata {
    UIAlertController *editor = [UIAlertController alertControllerWithTitle:YTKACELocalized(@"Edit metadata") message:nil preferredStyle:UIAlertControllerStyleAlert];
    NSArray *keys = @[@"title", @"artist"], *labels = @[YTKACELocalized(@"Title"), YTKACELocalized(@"Artist")];
    for (NSUInteger i = 0; i < keys.count; i++) {
        [editor addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = labels[i]; field.text = self.metadata[keys[i]];
            field.accessibilityLabel = labels[i]; field.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
    }
    [editor addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak YTKACEDownloadOptionsController *weakSelf = self;
    [editor addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Save") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *title = [editor.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *artist = [editor.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        weakSelf.metadata = @{@"title": title.length ? title : weakSelf.videoTitle, @"artist": artist ?: @""};
        [weakSelf rebuildForm];
    }]];
    [self presentViewController:editor animated:YES completion:nil];
}

- (void)updateVideoOptions:(NSArray *)videoOptions audioOptions:(NSArray *)audioOptions {
    if (audioOptions.count) {
        self.audioOptions = audioOptions;
        self.selectedAudio = [self preferredAudioIn:audioOptions matching:self.selectedAudio];
    }
    if (videoOptions.count) {
        self.videoOptions = videoOptions;
        YTKACEStreamOption *previous = self.selectedVideo, *matching = nil;
        for (YTKACEStreamOption *option in videoOptions) {
            if ([option isEqual:previous]) { matching = option; break; }
            if ([option.codecIdentifier isEqual:self.selectedCodec] &&
                (!matching || labs(option.height - previous.height) < labs(matching.height - previous.height))) matching = option;
        }
        self.selectedVideo = matching ?: videoOptions.firstObject;
        self.selectedCodec = self.selectedVideo.codecIdentifier;
    }
    if (self.isViewLoaded) [self rebuildForm];
}
- (void)updateCaptionChoices:(NSArray *)choices {
    self.captionChoices = choices ?: @[];
    [self chooseDefaultCaption];
    if (self.isViewLoaded) [self rebuildForm];
}
- (void)updateSponsorSegments:(NSArray *)segments {
    self.allSponsorSegments = [segments copy] ?: @[];
    NSMutableArray *valid = [NSMutableArray array];
    NSMutableSet *selection = [NSMutableSet set];
    for (NSDictionary *segment in segments) {
        YTKACEMedia::Interval range;
        if (!YTKACEReadSponsorInterval(segment, range) || ![(segment[@"actionType"] ?: @"skip") isEqual:@"skip"]) continue;
        [valid addObject:segment];
        NSString *key = [self segmentKey:segment];
        BOOL wasPresent = NO;
        for (NSDictionary *old in self.sponsorSegments) if ([[self segmentKey:old] isEqual:key]) { wasPresent = YES; break; }
        BOOL automatic = YTKACESponsorCategoryBehavior(segment[@"category"] ?: @"sponsor") == 0;
        if ([self.selectedSegments containsObject:key] || (!wasPresent && automatic)) [selection addObject:key];
    }
    self.sponsorSegments = valid;
    self.selectedSegments = selection;
    if (self.isViewLoaded) [self rebuildForm];
}
- (void)startDownload {
    if (self.submitted || !self.selectedAudio || (!self.isAudioOnly && !self.selectedVideo)) return;
    self.submitted = YES;
    NSMutableArray *removed = [NSMutableArray array];
    for (NSDictionary *segment in self.sponsorSegments) if ([self.selectedSegments containsObject:[self segmentKey:segment]]) [removed addObject:segment];
    YTKACEDownloadOptionsCompletion completion = self.completion;
    YTKACEStreamOption *video = self.isAudioOnly ? nil : self.selectedVideo, *audio = self.selectedAudio;
    NSDictionary *caption = self.isAudioOnly ? nil : self.selectedCaption;
    YTKACEDownloadDestination destination = self.destination;
    [self dismissViewControllerAnimated:YES completion:^{ if (completion) completion(video, audio, caption, destination, removed, self.isAudioOnly); }];
}
@end
