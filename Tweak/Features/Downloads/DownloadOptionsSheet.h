#import <UIKit/UIKit.h>
#import "StreamResolver.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YTKACEDownloadDestination) {
    YTKACEDownloadDestinationDownloads = 0,
    YTKACEDownloadDestinationPhotos = 1,
    YTKACEDownloadDestinationShare = 2
};

typedef void (^YTKACEDownloadOptionsCompletion)(
    YTKACEStreamOption * _Nullable selectedVideo,
    YTKACEStreamOption * _Nullable selectedAudio,
    NSDictionary * _Nullable selectedCaption,
    YTKACEDownloadDestination destination,
    NSArray<NSDictionary *> *removedSegments,
    BOOL isAudioOnly
);

@interface YTKACEDownloadOptionsController : UIViewController

@property(nonatomic, copy) NSString *videoTitle;
@property(nonatomic, copy) NSArray<YTKACEStreamOption *> *videoOptions;
@property(nonatomic, copy) NSArray<YTKACEStreamOption *> *audioOptions;
@property(nonatomic, copy) NSArray<NSDictionary *> *captionChoices;
@property(nonatomic, copy) NSArray<NSDictionary *> *sponsorSegments;
@property(nonatomic, assign) BOOL isAudioOnly;
@property(nonatomic, copy) YTKACEDownloadOptionsCompletion completion;

- (instancetype)initWithTitle:(NSString *)title
                 videoOptions:(NSArray<YTKACEStreamOption *> *)videoOptions
                 audioOptions:(NSArray<YTKACEStreamOption *> *)audioOptions
               captionChoices:(NSArray<NSDictionary *> *)captionChoices
              sponsorSegments:(NSArray<NSDictionary *> *)sponsorSegments
                    audioOnly:(BOOL)audioOnly
                   completion:(YTKACEDownloadOptionsCompletion)completion;

- (void)updateVideoOptions:(NSArray<YTKACEStreamOption *> *)videoOptions
              audioOptions:(NSArray<YTKACEStreamOption *> *)audioOptions;
- (void)updateCaptionChoices:(NSArray<NSDictionary *> *)choices;
- (void)updateSponsorSegments:(NSArray<NSDictionary *> *)segments;

@end

NS_ASSUME_NONNULL_END
