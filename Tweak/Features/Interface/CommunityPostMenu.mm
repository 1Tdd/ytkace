#import "CommunityPostMenu.h"
#import "PostTranslation.h"
#import "PostImages.h"
#import "../../UI/MediaActionSheet.h"
#import "../../UI/MediaExport.h"
#import "../../UI/Notice.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import "../Downloads/DownloadLog.h"

static id YTKACEPostValue(id object, NSString *name) {
    if ([object isKindOfClass:NSDictionary.class]) return [object objectForKey:name];
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSURL *YTKACEPostLink(id node);

static NSArray<NSURL *> *YTKACEPostImages(id node) {
    if (!node) return @[];
    NSMutableArray *pending = [NSMutableArray arrayWithObject:@[node, @NO]];
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSHashTable *seenAttachments = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSMutableArray *URLs = [NSMutableArray array];
    NSMutableArray *metadataURLs = [NSMutableArray array];
    NSUInteger protoReads = 0, protoCharacters = 0;
    for (NSUInteger i = 0; i < pending.count && i < 512; i++) {
        id item = pending[i][0];
        BOOL attachment = [pending[i][1] boolValue];
        NSString *name = NSStringFromClass([item class]);
        id identifier = YTKACEPostValue(item, @"accessibilityIdentifier");
        NSString *token = [identifier isKindOfClass:NSString.class] ? [identifier lowercaseString] : @"";
        id templateURI = YTKACEPostValue(item, @"templateURI");
        if ([templateURI isKindOfClass:NSString.class]) token = [token stringByAppendingFormat:@" %@", [templateURI lowercaseString]];
        attachment |= [name containsString:@"BackstageImage"] || [name isEqual:@"YTImageZoomNode"] || [token containsString:@"post_attachment"] ||
            [token containsString:@"image_carousel"] || [token containsString:@"post_image"] ||
            [token containsString:@"image_gallery"] || [token containsString:@"image_viewer"];
        if ([name isEqualToString:@"ELMCollectionNode"]) {
            SEL vertical = NSSelectorFromString(@"isVertical");
            NSMethodSignature *signature = [item methodSignatureForSelector:vertical];
            if (signature.numberOfArguments == 2 && strcmp(signature.methodReturnType, @encode(BOOL)) == 0)
                attachment |= !((BOOL (*)(id, SEL))objc_msgSend)(item, vertical);
        }
        NSHashTable *visited = attachment ? seenAttachments : seen;
        if ([visited containsObject:item]) continue;
        [visited addObject:item];
        id value = YTKACEPostValue(item, @"URL") ?: YTKACEPostValue(item, @"url");
        NSURL *URL = [value isKindOfClass:NSURL.class] ? value : ([value isKindOfClass:NSString.class] ? [NSURL URLWithString:value] : nil);
        if (URL) {
            UIView *view = attachment ? nil : YTKACEPostValue(item, @"view");
            if (attachment || ([view isKindOfClass:UIView.class] && CGRectGetWidth(view.bounds) >= 100 && CGRectGetHeight(view.bounds) >= 70))
                [URLs addObject:URL];
        }
        // ELM keeps offscreen carousel entries in its element tree before creating image views.
        if ([name isEqualToString:@"ELMElement"] && protoReads++ < 64 && protoCharacters < 4 * 1024 * 1024) {
            id proto = YTKACEPostValue(item, @"protoText");
            if ([proto isKindOfClass:NSString.class]) {
                protoCharacters += [proto length];
                for (NSURL *URL in YTKACEPostImageURLsInProto(proto)) {
                    // Unmaterialized image bindings can live in the post's parent
                    // component. Outside an attachment, accept only post-image URLs,
                    // never the author avatar or images mentioned in the post text.
                    if (attachment || [URL.path containsString:@"-nd-v1"]) [metadataURLs addObject:URL];
                }
            }
        }
        for (NSString *key in @[@"subnodes", @"childElements", @"element", @"entry", @"model",
                                @"backstagePostRenderer", @"communityPostRenderer", @"postRenderer",
                                @"backstageAttachment", @"backstageImageRenderer", @"postMultiImageRenderer",
                                @"image", @"images", @"imagesArray", @"sources", @"sourcesArray", @"thumbnails", @"thumbnailsArray",
                                @"controller", @"nodeController", @"children", @"cellNodes", @"cellControllers", @"materializedInstance", @"owningComponent"]) {
            id children = YTKACEPostValue(item, key);
            if (!children || children == item) continue;
            if (([key isEqualToString:@"controller"] || [key isEqualToString:@"nodeController"]) &&
                ![NSStringFromClass([children class]) hasPrefix:@"ELM"]) continue;
            if ([key isEqualToString:@"owningComponent"]) {
                id URI = YTKACEPostValue(children, @"templateURI");
                NSString *templateName = [URI isKindOfClass:NSString.class] ? [URI lowercaseString] : @"";
                // Never walk from a post to its feed/channel component.
                if (![templateName containsString:@"post"] && ![templateName containsString:@"image"]) continue;
            }
            BOOL childAttachment = attachment || [key isEqualToString:@"backstageAttachment"] ||
                [key isEqualToString:@"backstageImageRenderer"] || [key isEqualToString:@"postMultiImageRenderer"];
            NSArray *values = [children isKindOfClass:NSArray.class] ? children : @[children];
            for (id child in values) {
                if (pending.count >= 512) break;
                [pending addObject:@[child, @(childAttachment)]];
            }
        }
        NSArray *ivarNames = [name isEqualToString:@"ELMCollectionNode"]
            ? @[@"_singleSectionController", @"_pendingSectionNodes", @"_lazyPendingSectionNodeControllers"]
            : ([name isEqualToString:@"ELMComponent"] ? @[@"_lastMaterializedElement", @"_stagedRdmElement"] : @[]);
        if (ivarNames.count) {
            // Read already available lazy/bound elements without materializing cells.
            for (NSString *key in ivarNames) {
                Ivar ivar = class_getInstanceVariable([item class], key.UTF8String);
                const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
                id value = type && type[0] == '@' ? object_getIvar(item, ivar) : nil;
                if (!value) continue;
                NSArray *children = [value isKindOfClass:NSArray.class] ? value : @[value];
                for (id child in children) {
                    if (pending.count >= 512) break;
                    [pending addObject:@[child, @(attachment)]];
                }
            }
        }
    }
    [metadataURLs addObjectsFromArray:URLs];
    return YTKACEUniquePostImageURLs(metadataURLs);
}

static NSArray<NSURL *> *YTKACEPostImagesForViewer(NSURL *current, UIView *sourceView, id imageNode, NSURL **postURL) {
    NSMutableArray *best = [YTKACEPostImages(imageNode) mutableCopy];
    if (current) [best addObject:current];
    NSArray *result = YTKACEUniquePostImageURLs(best);
    if (postURL) *postURL = YTKACEPostLink(imageNode);
    // The fullscreen viewer only exposes one URL. Match it to its underlying post cell.
    // Inspect loaded view trees only; never instantiate or scroll neighbouring feed cells.
    NSMutableArray<UIView *> *pending = [NSMutableArray array];
    UIViewController *presenter = YTKACEMediaPresenter(sourceView);
    for (NSUInteger depth = 0; presenter && depth < 8; ++depth, presenter = presenter.presentingViewController)
        if (presenter.isViewLoaded) [pending addObject:presenter.view];
    UIViewController *root = sourceView.window.rootViewController;
    if (root.isViewLoaded) [pending addObject:root.view];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *controller = window.rootViewController;
            for (NSUInteger depth = 0; controller && depth < 8; depth++, controller = controller.presentedViewController) {
                if (controller.isViewLoaded) [pending addObject:controller.view];
            }
        }
    }
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSUInteger cells = 0;
    for (NSUInteger i = 0; i < pending.count && i < 1600 && cells < 32; ++i) {
        UIView *view = pending[i];
        if ([seen containsObject:view]) continue;
        [seen addObject:view];
        if ([view isKindOfClass:UICollectionViewCell.class] || [view isKindOfClass:UITableViewCell.class]) {
            id node = YTKACEPostValue(view, @"node") ?: YTKACEPostValue(view, @"keepalive_node");
            if (node) {
                ++cells;
                NSArray *candidate = YTKACEPostImages(node);
                // Canonical URL comparison also matches a differently sized viewer image.
                if (candidate.count && current &&
                    YTKACEUniquePostImageURLs([candidate arrayByAddingObject:current]).count == candidate.count) {
                    if (candidate.count > result.count) result = candidate;
                    if (postURL && !*postURL) *postURL = YTKACEPostLink(node);
                }
            }
        }
        for (UIView *child in view.subviews) {
            if (pending.count >= 1600) break;
            [pending addObject:child];
        }
    }
    YTKACEDownloadLog(@"posts", @"viewer images=%lu matchedCells=%lu", (unsigned long)result.count, (unsigned long)cells);
    return result;
}

static NSURL *YTKACEPostLink(id node) {
    if (!node) return nil;
    NSMutableArray *pending = [NSMutableArray arrayWithObject:node];
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (NSUInteger i = 0; i < pending.count && i < 256; ++i) {
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
        for (NSString *key in @[@"protoText", @"URL", @"url"]) {
            id value = YTKACEPostValue(item, key);
            if ([value isKindOfClass:NSURL.class]) value = [value absoluteString];
            NSString *postID = YTKACEPostIDInText(value);
            if (postID) return [NSURL URLWithString:[@"https://www.youtube.com/post/" stringByAppendingString:postID]];
        }
        for (NSString *name in @[@"entry", @"element", @"elementRenderer", @"communityPostRenderer", @"backstagePostRenderer", @"postRenderer", @"post", @"renderer", @"model", @"controller", @"nodeController", @"owningComponent", @"materializedInstance", @"children", @"subnodes", @"childElements"]) {
            id child = YTKACEPostValue(item, name);
            if (!child || child == item) continue;
            if ([name isEqual:@"owningComponent"]) {
                id URI = YTKACEPostValue(child, @"templateURI");
                if (![URI isKindOfClass:NSString.class] || ([URI rangeOfString:@"post" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                    [URI rangeOfString:@"image" options:NSCaseInsensitiveSearch].location == NSNotFound)) continue;
            }
            NSArray *children = [child isKindOfClass:NSArray.class] ? child : @[child];
            for (id value in children) {
                if (pending.count >= 256) break;
                [pending addObject:value];
            }
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
@property(nonatomic, strong) NSURL *currentImageURL;
@property(nonatomic, assign) BOOL savingImages;
@property(nonatomic, assign) BOOL resolvingImages;
@property(nonatomic, assign) BOOL imagesResolved;
@property(nonatomic, assign) BOOL saveWhenResolved;
@property(nonatomic, assign) BOOL communityPost;
@property(nonatomic, weak) id postNode;
@end

@implementation YTKACECommunityPostSheet
- (void)saveData:(NSArray<NSData *> *)images {
    YTKACESavePhotoData(images, ^(BOOL success, NSError *error) {
        YTKACEShowNotice(success ? YTKACELocalized(@"Saved to Photos") : (error.localizedDescription ?: YTKACELocalized(@"The image could not be saved.")));
    });
}
- (void)imageAction:(NSInteger)action URL:(NSURL *)URL {
    YTKACELoadImage(YTKACEPostOriginalImageURL(URL), URL, ^(NSData *data, NSError *error) {
        if (!data) { YTKACEShowNotice(error.localizedDescription); return; }
        if (action == 0) [self saveData:@[data]];
        else if (action == 1) YTKACEPreviewImage(data, YTKACEMediaPresenter(self.anchor));
        else { UIPasteboard.generalPasteboard.image = [UIImage imageWithData:data]; YTKACEShowNotice(YTKACELocalized(@"Image copied")); }
    });
}
- (void)saveImages:(NSArray<NSURL *> *)URLs atIndex:(NSUInteger)index saved:(NSUInteger)saved failed:(NSUInteger)failed {
    if (index == URLs.count) {
        self.savingImages = NO;
        NSString *message = !saved ? YTKACELocalized(@"The image could not be saved.") :
            (failed ? [NSString stringWithFormat:YTKACELocalized(@"Saved %lu images; %lu could not be loaded."), (unsigned long)saved, (unsigned long)failed] :
                [NSString stringWithFormat:YTKACELocalized(@"Saved %lu images."), (unsigned long)saved]);
        YTKACEShowNotice(message);
        return;
    }
    YTKACEShowNotice([NSString stringWithFormat:YTKACELocalized(@"Saving image %lu of %lu…"),
        (unsigned long)index + 1, (unsigned long)URLs.count]);
    NSURL *URL = URLs[index];
    YTKACELoadImage(YTKACEPostOriginalImageURL(URL), URL, ^(NSData *image, __unused NSError *error) {
        if (!image) { [self saveImages:URLs atIndex:index + 1 saved:saved failed:failed + 1]; return; }
        // Save one at a time so a carousel of full-resolution images does not accumulate in RAM.
        YTKACESavePhotoData(@[image], ^(BOOL success, NSError *saveError) {
            if (!success) {
                self.savingImages = NO;
                YTKACEShowNotice([NSString stringWithFormat:YTKACELocalized(@"Saved %lu images. %@"),
                    (unsigned long)saved, saveError.localizedDescription ?: YTKACELocalized(@"The image could not be saved.")]);
                return;
            }
            [self saveImages:URLs atIndex:index + 1 saved:saved + 1 failed:failed];
        });
    });
}
- (void)resolvePostImages {
    if (self.resolvingImages || self.imagesResolved) return;
    if (!self.postURL) self.postURL = YTKACEPostLink(self.postNode);
    if (!self.postURL) {
        // Bound local carousel models can still provide a complete multi-image list.
        self.imagesResolved = self.imageURLs.count > 1;
        [self buildPostActions];
        return;
    }
    self.resolvingImages = YES;
    [self buildPostActions];
    NSString *postID = self.postURL.lastPathComponent;
    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.youtube.com/post/%@?hl=en", postID]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL
        cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:20];
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *page = !error && status >= 200 && status < 300 && data.length <= 8 * 1024 * 1024
            ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSArray<NSURL *> *URLs = YTKACEPostImageURLsInPage(page, postID);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.resolvingImages = NO;
            NSURL *current = self.currentImageURL ?: self.imageURLs.firstObject;
            BOOL matches = !current || YTKACEUniquePostImageURLs([URLs arrayByAddingObject:current]).count == URLs.count;
            if (URLs.count && matches) {
                self.imageURLs = URLs;
                self.imagesResolved = YES;
            }
            YTKACEDownloadLog(@"posts", @"post image list status=%ld images=%lu matched=%d", (long)status, (unsigned long)URLs.count, matches);
            [self buildPostActions];
            if (self.saveWhenResolved) {
                self.saveWhenResolved = NO;
                if (self.imagesResolved) [self saveAllImages];
                else YTKACEShowNotice(YTKACELocalized(@"Could not load all post images. Open the post and try again."));
            }
        });
    }] resume];
}
- (void)saveAllImages {
    if (self.savingImages) return;
    if (!self.imagesResolved) {
        NSArray *resolved = self.communityPost ? YTKACEPostImages(self.postNode) :
            YTKACEPostImagesForViewer(self.currentImageURL, self.anchor, self.postNode, NULL);
        if (resolved.count > self.imageURLs.count) self.imageURLs = resolved;
        [self resolvePostImages];
        if (self.resolvingImages) { self.saveWhenResolved = YES; return; }
        if (!self.imagesResolved) {
            YTKACEShowNotice(YTKACELocalized(@"Could not load all post images. Open the post and try again."));
            return;
        }
    }
    if (!self.imageURLs.count) { YTKACEShowNotice(YTKACELocalized(@"No images found")); return; }
    self.savingImages = YES;
    [self saveImages:[self.imageURLs copy] atIndex:0 saved:0 failed:0];
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
            YTKACEPresentPostTranslation(weakSelf.postText, weakSelf.anchor);
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
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Posts.SaveImage")) {
        YTKACEMediaAction *saveAll = [YTKACEMediaAction action:@"post.images.saveAll"
            title:YTKACELocalized(@"Save all images") symbol:@"square.and.arrow.down.on.square"
            handler:^{ [weakSelf saveAllImages]; }];
        saveAll.detail = self.resolvingImages ? YTKACELocalized(@"Loading images…") :
            (self.imagesResolved ? [NSString stringWithFormat:YTKACELocalized(@"Images: %lu"), (unsigned long)self.imageURLs.count] :
                YTKACELocalized(@"Image list unavailable"));
        [rows addObject:saveAll];
    }
    if (self.imageURLs.count && YTKACEFeatureEnabled(@"YTKACE.Preference.Posts.SaveImage")) {
        [rows addObject:[YTKACEMediaAction group:@"post.image" title:YTKACELocalized(@"Image") symbol:@"photo" children:[self actionsForImage:self.currentImageURL ?: self.imageURLs.firstObject identifier:@"post.image"]]];
        if (self.imageURLs.count > 1) {
            NSMutableArray *images = [NSMutableArray array];
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
    sheet.communityPost = YES;
    sheet.postNode = node;
    sheet.postURL = YTKACEPostLink(node);
    NSMutableArray *images = [YTKACEPostImages(node) mutableCopy];
    if (currentImage) [images addObject:currentImage];
    sheet.imageURLs = YTKACEUniquePostImageURLs(images);
    sheet.currentImageURL = currentImage;
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
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Posts.SaveImage")) [sheet resolvePostImages];
    if (sheet.actionSections.count) [presenter presentViewController:sheet animated:YES completion:nil];
}

void YTKACEPresentPostImageMenu(NSURL *imageURL, UIView *sourceView, id imageNode) {
    UIViewController *presenter = YTKACEMediaPresenter(sourceView);
    if (!imageURL || !presenter) return;
    YTKACECommunityPostSheet *sheet = [YTKACECommunityPostSheet new];
    sheet.heading = YTKACELocalized(@"Image");
    sheet.anchor = sourceView;
    sheet.postNode = imageNode;
    sheet.currentImageURL = imageURL;
    NSURL *postURL = nil;
    sheet.imageURLs = YTKACEPostImagesForViewer(imageURL, sourceView, imageNode, &postURL);
    sheet.postURL = postURL;
    [sheet buildPostActions];
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Posts.SaveImage")) [sheet resolvePostImages];
    [presenter presentViewController:sheet animated:YES completion:nil];
}
