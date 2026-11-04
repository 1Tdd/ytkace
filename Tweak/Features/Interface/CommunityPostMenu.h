#import <UIKit/UIKit.h>
FOUNDATION_EXPORT void YTKACEPresentCommunityPostMenu(UIView *postView, id node, NSString *text, NSURL *currentImage);
FOUNDATION_EXPORT void YTKACEPresentPostImageMenu(NSURL *imageURL, UIView *sourceView, id imageNode);
FOUNDATION_EXPORT NSData *YTKACEPostElementData(id cellNode);
FOUNDATION_EXPORT NSArray<NSData *> *YTKACECapturedPostElementData(void);
