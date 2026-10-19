#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTKACEFFmpegCompletion)(NSError * _Nullable error);
typedef void (^YTKACEFFmpegProgress)(double fraction);

FOUNDATION_EXPORT void YTKACEFFmpegCancelConversion(NSString *identifier);

@interface YTKACEFFmpegMuxer : NSObject
+ (void)convertMediaURL:(NSURL *)inputURL
              outputURL:(NSURL *)outputURL
             identifier:(NSString *)identifier
            videoPreset:(nullable NSString *)videoPreset
            audioFormat:(NSString *)audioFormat
           audioBitrate:(NSInteger)audioBitrate
               metadata:(nullable NSDictionary<NSString *, NSString *> *)metadata
               progress:(nullable YTKACEFFmpegProgress)progress
             completion:(YTKACEFFmpegCompletion)completion;
+ (void)remuxAudioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(YTKACEFFmpegCompletion)completion;
+ (void)remuxAudioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
      removedSegments:(nullable NSArray<NSDictionary *> *)removedSegments
           completion:(YTKACEFFmpegCompletion)completion;
+ (void)remuxAudioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
      removedSegments:(nullable NSArray<NSDictionary *> *)removedSegments
          appliedCuts:(nullable void (^)(NSArray<NSDictionary *> *cuts))handler
           completion:(YTKACEFFmpegCompletion)completion;
+ (void)remuxAudioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
      removedSegments:(nullable NSArray<NSDictionary *> *)removedSegments
             metadata:(nullable NSDictionary<NSString *, NSString *> *)metadata
          appliedCuts:(nullable void (^)(NSArray<NSDictionary *> *cuts))handler
           completion:(YTKACEFFmpegCompletion)completion;
+ (void)remuxVideoURL:(NSURL *)videoURL
             audioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(YTKACEFFmpegCompletion)completion;
+ (void)remuxVideoURL:(NSURL *)videoURL
             audioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
      removedSegments:(nullable NSArray<NSDictionary *> *)removedSegments
           completion:(YTKACEFFmpegCompletion)completion;
+ (void)remuxVideoURL:(NSURL *)videoURL
             audioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
      removedSegments:(nullable NSArray<NSDictionary *> *)removedSegments
          appliedCuts:(nullable void (^)(NSArray<NSDictionary *> *cuts))handler
           completion:(YTKACEFFmpegCompletion)completion;
+ (void)normalizeMediaURL:(NSURL *)mediaURL
                outputURL:(NSURL *)outputURL
               completion:(YTKACEFFmpegCompletion)completion;
+ (void)videoFromAudioURL:(NSURL *)audioURL
             artworkData:(nullable NSData *)artworkData
                outputURL:(NSURL *)outputURL
                 progress:(nullable YTKACEFFmpegProgress)progress
               completion:(YTKACEFFmpegCompletion)completion;
+ (void)muxSubtitlesIntoURL:(NSURL *)mediaURL
                       cues:(NSArray<NSDictionary *> *)cues
                   language:(nullable NSString *)language
                  outputURL:(NSURL *)outputURL
                 completion:(YTKACEFFmpegCompletion)completion;
+ (void)embedArtworkData:(NSData *)artworkData
                 mediaURL:(NSURL *)mediaURL
               completion:(YTKACEFFmpegCompletion)completion;
@end

NS_ASSUME_NONNULL_END
