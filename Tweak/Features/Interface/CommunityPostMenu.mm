#import "CommunityPostMenu.h"
#import "../../UI/MediaActionSheet.h"
#import "../../UI/MediaExport.h"
#import "../../UI/Notice.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import <objc/message.h>

static id YTKACEPostValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSURL *YTKACEPostOriginalURL(NSURL *URL) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    NSString *host = parts.host.lowercaseString;
    if (!([host hasSuffix:@".ggpht.com"] || [host hasSuffix:@".googleusercontent.com"])) return URL;
    NSRange options = [parts.path rangeOfString:@"=" options:NSBackwardsSearch];
    if (options.location != NSNotFound) parts.path = [[parts.path substringToIndex:options.location] stringByAppendingString:@"=s0"];
    return parts.URL ?: URL;
}

static NSArray<NSURL *> *YTKACEPostImages(id node) {
    NSMutableArray *pending = [NSMutableArray arrayWithObject:node];
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSMutableOrderedSet *URLs = [NSMutableOrderedSet orderedSet];
    for (NSUInteger i = 0; i < pending.count && i < 384; i++) {
        id item = pending[i];
        if ([seen containsObject:item]) continue;
        [seen addObject:item];
        id value = YTKACEPostValue(item, @"URL");
        NSURL *URL = [value isKindOfClass:NSURL.class] ? value : ([value isKindOfClass:NSString.class] ? [NSURL URLWithString:value] : nil);
        UIView *view = YTKACEPostValue(item, @"view");
        if (URL && [view isKindOfClass:UIView.class] && CGRectGetWidth(view.bounds) >= 100 && CGRectGetHeight(view.bounds) >= 70) [URLs addObject:URL];
        id children = YTKACEPostValue(item, @"subnodes");
        if ([children isKindOfClass:NSArray.class] && pending.count + [children count] <= 384) [pending addObjectsFromArray:children];
    }
    return URLs.array;
}

static NSURL *YTKACEPostLink(id node) {
    NSMutableArray *pending = [NSMutableArray arrayWithObject:node];
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (NSUInteger i = 0; i < pending.count && i < 64; ++i) {
        id item = pending[i];
        if ([seen containsObject:item]) continue;
        [seen addObject:item];
        for (NSString *name in @[@"postId", @"postID", @"backstagePostId"]) {
            id value = YTKACEPostValue(item, name);
            if ([value isKindOfClass:NSString.class] && [value length] && [value length] <= 256 &&
                [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet]].location == NSNotFound) {
                return [NSURL URLWithString:[@"https://www.youtube.com/post/" stringByAppendingString:value]];
            }
        }
        for (NSString *name in @[@"entry", @"elementRenderer", @"communityPostRenderer", @"backstagePostRenderer", @"postRenderer", @"post", @"renderer", @"model"]) {
            id child = YTKACEPostValue(item, name);
            if (child && child != item && pending.count < 64) [pending addObject:child];
        }
    }
    return nil;
}

@interface YTKACECommunityPostSheet : YTKACEMediaActionSheet
@property(nonatomic, weak) UIView *anchor;
@property(nonatomic, copy) NSString *postText;
@property(nonatomic, strong) UIImage *postSnapshot;
@property(nonatomic, strong) NSURL *postURL;
@property(nonatomic, copy) NSArray<NSURL *> *imageURLs;
@end

@implementation YTKACECommunityPostSheet
- (void)saveData:(NSArray<NSData *> *)images {
    YTKACESavePhotoData(images, ^(BOOL success, NSError *error) {
        YTKACEShowNotice(success ? YTKACELocalized(@"Saved to Photos") : (error.localizedDescription ?: YTKACELocalized(@"The image could not be saved.")));
    });
}
- (void)imageAction:(NSInteger)action URL:(NSURL *)URL {
    YTKACELoadImage(YTKACEPostOriginalURL(URL), URL, ^(NSData *data, NSError *error) {
        if (!data) { YTKACEShowNotice(error.localizedDescription); return; }
        if (action == 0) [self saveData:@[data]];
        else if (action == 1) YTKACEPreviewImage(data, YTKACEMediaPresenter(self.anchor));
        else { UIPasteboard.generalPasteboard.image = [UIImage imageWithData:data]; YTKACEShowNotice(YTKACELocalized(@"Image copied")); }
    });
}
- (void)saveImages:(NSArray<NSURL *> *)URLs atIndex:(NSUInteger)index data:(NSMutableArray<NSData *> *)data failed:(NSUInteger)failed {
    if (index == URLs.count) {
        if (!data.count) { YTKACEShowNotice(YTKACELocalized(@"The image could not be saved.")); return; }
        YTKACESavePhotoData(data, ^(BOOL success, NSError *error) {
            NSString *message = failed ? [NSString stringWithFormat:YTKACELocalized(@"Saved %lu images; %lu could not be loaded."), (unsigned long)data.count, (unsigned long)failed] : YTKACELocalized(@"Saved to Photos");
            YTKACEShowNotice(success ? message : error.localizedDescription);
        });
        return;
    }
    NSURL *URL = URLs[index];
    YTKACELoadImage(YTKACEPostOriginalURL(URL), URL, ^(NSData *image, __unused NSError *error) {
        if (image) [data addObject:image];
        [self saveImages:URLs atIndex:index + 1 data:data failed:failed + (image ? 0 : 1)];
    });
}
- (NSArray<YTKACEMediaAction *> *)actionsForImage:(NSURL *)URL identifier:(NSString *)identifier {
    __weak YTKACECommunityPostSheet *weakSelf = self;
    NSArray *titles = @[YTKACELocalized(@"Save current image"), YTKACELocalized(@"Show current image"), YTKACELocalized(@"Copy current image")];
    NSMutableArray *actions = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        [actions addObject:[YTKACEMediaAction action:[identifier stringByAppendingFormat:@".%lu", (unsigned long)i] title:titles[i]
            symbol:@[@"photo.badge.arrow.down", @"photo", @"doc.on.doc"][i] handler:^{ [weakSelf imageAction:i URL:URL]; }]];
    }
    return actions;
}
- (void)buildPostActions {
    __weak YTKACECommunityPostSheet *weakSelf = self;
    NSMutableArray *rows = [NSMutableArray array];
    if (self.postText.length && [YTKACEPreferenceObject(@"YTKACE.Preference.Posts.CopyText") boolValue]) {
        [rows addObject:[YTKACEMediaAction action:@"post.copy.text" title:YTKACELocalized(@"Copy post text") symbol:@"doc.on.doc" handler:^{
            UIPasteboard.generalPasteboard.string = weakSelf.postText;
            YTKACEShowNotice(YTKACELocalized(@"Text copied"));
        }]];
        [rows addObject:[YTKACEMediaAction action:@"post.translate" title:YTKACELocalized(@"Translate post") symbol:@"character.bubble" handler:^{
            NSURLComponents *URL = [NSURLComponents componentsWithString:@"https://translate.google.com/"];
            URL.queryItems = @[[NSURLQueryItem queryItemWithName:@"sl" value:@"auto"],
                [NSURLQueryItem queryItemWithName:@"tl" value:[NSLocale.preferredLanguages.firstObject componentsSeparatedByString:@"-"].firstObject ?: @"en"],
                [NSURLQueryItem queryItemWithName:@"text" value:weakSelf.postText], [NSURLQueryItem queryItemWithName:@"op" value:@"translate"]];
            [UIApplication.sharedApplication openURL:URL.URL options:@{} completionHandler:nil];
        }]];
    }
    if (self.postSnapshot && YTKACEFeatureEnabled(@"YTKACE.Preference.Posts.SaveImage")) {
        NSArray *actions = @[
            [YTKACEMediaAction action:@"post.snapshot.save" title:YTKACELocalized(@"Save post as image") symbol:@"photo.badge.arrow.down" handler:^{
                NSData *data = UIImagePNGRepresentation(weakSelf.postSnapshot);
                if (data) [weakSelf saveData:@[data]];
            }],
            [YTKACEMediaAction action:@"post.snapshot.copy" title:YTKACELocalized(@"Copy post as image") symbol:@"doc.on.doc" handler:^{
                UIPasteboard.generalPasteboard.image = weakSelf.postSnapshot;
                YTKACEShowNotice(YTKACELocalized(@"Image copied"));
            }]
        ];
        [rows addObject:[YTKACEMediaAction group:@"post.snapshot" title:YTKACELocalized(@"Post as image") symbol:@"photo.on.rectangle" children:actions]];
    }
    if (self.imageURLs.count && YTKACEFeatureEnabled(@"YTKACE.Preference.Posts.SaveImage")) {
        [rows addObject:[YTKACEMediaAction group:@"post.image" title:YTKACELocalized(@"Image") symbol:@"photo" children:[self actionsForImage:self.imageURLs.firstObject identifier:@"post.image"]]];
        if (self.imageURLs.count > 1) {
            NSMutableArray *images = [NSMutableArray arrayWithObject:[YTKACEMediaAction action:@"post.images.saveAll" title:YTKACELocalized(@"Save all images") symbol:@"square.and.arrow.down.on.square" handler:^{
                YTKACEShowNotice(YTKACELocalized(@"Saving images…"));
                [weakSelf saveImages:weakSelf.imageURLs atIndex:0 data:[NSMutableArray array] failed:0];
            }]];
            for (NSUInteger i = 0; i < self.imageURLs.count; i++) {
                NSString *identifier = [NSString stringWithFormat:@"post.images.%lu", (unsigned long)i];
                [images addObject:[YTKACEMediaAction group:identifier title:[NSString stringWithFormat:YTKACELocalized(@"Image %lu"), (unsigned long)i + 1] symbol:nil children:[self actionsForImage:self.imageURLs[i] identifier:identifier]]];
            }
            [rows addObject:[YTKACEMediaAction group:@"post.images" title:YTKACELocalized(@"Images") symbol:@"photo.stack" children:images]];
        }
    }
    if (self.postURL) [rows addObject:[YTKACEMediaAction action:@"post.copy.link" title:YTKACELocalized(@"Copy post link") symbol:@"link" handler:^{
        UIPasteboard.generalPasteboard.URL = weakSelf.postURL;
        YTKACEShowNotice(YTKACELocalized(@"Link copied"));
    }]];
    self.actionSections = rows.count ? @[rows] : @[];
}
@end

void YTKACEPresentCommunityPostMenu(UIView *postView, id node, NSString *text, NSURL *currentImage) {
    UIViewController *presenter = YTKACEMediaPresenter(postView);
    if (!presenter || !node || !postView.window) return;
    YTKACECommunityPostSheet *sheet = [YTKACECommunityPostSheet new];
    sheet.heading = YTKACELocalized(@"Community post");
    sheet.anchor = postView;
    sheet.postText = text;
    sheet.postURL = YTKACEPostLink(node);
    NSMutableOrderedSet *images = [NSMutableOrderedSet orderedSet];
    if (currentImage) [images addObject:currentImage];
    [images addObjectsFromArray:YTKACEPostImages(node)];
    sheet.imageURLs = images.array;
    CGSize size = postView.bounds.size;
    if (size.width > 0 && size.height > 0 && size.width <= 4096 && size.height <= 12000) {
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = MIN(UIScreen.mainScreen.scale, 4096 / MAX(size.width, size.height));
        format.opaque = YES;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
        sheet.postSnapshot = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [(postView.backgroundColor ?: UIColor.blackColor) setFill];
            UIRectFill((CGRect){CGPointZero, size});
            [postView.layer renderInContext:context.CGContext];
        }];
    }
    [sheet buildPostActions];
    if (sheet.actionSections.count) [presenter presentViewController:sheet animated:YES completion:nil];
}

void YTKACEPresentPostImageMenu(NSURL *imageURL, UIView *sourceView) {
    UIViewController *presenter = YTKACEMediaPresenter(sourceView);
    if (!imageURL || !presenter) return;
    YTKACECommunityPostSheet *sheet = [YTKACECommunityPostSheet new];
    sheet.heading = YTKACELocalized(@"Image");
    sheet.anchor = sourceView;
    sheet.imageURLs = @[imageURL];
    [sheet buildPostActions];
    [presenter presentViewController:sheet animated:YES completion:nil];
}
