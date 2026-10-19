#import <UIKit/UIKit.h>
FOUNDATION_EXPORT UIViewController *YTKACEMediaPresenter(UIView *sourceView);

FOUNDATION_EXPORT void YTKACELoadImage(NSURL *URL, NSURL *fallbackURL,
    void (^completion)(NSData *data, NSError *error));
FOUNDATION_EXPORT void YTKACESavePhotoData(NSArray<NSData *> *images,
    void (^completion)(BOOL success, NSError *error));
FOUNDATION_EXPORT void YTKACEPreviewImage(NSData *data, UIViewController *presenter);
FOUNDATION_EXPORT void YTKACEShareTextFile(NSString *text, NSString *filename,
    UIViewController *presenter, UIView *sourceView);
