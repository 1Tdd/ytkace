#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YTKACELogFilter) {
    YTKACELogFilterAll = 0,
    YTKACELogFilterDownloads,
    YTKACELogFilterPosts,
    YTKACELogFilterFeed,
    YTKACELogFilterInterface,
    YTKACELogFilterStartup,
    YTKACELogFilterErrors,
};

// The entries of `contents` in `filter` that hold every word of `query`, in their order.
// An empty string means nothing matched.
FOUNDATION_EXPORT NSString *YTKACEFilteredLog(NSString *contents, YTKACELogFilter filter,
                                              NSString * _Nullable query);

NS_ASSUME_NONNULL_END
