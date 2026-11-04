#import <Foundation/Foundation.h>

FOUNDATION_EXPORT BOOL YTKACEIsPostImageURL(NSURL *URL);
FOUNDATION_EXPORT NSURL *YTKACEPostOriginalImageURL(NSURL *URL);
FOUNDATION_EXPORT NSArray<NSURL *> *YTKACEUniquePostImageURLs(NSArray<NSURL *> *URLs);
// Only used inside the current post's image attachment/carousel, never the feed.
FOUNDATION_EXPORT NSArray<NSURL *> *YTKACEPostImageURLsInProto(NSString *proto);
FOUNDATION_EXPORT NSString *YTKACEPostIDInText(NSString *text);
// RenderNext cells are built from a serialized element holding the whole post,
// including carousel images that have no view yet.
FOUNDATION_EXPORT BOOL YTKACEElementDataHasPostImage(NSData *data);
FOUNDATION_EXPORT NSArray<NSURL *> *YTKACEPostImageURLsInElementData(NSData *data);
FOUNDATION_EXPORT NSString *YTKACEPostIDInElementData(NSData *data);
// Finds the serialized elements that name an image, whatever size the URL asks for.
FOUNDATION_EXPORT NSArray<NSData *> *YTKACEElementDataMentioningImage(NSArray<NSData *> *candidates, NSURL *image);
FOUNDATION_EXPORT NSArray<NSURL *> *YTKACEPostImageURLsInPage(NSString *page, NSString *postID);
