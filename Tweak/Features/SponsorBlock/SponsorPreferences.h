#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const YTKACESponsorUserIDKey;
FOUNDATION_EXPORT NSString * const YTKACESponsorSubmitButtonKey;
FOUNDATION_EXPORT NSString * const YTKACESponsorTimeSavedKey;
FOUNDATION_EXPORT NSString * const YTKACESponsorSkipCountKey;
FOUNDATION_EXPORT NSString * const YTKACESponsorChannelWhitelistKey;
FOUNDATION_EXPORT NSString * const YTKACESponsorShowTimeWithSkipsKey;
FOUNDATION_EXPORT BOOL YTKACESponsorShowTimeWithSkipsEnabled(void);
FOUNDATION_EXPORT NSString * const YTKACESponsorFullVideoLabelsKey;
FOUNDATION_EXPORT BOOL YTKACESponsorFullVideoLabelsEnabled(void);
FOUNDATION_EXPORT double YTKACESponsorCalculateSkippedDuration(NSArray<NSDictionary *> * _Nullable segments, double duration);

FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *YTKACESponsorCategoryDefinitions(void);
FOUNDATION_EXPORT NSString *YTKACESponsorCategoryTitle(NSString *category);
FOUNDATION_EXPORT NSString *YTKACESponsorCategoryDescription(NSString *category);
FOUNDATION_EXPORT NSString *YTKACESponsorBehaviorKey(NSString *category);
FOUNDATION_EXPORT NSString *YTKACESponsorColorKey(NSString *category);
FOUNDATION_EXPORT NSInteger YTKACESponsorCategoryBehavior(NSString *category);
FOUNDATION_EXPORT NSArray<NSString *> *YTKACESponsorEnabledCategories(void);
FOUNDATION_EXPORT UIColor *YTKACESponsorCategoryColor(NSString *category);
FOUNDATION_EXPORT NSInteger YTKACESponsorNotificationMode(void);
FOUNDATION_EXPORT NSTimeInterval YTKACESponsorSkipAlertDuration(void);
FOUNDATION_EXPORT NSTimeInterval YTKACESponsorUnskipAlertDuration(void);
FOUNDATION_EXPORT NSString *YTKACESponsorUserID(void);
FOUNDATION_EXPORT void YTKACESetSponsorUserID(NSString * _Nullable userID);
FOUNDATION_EXPORT NSString *YTKACEResetSponsorUserID(void);
FOUNDATION_EXPORT NSString * _Nullable YTKACESponsorComputePublicUserID(NSString * _Nullable userID);
FOUNDATION_EXPORT NSString * _Nullable YTKACESponsorPublicUserID(void);
FOUNDATION_EXPORT BOOL YTKACESponsorSubmitButtonEnabled(void);
FOUNDATION_EXPORT NSString * _Nullable YTKACEExtractUserIDFromInput(NSString * _Nullable rawInput);
FOUNDATION_EXPORT BOOL YTKACESponsorImportConfig(NSString * _Nullable rawInput, NSString * _Nullable * _Nullable outSummary);
FOUNDATION_EXPORT NSString *YTKACESponsorExportJSON(void);

FOUNDATION_EXPORT double YTKACESponsorTotalTimeSaved(void);
FOUNDATION_EXPORT NSInteger YTKACESponsorTotalSkipsCount(void);
FOUNDATION_EXPORT void YTKACESponsorAddSkippedTime(double seconds);
FOUNDATION_EXPORT void YTKACESponsorUndoSkippedTime(double seconds);
FOUNDATION_EXPORT NSString *YTKACESponsorFormattedTimeSaved(void);

FOUNDATION_EXPORT NSString * const YTKACESponsorOthersTimeSavedKey;
FOUNDATION_EXPORT NSString * const YTKACESponsorOthersSkipsCountKey;
FOUNDATION_EXPORT NSString * const YTKACESponsorSubmissionsCountKey;
FOUNDATION_EXPORT NSString * const YTKACESponsorUserNameKey;

FOUNDATION_EXPORT double YTKACESponsorOthersTimeSaved(void);
FOUNDATION_EXPORT NSInteger YTKACESponsorOthersSkipsCount(void);
FOUNDATION_EXPORT NSInteger YTKACESponsorSubmissionsCount(void);
FOUNDATION_EXPORT NSString * _Nullable YTKACESponsorUserName(void);
FOUNDATION_EXPORT NSString *YTKACESponsorFormattedOthersTimeSaved(void);
FOUNDATION_EXPORT void YTKACESponsorSetOthersStats(double minutesSaved, NSInteger skips, NSInteger submissions);
FOUNDATION_EXPORT void YTKACESponsorFetchUserInfo(void (^ _Nullable completion)(BOOL success, double othersTimeSaved, NSInteger othersSkips, NSInteger submissions));

FOUNDATION_EXPORT NSArray<NSString *> *YTKACESponsorWhitelistedChannels(void);
FOUNDATION_EXPORT BOOL YTKACESponsorIsChannelWhitelisted(NSString * _Nullable channel);
FOUNDATION_EXPORT void YTKACESponsorSetChannelWhitelisted(NSString *channel, BOOL whitelisted);
FOUNDATION_EXPORT void YTKACESponsorClearWhitelistedChannels(void);

NS_ASSUME_NONNULL_END
