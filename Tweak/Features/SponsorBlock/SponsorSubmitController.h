#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void YTKACEInstallSponsorSubmitControls(void);

void YTKACEPresentSponsorSubmitController(
    NSString * _Nullable videoID,
    double startTime,
    double endTime,
    UIViewController * _Nullable presenter
);

@interface YTKACESponsorSubmitController : UIViewController
@property (nonatomic, copy, nullable) NSString *videoID;
@property (nonatomic, copy, nullable) NSString *videoTitle;
@property (nonatomic, assign) double videoDuration;
@property (nonatomic, assign) double startTime;
@property (nonatomic, assign) double endTime;
@property (nonatomic, copy) NSString *selectedCategory;
@property (nonatomic, copy) NSString *actionType;
@property (nonatomic, copy, nullable) dispatch_block_t onDismiss;
@end

NS_ASSUME_NONNULL_END
