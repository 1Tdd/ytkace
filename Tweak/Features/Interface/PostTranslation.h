#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSArray<NSString *> *YTKACETranslationChunks(NSString *text, NSUInteger limit);
FOUNDATION_EXPORT NSString *YTKACETranslationResponse(NSData *data);

#ifndef YTKACE_TRANSLATION_TEST
#import <UIKit/UIKit.h>
FOUNDATION_EXPORT void YTKACEPresentPostTranslation(NSString *text, UIView *sourceView);
#endif
