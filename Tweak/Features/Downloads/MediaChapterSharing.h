#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *YTKACEChapterTextFromChapters(NSArray<NSDictionary *> *chapters);

// Completions run on the main queue. Empty text means no readable chapters.
FOUNDATION_EXPORT void YTKACEChapterTextForMediaURL(NSURL *URL,
    void (^completion)(NSString *text));
FOUNDATION_EXPORT void YTKACEPrepareMediaShareItems(NSArray<NSURL *> *URLs,
    UIViewController *presenter,
    void (^completion)(NSArray *items));

NS_ASSUME_NONNULL_END
