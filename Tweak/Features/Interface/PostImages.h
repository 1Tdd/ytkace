#import <Foundation/Foundation.h>

FOUNDATION_EXPORT BOOL YTKACEIsPostImageURL(NSURL *URL);
FOUNDATION_EXPORT NSURL *YTKACEPostOriginalImageURL(NSURL *URL);
FOUNDATION_EXPORT NSArray<NSURL *> *YTKACEUniquePostImageURLs(NSArray<NSURL *> *URLs);
// Only used inside the current post's image attachment/carousel, never the feed.
FOUNDATION_EXPORT NSArray<NSURL *> *YTKACEPostImageURLsInProto(NSString *proto);
FOUNDATION_EXPORT NSString *YTKACEPostIDInText(NSString *text);
FOUNDATION_EXPORT NSArray<NSURL *> *YTKACEPostImageURLsInPage(NSString *page, NSString *postID);
