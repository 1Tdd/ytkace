#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTKACEVideoChapter : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) double startTime;
@property (nonatomic, assign) double endTime;
@property (nonatomic, readonly) double duration;
@property (nonatomic, readonly) NSString *suggestedCategory;
@property (nonatomic, readonly) BOOL isLikelySponsor;
- (instancetype)initWithTitle:(NSString *)title startTime:(double)startTime endTime:(double)endTime;
@end

void YTKACEInstallSponsorBlockHooks(void);
NSString * _Nullable YTKACESponsorCurrentVideoID(void);
double YTKACESponsorCurrentTime(void);
double YTKACESponsorCurrentDuration(void);
NSString * _Nullable YTKACESponsorCurrentVideoTitle(void);
NSString * _Nullable YTKACESponsorCurrentVideoDescription(void);
NSString * _Nullable YTKACESponsorCurrentChannelTitle(void);
NSArray<NSDictionary<NSString *, id> *> *YTKACESponsorCurrentSegments(void);
NSArray<YTKACEVideoChapter *> *YTKACESponsorCurrentChapters(void);
void YTKACESponsorSeek(double time);
void YTKACEPlayYouTubePlayer(void);
void YTKACEPauseYouTubePlayer(void);
void YTKACESponsorRefreshCurrentVideo(void);
void YTKACESetTestSkip(double start, double end);
void YTKACESponsorUserDidManualSeek(void);

NS_ASSUME_NONNULL_END
