#import "SponsorThumbnailBadge.h"
#import "SponsorPreferences.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Hooking.h"

#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

static os_unfair_lock YTKACEBadgeLock = OS_UNFAIR_LOCK_INIT;
static NSCache<NSString *, NSDictionary<NSString *, NSString *> *> *YTKACEPrefixCache;
static NSMutableDictionary<NSString *, NSString *> *YTKACEDirectLabelCache;
static NSMutableSet<NSString *> *YTKACEInFlightPrefixes;
static NSMapTable<id, NSString *> *YTKACEActiveNodes;
static NSURLSession *YTKACEBadgeSession;
static NSMutableDictionary<NSString *, UIImage *> *YTKACEBadgeImageCache;

static const void *YTKACESponsorBadgeLayerKey = &YTKACESponsorBadgeLayerKey;
static const void *YTKACESponsorBadgeVideoIDKey = &YTKACESponsorBadgeVideoIDKey;

static void YTKACEEnsureBadgeSession(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACEPrefixCache = [NSCache new];
        YTKACEPrefixCache.countLimit = 512;
        YTKACEDirectLabelCache = [NSMutableDictionary dictionaryWithCapacity:256];
        YTKACEInFlightPrefixes = [NSMutableSet set];
        YTKACEActiveNodes = [NSMapTable weakToStrongObjectsMapTable];
        YTKACEBadgeImageCache = [NSMutableDictionary dictionaryWithCapacity:8];

        NSURLSessionConfiguration *config =
            NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 10.0;
        config.timeoutIntervalForResource = 15.0;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        YTKACEBadgeSession = [NSURLSession sessionWithConfiguration:config];
    });
}

static UIImage *YTKACESponsorBadgeImageForCategory(NSString *category) {
    if (category.length == 0) return nil;

    os_unfair_lock_lock(&YTKACEBadgeLock);
    if (YTKACEBadgeImageCache == nil) {
        YTKACEBadgeImageCache = [NSMutableDictionary dictionaryWithCapacity:8];
    }
    UIImage *cached = YTKACEBadgeImageCache[category];
    os_unfair_lock_unlock(&YTKACEBadgeLock);
    if (cached != nil) return cached;

    NSString *text = YTKACELocalized(@"SPONSOR");
    if ([category isEqualToString:@"selfpromo"]) {
        text = YTKACELocalized(@"AUTOPROMO");
    } else if ([category isEqualToString:@"exclusive_access"]) {
        text = YTKACELocalized(@"EXCLUSIVE");
    }

    UIColor *bg = YTKACESponsorCategoryColor(category);
    if (bg == nil) {
        bg = [UIColor colorWithRed:0.0 green:0.83 blue:0.51 alpha:1.0];
    }

    CGFloat r = 0, g = 0, b = 0, a = 0;
    BOOL hasRGB = [bg getRed:&r green:&g blue:&b alpha:&a];
    CGFloat luminance = hasRGB ? (0.299 * r + 0.587 * g + 0.114 * b) : 0.0;
    UIColor *textColor = (luminance > 0.62)
        ? [UIColor colorWithWhite:0.10 alpha:1.0]
        : [UIColor whiteColor];

    UIFont *font = [UIFont systemFontOfSize:9.0 weight:UIFontWeightHeavy];
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: textColor
    };
    CGSize textSize = [text sizeWithAttributes:attrs];
    CGFloat width = ceil(textSize.width + 10.0);
    CGFloat height = 15.0;
    CGSize size = CGSizeMake(width, height);

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0.5, 0.5, width - 1.0, height - 1.0);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:3.5];

        [[bg colorWithAlphaComponent:0.95] setFill];
        [path fill];

        [[UIColor colorWithWhite:0.0 alpha:0.22] setStroke];
        path.lineWidth = 0.5;
        [path stroke];

        CGFloat textX = (CGFloat)((int)((width - textSize.width) / 2.0));
        CGFloat textY = (CGFloat)((int)((height - textSize.height) / 2.0));
        CGRect textRect = CGRectMake(textX, textY, textSize.width, textSize.height);
        [text drawInRect:textRect withAttributes:attrs];
    }];

    if (image != nil) {
        os_unfair_lock_lock(&YTKACEBadgeLock);
        YTKACEBadgeImageCache[category] = image;
        os_unfair_lock_unlock(&YTKACEBadgeLock);
    }
    return image;
}

static NSString *YTKACEVideoIDHashPrefix(NSString *videoID) {
    if (videoID.length == 0) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    const char *utf8 = [videoID UTF8String];
    if (utf8 == NULL) return nil;
    CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
    return [NSString stringWithFormat:@"%02x%02x", digest[0], digest[1]];
}

static NSString *YTKACEExtractVideoID(id URLOrVideoID) {
    if (URLOrVideoID == nil) return nil;
    if ([URLOrVideoID isKindOfClass:NSString.class]) {
        NSString *str = (NSString *)URLOrVideoID;
        if (str.length == 11 &&
            [str rangeOfString:@"/"].location == NSNotFound &&
            [str rangeOfString:@"?"].location == NSNotFound) {
            return str;
        }
        if ([str rangeOfString:@"/vi"].location != NSNotFound ||
            [str rangeOfString:@"/an_webp"].location != NSNotFound) {
            static NSRegularExpression *expression;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                expression = [NSRegularExpression regularExpressionWithPattern:
                    @"/(?:vi|vi_webp|an_webp)/([A-Za-z0-9_-]{11})/" options:0 error:nil];
            });
            NSTextCheckingResult *match =
                [expression firstMatchInString:str options:0
                                         range:NSMakeRange(0, str.length)];
            if (match.numberOfRanges >= 2) {
                return [str substringWithRange:[match rangeAtIndex:1]];
            }
        }
        if ([str rangeOfString:@"v="].location != NSNotFound) {
            static NSRegularExpression *vExpr;
            static dispatch_once_t vOnceToken;
            dispatch_once(&vOnceToken, ^{
                vExpr = [NSRegularExpression regularExpressionWithPattern:
                    @"[?&]v=([A-Za-z0-9_-]{11})" options:0 error:nil];
            });
            NSTextCheckingResult *vMatch =
                [vExpr firstMatchInString:str options:0
                                    range:NSMakeRange(0, str.length)];
            if (vMatch.numberOfRanges >= 2) {
                return [str substringWithRange:[vMatch rangeAtIndex:1]];
            }
        }
        return nil;
    }
    if ([URLOrVideoID isKindOfClass:NSURL.class]) {
        return YTKACEExtractVideoID(((NSURL *)URLOrVideoID).absoluteString);
    }
    return nil;
}

void YTKACESponsorRecordVideoLabel(NSString *videoID, NSString *category) {
    if (videoID.length == 0 || category.length == 0) return;
    YTKACEEnsureBadgeSession();
    os_unfair_lock_lock(&YTKACEBadgeLock);
    YTKACEDirectLabelCache[videoID] = category;
    os_unfair_lock_unlock(&YTKACEBadgeLock);
}

static NSString *YTKACEKnownLabelForVideoID(NSString *videoID) {
    if (videoID.length == 0) return nil;
    YTKACEEnsureBadgeSession();
    os_unfair_lock_lock(&YTKACEBadgeLock);
    NSString *direct = YTKACEDirectLabelCache[videoID];
    os_unfair_lock_unlock(&YTKACEBadgeLock);
    if (direct != nil) return direct.length > 0 ? direct : nil;

    NSString *prefix = YTKACEVideoIDHashPrefix(videoID);
    if (prefix.length == 0) return nil;

    NSDictionary<NSString *, NSString *> *bucket = [YTKACEPrefixCache objectForKey:prefix];
    if (bucket != nil) {
        return bucket[videoID];
    }
    return nil;
}

static BOOL YTKACEIsPrefixCached(NSString *prefix) {
    if (prefix.length == 0) return NO;
    YTKACEEnsureBadgeSession();
    return [YTKACEPrefixCache objectForKey:prefix] != nil;
}

static void YTKACEApplyBadgeToNodeInternal(id node, NSString *videoID);

static void YTKACEFetchBucketForPrefix(NSString *prefix) {
    if (prefix.length == 0) return;
    YTKACEEnsureBadgeSession();

    os_unfair_lock_lock(&YTKACEBadgeLock);
    if ([YTKACEPrefixCache objectForKey:prefix] != nil ||
        [YTKACEInFlightPrefixes containsObject:prefix]) {
        os_unfair_lock_unlock(&YTKACEBadgeLock);
        return;
    }
    [YTKACEInFlightPrefixes addObject:prefix];
    os_unfair_lock_unlock(&YTKACEBadgeLock);

    NSString *urlString = [NSString stringWithFormat:
        @"https://sponsor.ajay.app/api/videoLabels/%@?hasStartSegment=true", prefix];
    NSURL *url = [NSURL URLWithString:urlString];
    if (url == nil) {
        os_unfair_lock_lock(&YTKACEBadgeLock);
        [YTKACEInFlightPrefixes removeObject:prefix];
        os_unfair_lock_unlock(&YTKACEBadgeLock);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [YTKACEBadgeSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableDictionary<NSString *, NSString *> *bucket = [NSMutableDictionary dictionary];
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;

        if (error == nil && http.statusCode == 200 && data.length > 0) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSArray.class]) {
                for (id item in (NSArray *)json) {
                    if (![item isKindOfClass:NSDictionary.class]) continue;
                    NSString *vid = item[@"videoID"];
                    if (vid.length == 0) continue;
                    NSArray *segments = item[@"segments"];
                    if ([segments isKindOfClass:NSArray.class] && segments.count > 0) {
                        NSDictionary *firstSeg = segments[0];
                        if ([firstSeg isKindOfClass:NSDictionary.class]) {
                            NSString *cat = firstSeg[@"category"];
                            if (cat.length > 0) {
                                bucket[vid] = cat;
                            }
                        }
                    }
                }
            }
        }

        [YTKACEPrefixCache setObject:bucket forKey:prefix];

        os_unfair_lock_lock(&YTKACEBadgeLock);
        [YTKACEInFlightPrefixes removeObject:prefix];
        NSArray *nodes = [[YTKACEActiveNodes keyEnumerator] allObjects];
        os_unfair_lock_unlock(&YTKACEBadgeLock);

        dispatch_async(dispatch_get_main_queue(), ^{
            for (id activeNode in nodes) {
                os_unfair_lock_lock(&YTKACEBadgeLock);
                NSString *activeVid = [YTKACEActiveNodes objectForKey:activeNode];
                os_unfair_lock_unlock(&YTKACEBadgeLock);

                if (activeVid.length > 0 &&
                    [YTKACEVideoIDHashPrefix(activeVid) isEqualToString:prefix]) {
                    YTKACEApplyBadgeToNodeInternal(activeNode, activeVid);
                }
            }
        });
    }];
    [task resume];
}

static CALayer *YTKACEThumbnailLayerForNode(id node) {
    if (node == nil) return nil;
    if ([node isKindOfClass:CALayer.class]) return (CALayer *)node;
    if ([node isKindOfClass:UIView.class]) return ((UIView *)node).layer;

    SEL layerSel = NSSelectorFromString(@"layer");
    if ([node respondsToSelector:layerSel]) {
        id l = ((id (*)(id, SEL))objc_msgSend)(node, layerSel);
        if ([l isKindOfClass:CALayer.class]) return (CALayer *)l;
    }

    SEL viewSel = NSSelectorFromString(@"view");
    if ([node respondsToSelector:viewSel]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(node, viewSel);
        if ([v isKindOfClass:UIView.class]) return ((UIView *)v).layer;
    }

    return nil;
}

static NSString *YTKACEVideoIDForNode(id node) {
    if (node == nil) return nil;
    NSString *videoID = objc_getAssociatedObject(node, YTKACESponsorBadgeVideoIDKey);
    if (videoID.length == 11) return videoID;

    SEL urlSel = NSSelectorFromString(@"URL");
    if ([node respondsToSelector:urlSel]) {
        id url = ((id (*)(id, SEL))objc_msgSend)(node, urlSel);
        videoID = YTKACEExtractVideoID(url);
        if (videoID.length == 11) {
            objc_setAssociatedObject(node, YTKACESponsorBadgeVideoIDKey, videoID,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
            return videoID;
        }
    }

    SEL viewSel = NSSelectorFromString(@"view");
    if ([node respondsToSelector:viewSel]) {
        id view = ((id (*)(id, SEL))objc_msgSend)(node, viewSel);
        if (view != nil) {
            NSString *vVid = objc_getAssociatedObject(view, YTKACESponsorBadgeVideoIDKey);
            if (vVid.length == 11) return vVid;
        }
    }

    id current = node;
    for (NSUInteger depth = 0; current != nil && depth < 8; depth++) {
        NSString *ancestorVid = objc_getAssociatedObject(current, YTKACESponsorBadgeVideoIDKey);
        if (ancestorVid.length == 11) {
            objc_setAssociatedObject(node, YTKACESponsorBadgeVideoIDKey, ancestorVid,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
            return ancestorVid;
        }
        SEL supernodeSel = NSSelectorFromString(@"supernode");
        if ([current respondsToSelector:supernodeSel]) {
            current = ((id (*)(id, SEL))objc_msgSend)(current, supernodeSel);
            continue;
        }
        if ([current isKindOfClass:UIView.class]) {
            current = [(UIView *)current superview];
            continue;
        }
        break;
    }

    return nil;
}

static void YTKACEApplyBadgeToNodeInternal(id node, NSString *videoID) {
    if (node == nil) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACEApplyBadgeToNodeInternal(node, videoID);
        });
        return;
    }

    CALayer *hostLayer = YTKACEThumbnailLayerForNode(node);
    if (hostLayer == nil) return;

    CALayer *badgeLayer = objc_getAssociatedObject(node, YTKACESponsorBadgeLayerKey);
    if (badgeLayer == nil) {
        badgeLayer = objc_getAssociatedObject(hostLayer, YTKACESponsorBadgeLayerKey);
    }

    if (!YTKACESponsorFullVideoLabelsEnabled()) {
        if (badgeLayer != nil) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            badgeLayer.hidden = YES;
            [CATransaction commit];
        }
        return;
    }

    NSString *category = YTKACEKnownLabelForVideoID(videoID);
    NSString *prefix = YTKACEVideoIDHashPrefix(videoID);

    if (category.length == 0 && !YTKACEIsPrefixCached(prefix)) {
        if (badgeLayer != nil) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            badgeLayer.hidden = YES;
            [CATransaction commit];
        }
        YTKACEFetchBucketForPrefix(prefix);
        return;
    }

    BOOL eligibleCategory = [category isEqualToString:@"sponsor"] ||
                            [category isEqualToString:@"selfpromo"] ||
                            [category isEqualToString:@"exclusive_access"];

    if (!eligibleCategory || YTKACESponsorCategoryBehavior(category) == 2) {
        if (badgeLayer != nil) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            badgeLayer.hidden = YES;
            [CATransaction commit];
        }
        return;
    }

    CGRect bounds = hostLayer.bounds;
    if (CGRectGetWidth(bounds) > 0.0 &&
        (CGRectGetWidth(bounds) < 50.0 || CGRectGetHeight(bounds) < 35.0)) {
        if (badgeLayer != nil) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            badgeLayer.hidden = YES;
            [CATransaction commit];
        }
        return;
    }

    UIImage *badgeImg = YTKACESponsorBadgeImageForCategory(category);
    if (badgeImg == nil) return;

    if (badgeLayer == nil) {
        badgeLayer = [CALayer layer];
        badgeLayer.name = @"YTKACESponsorBadgeLayer";
        badgeLayer.shadowColor = [UIColor blackColor].CGColor;
        badgeLayer.shadowOpacity = 0.35f;
        badgeLayer.shadowOffset = CGSizeMake(0.0, 1.0);
        badgeLayer.shadowRadius = 1.5;
        objc_setAssociatedObject(node, YTKACESponsorBadgeLayerKey, badgeLayer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(hostLayer, YTKACESponsorBadgeLayerKey, badgeLayer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    badgeLayer.contents = (__bridge id)badgeImg.CGImage;
    badgeLayer.contentsScale = badgeImg.scale;
    badgeLayer.frame = CGRectMake(7.0, 7.0, badgeImg.size.width, badgeImg.size.height);
    badgeLayer.zPosition = 999.0;
    badgeLayer.hidden = NO;

    if (badgeLayer.superlayer != hostLayer) {
        [badgeLayer removeFromSuperlayer];
        [hostLayer addSublayer:badgeLayer];
    } else {
        [hostLayer addSublayer:badgeLayer];
    }

    [CATransaction commit];
}

void YTKACESponsorNoteThumbnail(id node, id _Nullable URLOrVideoID) {
    if (node == nil) return;
    NSString *videoID = YTKACEExtractVideoID(URLOrVideoID);
    if (videoID.length == 0) return;

    YTKACEEnsureBadgeSession();
    objc_setAssociatedObject(node, YTKACESponsorBadgeVideoIDKey, videoID,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    id current = node;
    for (NSUInteger depth = 0; current != nil && depth < 8; depth++) {
        NSString *name = NSStringFromClass([current class]);
        if ([name containsString:@"Cell"] || [name containsString:@"Entry"]) {
            objc_setAssociatedObject(current, YTKACESponsorBadgeVideoIDKey, videoID,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
            break;
        }
        SEL supernodeSel = NSSelectorFromString(@"supernode");
        if ([current respondsToSelector:supernodeSel]) {
            current = ((id (*)(id, SEL))objc_msgSend)(current, supernodeSel);
            continue;
        }
        if ([current isKindOfClass:UIView.class]) {
            current = [(UIView *)current superview];
            continue;
        }
        break;
    }

    os_unfair_lock_lock(&YTKACEBadgeLock);
    [YTKACEActiveNodes setObject:videoID forKey:node];
    os_unfair_lock_unlock(&YTKACEBadgeLock);

    void (^work)(void) = ^{
        YTKACEApplyBadgeToNodeInternal(node, videoID);
    };

    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

void YTKACESponsorUpdateThumbnailBadge(id node) {
    if (node == nil) return;
    NSString *videoID = YTKACEVideoIDForNode(node);
    if (videoID.length == 0) return;

    os_unfair_lock_lock(&YTKACEBadgeLock);
    [YTKACEActiveNodes setObject:videoID forKey:node];
    os_unfair_lock_unlock(&YTKACEBadgeLock);

    void (^work)(void) = ^{
        YTKACEApplyBadgeToNodeInternal(node, videoID);
    };

    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

static IMP OriginalELMSetURL;
static void YTKACEELMSetURL(id node, SEL selector, id URL) {
    if (OriginalELMSetURL != NULL) {
        ((void (*)(id, SEL, id))OriginalELMSetURL)(node, selector, URL);
    }
    YTKACESponsorNoteThumbnail(node, URL);
}

static IMP OriginalELMSetURLReset;
static void YTKACEELMSetURLReset(id node, SEL selector, id URL, BOOL reset) {
    if (OriginalELMSetURLReset != NULL) {
        ((void (*)(id, SEL, id, BOOL))OriginalELMSetURLReset)(node, selector, URL, reset);
    }
    YTKACESponsorNoteThumbnail(node, URL);
}

static IMP OriginalASSetURL;
static void YTKACEASSetURL(id node, SEL selector, id URL) {
    if (OriginalASSetURL != NULL) {
        ((void (*)(id, SEL, id))OriginalASSetURL)(node, selector, URL);
    }
    YTKACESponsorNoteThumbnail(node, URL);
}

static IMP OriginalASSetURLReset;
static void YTKACEASSetURLReset(id node, SEL selector, id URL, BOOL reset) {
    if (OriginalASSetURLReset != NULL) {
        ((void (*)(id, SEL, id, BOOL))OriginalASSetURLReset)(node, selector, URL, reset);
    }
    YTKACESponsorNoteThumbnail(node, URL);
}

void YTKACEInstallSponsorThumbnailBadgeHooks(void) {
    YTKACEEnsureBadgeSession();

    YTKACEInstallInstanceHook(@"ELMImageNode", @"setURL:",
                              (IMP)YTKACEELMSetURL, &OriginalELMSetURL);
    YTKACEInstallInstanceHook(@"ELMImageNode", @"setURL:resetToDefault:",
                              (IMP)YTKACEELMSetURLReset, &OriginalELMSetURLReset);
    YTKACEInstallInstanceHook(@"ASNetworkImageNode", @"setURL:",
                              (IMP)YTKACEASSetURL, &OriginalASSetURL);
    YTKACEInstallInstanceHook(@"ASNetworkImageNode", @"setURL:resetToDefault:",
                              (IMP)YTKACEASSetURLReset, &OriginalASSetURLReset);

    [NSNotificationCenter.defaultCenter
        addObserverForName:YTKACEPreferencesDidChangeNotification
                    object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
        os_unfair_lock_lock(&YTKACEBadgeLock);
        [YTKACEBadgeImageCache removeAllObjects];
        NSArray *nodes = [[YTKACEActiveNodes keyEnumerator] allObjects];
        os_unfair_lock_unlock(&YTKACEBadgeLock);

        for (id activeNode in nodes) {
            os_unfair_lock_lock(&YTKACEBadgeLock);
            NSString *vid = [YTKACEActiveNodes objectForKey:activeNode];
            os_unfair_lock_unlock(&YTKACEBadgeLock);

            if (vid.length > 0) {
                YTKACEApplyBadgeToNodeInternal(activeNode, vid);
            }
        }
    }];
}
