#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTKACESponsorCompletion)(
    NSArray<NSDictionary<NSString *, id> *> *segments
);

@interface YTKACESponsorClient : NSObject
+ (instancetype)sharedClient;
- (void)segmentsForVideoID:(NSString *)videoID
                completion:(YTKACESponsorCompletion)completion;
- (void)segmentsForVideoID:(NSString *)videoID
                categories:(NSArray<NSString *> *)categories
                completion:(YTKACESponsorCompletion)completion;
- (void)clearCache;
- (void)clearCacheForVideoID:(NSString *)videoID;
- (void)submitSegmentForVideoID:(NSString *)videoID
                          start:(double)start
                            end:(double)end
                       category:(NSString *)category
                     actionType:(nullable NSString *)actionType
                  videoDuration:(double)duration
                     completion:(nullable void (^)(BOOL success, NSString * _Nullable message))completion;
- (void)voteForSegmentUUID:(NSString *)uuid
                      type:(NSInteger)type
                completion:(nullable void (^)(BOOL success, NSString * _Nullable message))completion;
@end

NS_ASSUME_NONNULL_END
