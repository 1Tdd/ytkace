#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSURL *YTKACEPostOriginalImageURL(NSURL *URL);
FOUNDATION_EXPORT NSArray<NSURL *> *YTKACEUniquePostImageURLs(NSArray<NSURL *> *URLs);
// Only used inside the current post's image attachment/carousel, never the feed.
FOUNDATION_EXPORT NSArray<NSURL *> *YTKACEPostImageURLsInProto(NSString *proto);
