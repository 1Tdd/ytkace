#import "DeArrow.h"
#import "SponsorThumbnailBadge.h"
#import "SponsorPreferences.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <stdatomic.h>

NSString * const YTKACEDeArrowThumbModeKey = @"YTKACE.Preference.DeArrow.ThumbnailMode";
NSString * const YTKACEDeArrowTitlesKey = @"YTKACE.Preference.DeArrow.Titles";

static NSString * const YTKACEBrandingStoreKey = @"YTKACE.Preference.DeArrow.Branding";

static const NSUInteger YTKACEStoreLimit = 800;
static const NSUInteger YTKACEMaxConcurrent = 4;
static const NSUInteger YTKACERequestsPerMinute = 90;
static const NSUInteger YTKACEPendingLimit = 300;
static const NSUInteger YTKACEAncestorDepth = 12;
static const NSUInteger YTKACECellTextDepth = 10;
static const NSUInteger YTKACEMaxCellText = 10;
static const NSTimeInterval YTKACENegativeTTL = 7 * 24 * 60 * 60;
static const NSInteger YTKACEStoreVersion = 2;

static IMP OriginalDownloadImage;
static IMP OriginalCachedImage;
static IMP OriginalApplyProperties;

static const void *YTKACENodeVideoIDKey = &YTKACENodeVideoIDKey;
static const void *YTKACECellVideoIDKey = &YTKACECellVideoIDKey;

static os_unfair_lock YTKACELock = OS_UNFAIR_LOCK_INIT;
static NSUInteger YTKACEActiveRequests;
static NSUInteger YTKACEWindowCount;
static NSTimeInterval YTKACEWindowStart;
static NSMutableSet<NSString *> *YTKACEInFlight;
static NSMutableSet<NSString *> *YTKACEThumbInFlight;
static NSMutableArray<NSString *> *YTKACEPendingIDs;
static NSMapTable *YTKACEPendingNodes;
static NSMapTable *YTKACEPendingCells;
static NSMutableDictionary<NSString *, NSDictionary *> *YTKACEStore;
static NSCache<NSString *, UIImage *> *YTKACEImageCache;

static atomic_int YTKACEModeCache = -1;
static atomic_int YTKACETitlesCache = -1;

static void YTKACEPumpQueue(void);
static void YTKACEApplyTitleToCell(id root, NSString *videoID);

static NSInteger YTKACEThumbMode(void) {
    int cached = atomic_load(&YTKACEModeCache);
    if (cached >= 0) return cached;
    id stored = YTKACEPreferenceObject(YTKACEDeArrowThumbModeKey);
    NSInteger mode = [stored respondsToSelector:@selector(integerValue)]
        ? MAX(0, MIN([stored integerValue], 1)) : 0;
    atomic_store(&YTKACEModeCache, (int)mode);
    return mode;
}

static BOOL YTKACEReplacingTitles(void) {
    int cached = atomic_load(&YTKACETitlesCache);
    if (cached >= 0) return cached != 0;
    BOOL enabled = YTKACEFeatureEnabled(YTKACEDeArrowTitlesKey);
    atomic_store(&YTKACETitlesCache, enabled ? 1 : 0);
    return enabled;
}

static BOOL YTKACEReplacingThumbs(void) {
    return YTKACEThumbMode() > 0;
}

static BOOL YTKACEAnyFeatureOn(void) {
    return YTKACEReplacingThumbs() || YTKACEReplacingTitles();
}

static id YTKACESend(id object, SEL selector) {
    if (object == nil || selector == NULL) return nil;
    @try {
        if (![object respondsToSelector:selector]) return nil;
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id YTKACESupernode(id node) {
    return YTKACESend(node, @selector(supernode));
}

static NSArray *YTKACESubnodes(id node) {
    id value = YTKACESend(node, @selector(subnodes));
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSString *YTKACENodeText(id node) {
    id value = YTKACESend(node, @selector(attributedText));
    if ([value isKindOfClass:NSAttributedString.class]) {
        return ((NSAttributedString *)value).string;
    }
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id YTKACECellRoot(id node) {
    static Class cellClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cellClass = NSClassFromString(@"ELMCellNode");
    });
    if (cellClass == Nil) return nil;
    id current = node;
    for (NSUInteger level = 0; level < YTKACEAncestorDepth; level++) {
        if ([current isKindOfClass:cellClass]) return current;
        current = YTKACESupernode(current);
        if (current == nil) break;
    }
    return nil;
}

static NSString *YTKACEVideoIDFromURL(NSString *absolute) {
    if (absolute.length == 0) return nil;
    if ([absolute rangeOfString:@"/vi"].location == NSNotFound) return nil;
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"/(?:vi|vi_webp)/([A-Za-z0-9_-]{11})/" options:0 error:nil];
    });
    NSTextCheckingResult *match =
        [expression firstMatchInString:absolute options:0
                                 range:NSMakeRange(0, absolute.length)];
    if (match.numberOfRanges < 2) return nil;
    return [absolute substringWithRange:[match rangeAtIndex:1]];
}

static NSString *YTKACEURLString(id value) {
    if ([value isKindOfClass:NSURL.class]) return ((NSURL *)value).absoluteString;
    if ([value isKindOfClass:NSString.class]) return (NSString *)value;
    id resolved = YTKACESend(value, @selector(absoluteString));
    return [resolved isKindOfClass:NSString.class] ? resolved : nil;
}

static void YTKACELoadStore(void) {
    if (YTKACEStore != nil) return;
    NSDictionary *stored =
        [NSUserDefaults.standardUserDefaults dictionaryForKey:YTKACEBrandingStoreKey];
    YTKACEStore = [stored isKindOfClass:NSDictionary.class]
        ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    YTKACEImageCache = [NSCache new];
    YTKACEImageCache.countLimit = 160;
    YTKACEInFlight = [NSMutableSet set];
    YTKACEThumbInFlight = [NSMutableSet set];
    YTKACEPendingIDs = [NSMutableArray array];
    YTKACEPendingNodes = [NSMapTable strongToWeakObjectsMapTable];
    YTKACEPendingCells = [NSMapTable strongToWeakObjectsMapTable];
}

static void YTKACEEvictLocked(void) {
    if (YTKACEStore.count <= YTKACEStoreLimit) return;
    NSArray<NSString *> *ordered = [YTKACEStore.allKeys sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *left, NSString *right) {
            double a = [YTKACEStore[left][@"a"] doubleValue];
            double b = [YTKACEStore[right][@"a"] doubleValue];
            if (a < b) return NSOrderedAscending;
            if (a > b) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    NSUInteger drop = YTKACEStore.count - (YTKACEStoreLimit * 3 / 4);
    if (drop > ordered.count) drop = ordered.count;
    for (NSUInteger index = 0; index < drop; index++) {
        [YTKACEStore removeObjectForKey:ordered[index]];
    }
}

static void YTKACESchedulePersistStore(void) {
    static BOOL persistScheduled = NO;
    os_unfair_lock_lock(&YTKACELock);
    if (persistScheduled) {
        os_unfair_lock_unlock(&YTKACELock);
        return;
    }
    persistScheduled = YES;
    os_unfair_lock_unlock(&YTKACELock);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        os_unfair_lock_lock(&YTKACELock);
        persistScheduled = NO;
        YTKACEEvictLocked();
        NSDictionary *snapshot = [YTKACEStore copy];
        os_unfair_lock_unlock(&YTKACELock);
        if (snapshot != nil) {
            [NSUserDefaults.standardUserDefaults setObject:snapshot
                                                    forKey:YTKACEBrandingStoreKey];
        }
    });
}

static NSDictionary *YTKACEFreshEntryLocked(NSString *videoID) {
    NSDictionary *entry = YTKACEStore[videoID];
    if (entry == nil) return nil;
    if ([entry[@"v"] integerValue] < YTKACEStoreVersion) {
        [YTKACEStore removeObjectForKey:videoID];
        return nil;
    }
    if (entry[@"t"] != nil || entry[@"ti"] != nil) return entry;
    double added = [entry[@"a"] doubleValue];
    if (NSDate.date.timeIntervalSince1970 - added > YTKACENegativeTTL) {
        [YTKACEStore removeObjectForKey:videoID];
        return nil;
    }
    return entry;
}

static void YTKACEStoreBranding(NSString *videoID, NSNumber *timestamp,
                                NSString *title) {
    if (videoID.length == 0) return;
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"a"] = @(NSDate.date.timeIntervalSince1970);
    entry[@"v"] = @(YTKACEStoreVersion);
    if (timestamp != nil) entry[@"t"] = timestamp;
    if (title.length != 0) entry[@"ti"] = title;
    if (timestamp == nil && title.length == 0) entry[@"n"] = @YES;
    os_unfair_lock_lock(&YTKACELock);
    YTKACEStore[videoID] = entry;
    [YTKACEInFlight removeObject:videoID];
    if (YTKACEActiveRequests > 0) YTKACEActiveRequests--;
    os_unfair_lock_unlock(&YTKACELock);
    YTKACESchedulePersistStore();
    YTKACEPumpQueue();
}

static NSString *YTKACEStoredTitle(NSString *videoID) {
    if (videoID.length == 0) return nil;
    os_unfair_lock_lock(&YTKACELock);
    id title = YTKACEStore[videoID][@"ti"];
    os_unfair_lock_unlock(&YTKACELock);
    return [title isKindOfClass:NSString.class] ? title : nil;
}

static void YTKACEApplyImage(id node, NSString *videoID, UIImage *image) {
    if (node == nil || image == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        id current = objc_getAssociatedObject(node, YTKACENodeVideoIDKey);
        if (![current isEqual:videoID]) return;
        SEL setter = NSSelectorFromString(@"setImage:");
        if (![node respondsToSelector:setter]) return;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(node, setter, image);
        } @catch (__unused NSException *exception) {
        }
    });
}

static void YTKACEFetchThumbnail(NSString *videoID, double timestamp, id node) {
    if (!YTKACEReplacingThumbs()) return;
    os_unfair_lock_lock(&YTKACELock);
    BOOL busy = [YTKACEThumbInFlight containsObject:videoID];
    if (!busy) [YTKACEThumbInFlight addObject:videoID];
    os_unfair_lock_unlock(&YTKACELock);
    if (busy) return;

    NSString *address = [NSString stringWithFormat:
        @"https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=%@&time=%.3f",
        videoID, timestamp];
    NSURL *URL = [NSURL URLWithString:address];
    if (URL == nil) {
        os_unfair_lock_lock(&YTKACELock);
        [YTKACEThumbInFlight removeObject:videoID];
        os_unfair_lock_unlock(&YTKACELock);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.timeoutInterval = 20.0;
    __weak id weakNode = node;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        os_unfair_lock_lock(&YTKACELock);
        [YTKACEThumbInFlight removeObject:videoID];
        os_unfair_lock_unlock(&YTKACELock);
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        UIImage *decoded = (error == nil && http.statusCode == 200 && data.length != 0)
            ? [UIImage imageWithData:data] : nil;
        if (decoded == nil) return;
        os_unfair_lock_lock(&YTKACELock);
        [YTKACEImageCache setObject:decoded forKey:videoID];
        os_unfair_lock_unlock(&YTKACELock);
        YTKACEApplyImage(weakNode, videoID, decoded);
    }] resume];
}

static void YTKACECollectTextNodes(id node, NSUInteger depth, NSMutableArray *out) {
    if (node == nil || depth > YTKACECellTextDepth ||
        out.count >= YTKACEMaxCellText) {
        return;
    }
    static Class textClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        textClass = NSClassFromString(@"ELMTextNode");
    });
    if (textClass != Nil && [node isKindOfClass:textClass]) {
        if (YTKACENodeText(node).length != 0) [out addObject:node];
    }
    for (id child in YTKACESubnodes(node)) {
        YTKACECollectTextNodes(child, depth + 1, out);
    }
}

static BOOL YTKACELooksLikeDuration(NSString *text) {
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"^\\d{1,2}:\\d{2}(:\\d{2})?$" options:0 error:nil];
    });
    return [expression numberOfMatchesInString:text options:0
                                         range:NSMakeRange(0, text.length)] != 0;
}

static void YTKACEWriteTitle(id textNode, NSString *title) {
    void (^work)(void) = ^{
        id current = YTKACESend(textNode, @selector(attributedText));
        if (![current isKindOfClass:NSAttributedString.class]) return;
        NSAttributedString *existing = current;
        if ([existing.string isEqualToString:title]) return;
        NSDictionary *attributes = existing.length != 0
            ? [existing attributesAtIndex:0 effectiveRange:NULL] : nil;
        NSAttributedString *replacement =
            [[NSAttributedString alloc] initWithString:title attributes:attributes];
        SEL setter = NSSelectorFromString(@"setAttributedText:");
        if (![textNode respondsToSelector:setter]) return;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(textNode, setter, replacement);
        } @catch (__unused NSException *exception) {
        }
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

static void YTKACEApplyTitleToCell(id root, NSString *videoID) {
    if (root == nil || videoID.length == 0 || !YTKACEReplacingTitles()) return;

    NSString *title = YTKACEStoredTitle(videoID);
    if (title.length == 0) {
        os_unfair_lock_lock(&YTKACELock);
        [YTKACEPendingCells setObject:root forKey:videoID];
        os_unfair_lock_unlock(&YTKACELock);
        return;
    }

    NSMutableArray *nodes = [NSMutableArray array];
    YTKACECollectTextNodes(root, 0, nodes);
    if (nodes.count < 2) return;
    id candidate = nodes[nodes.count - 2];
    NSString *text = YTKACENodeText(candidate);
    if ([text isEqualToString:title]) return;
    if (YTKACELooksLikeDuration(text)) return;
    YTKACEWriteTitle(candidate, title);
}

static void YTKACEApplyPendingTitle(NSString *videoID) {
    if (videoID.length == 0 || !YTKACEReplacingTitles()) return;
    os_unfair_lock_lock(&YTKACELock);
    id root = [YTKACEPendingCells objectForKey:videoID];
    os_unfair_lock_unlock(&YTKACELock);
    if (root != nil) YTKACEApplyTitleToCell(root, videoID);
}

static BOOL YTKACEClaimSlotLocked(void) {
    if (YTKACEActiveRequests >= YTKACEMaxConcurrent) return NO;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - YTKACEWindowStart >= 60.0) {
        YTKACEWindowStart = now;
        YTKACEWindowCount = 0;
    }
    if (YTKACEWindowCount >= YTKACERequestsPerMinute) return NO;
    YTKACEWindowCount++;
    YTKACEActiveRequests++;
    return YES;
}

static void YTKACEFetchBranding(NSString *videoID, id node) {
    NSString *address = [NSString stringWithFormat:
        @"https://sponsor.ajay.app/api/branding?videoID=%@", videoID];
    NSURL *URL = [NSURL URLWithString:address];
    if (URL == nil) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.timeoutInterval = 15.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    __weak id weakNode = node;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        if (error != nil) {
            os_unfair_lock_lock(&YTKACELock);
            [YTKACEInFlight removeObject:videoID];
            if (YTKACEActiveRequests > 0) YTKACEActiveRequests--;
            os_unfair_lock_unlock(&YTKACELock);
            YTKACEPumpQueue();
            return;
        }
        id json = (http.statusCode == 200 && data.length != 0)
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class]) {
            YTKACEStoreBranding(videoID, nil, nil);
            return;
        }
        NSDictionary *payload = json;
        NSArray *titles = [payload[@"titles"] isKindOfClass:NSArray.class]
            ? payload[@"titles"] : @[];
        NSArray *thumbnails = [payload[@"thumbnails"] isKindOfClass:NSArray.class]
            ? payload[@"thumbnails"] : @[];

        NSString *useTitle = nil;
        NSDictionary *bestTitle = titles.firstObject;
        if ([bestTitle isKindOfClass:NSDictionary.class]) {
            BOOL trusted = [bestTitle[@"locked"] boolValue] ||
                [bestTitle[@"votes"] integerValue] >= 0;
            id text = bestTitle[@"title"];
            if (trusted && ![bestTitle[@"original"] boolValue] &&
                [text isKindOfClass:NSString.class]) {
                NSString *cleaned = [(NSString *)text
                    stringByReplacingOccurrencesOfString:@">" withString:@""];
                cleaned = [cleaned stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (cleaned.length != 0) useTitle = cleaned;
            }
        }

        NSNumber *useTimestamp = nil;
        NSDictionary *bestThumb = thumbnails.firstObject;
        if ([bestThumb isKindOfClass:NSDictionary.class]) {
            BOOL trusted = [bestThumb[@"locked"] boolValue] ||
                [bestThumb[@"votes"] integerValue] >= 0;
            id timestamp = bestThumb[@"timestamp"];
            if (trusted && ![bestThumb[@"original"] boolValue] &&
                [timestamp isKindOfClass:NSNumber.class]) {
                useTimestamp = timestamp;
            }
        }

        YTKACEStoreBranding(videoID, useTimestamp, useTitle);
        if (useTitle.length != 0) YTKACEApplyPendingTitle(videoID);
        if (useTimestamp != nil) {
            YTKACEFetchThumbnail(videoID, useTimestamp.doubleValue, weakNode);
        }
    }] resume];
}

static void YTKACEPumpQueue(void) {
    while (YES) {
        NSString *videoID = nil;
        id node = nil;
        os_unfair_lock_lock(&YTKACELock);
        while (YTKACEPendingIDs.count != 0 && videoID == nil) {
            NSString *candidate = YTKACEPendingIDs.firstObject;
            [YTKACEPendingIDs removeObjectAtIndex:0];
            if (YTKACEFreshEntryLocked(candidate) != nil ||
                [YTKACEInFlight containsObject:candidate]) {
                [YTKACEPendingNodes removeObjectForKey:candidate];
                continue;
            }
            if (!YTKACEClaimSlotLocked()) {
                [YTKACEPendingIDs insertObject:candidate atIndex:0];
                break;
            }
            [YTKACEInFlight addObject:candidate];
            node = [YTKACEPendingNodes objectForKey:candidate];
            [YTKACEPendingNodes removeObjectForKey:candidate];
            videoID = candidate;
        }
        os_unfair_lock_unlock(&YTKACELock);
        if (videoID == nil) return;
        YTKACEFetchBranding(videoID, node);
    }
}

static void YTKACEEnqueueLookup(NSString *videoID, id node) {
    os_unfair_lock_lock(&YTKACELock);
    BOOL known = YTKACEFreshEntryLocked(videoID) != nil ||
        [YTKACEInFlight containsObject:videoID] ||
        [YTKACEPendingIDs containsObject:videoID];
    if (!known) {
        if (YTKACEPendingIDs.count >= YTKACEPendingLimit) {
            [YTKACEPendingIDs removeObjectAtIndex:0];
        }
        [YTKACEPendingIDs addObject:videoID];
        if (node != nil) [YTKACEPendingNodes setObject:node forKey:videoID];
    }
    os_unfair_lock_unlock(&YTKACELock);
    if (!known) YTKACEPumpQueue();
}

static void YTKACEConsiderVideo(id node, NSString *videoID) {
    BOOL replacing = YTKACEReplacingThumbs();
    os_unfair_lock_lock(&YTKACELock);
    YTKACELoadStore();
    UIImage *ready = replacing ? [YTKACEImageCache objectForKey:videoID] : nil;
    NSDictionary *known = YTKACEFreshEntryLocked(videoID);
    os_unfair_lock_unlock(&YTKACELock);

    if (ready != nil) {
        YTKACEApplyImage(node, videoID, ready);
        return;
    }
    if (known != nil) {
        NSNumber *timestamp = known[@"t"];
        if (replacing && [timestamp isKindOfClass:NSNumber.class]) {
            YTKACEFetchThumbnail(videoID, timestamp.doubleValue, node);
        }
        return;
    }
    YTKACEEnqueueLookup(videoID, node);
}

static void YTKACENoteImage(id receiver, id URL) {
    NSString *videoID = YTKACEVideoIDFromURL(YTKACEURLString(URL));
    if (videoID.length == 0) return;

    objc_setAssociatedObject(receiver, YTKACENodeVideoIDKey, videoID,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    id root = YTKACECellRoot(receiver);
    if (root != nil) {
        objc_setAssociatedObject(root, YTKACECellVideoIDKey, videoID,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    if (YTKACEAnyFeatureOn()) {
        YTKACEConsiderVideo(receiver, videoID);
        if (root != nil) YTKACEApplyTitleToCell(root, videoID);
    }
    YTKACESponsorNoteThumbnail(receiver, videoID);
}

static id YTKACEDownloadImage(id receiver, SEL selector, id URL, BOOL shouldRetry,
                              id callbackQueue, id progress, id completion) {
    if (YTKACEAnyFeatureOn() || YTKACESponsorFullVideoLabelsEnabled()) {
        YTKACENoteImage(receiver, URL);
    }
    if (OriginalDownloadImage == NULL) return nil;
    return ((id (*)(id, SEL, id, BOOL, id, id, id))OriginalDownloadImage)(
        receiver, selector, URL, shouldRetry, callbackQueue, progress, completion);
}

static void YTKACECachedImage(id receiver, SEL selector, id URL,
                              id callbackQueue, id completion) {
    if (YTKACEAnyFeatureOn() || YTKACESponsorFullVideoLabelsEnabled()) {
        YTKACENoteImage(receiver, URL);
    }
    if (OriginalCachedImage == NULL) return;
    ((void (*)(id, SEL, id, id, id))OriginalCachedImage)(
        receiver, selector, URL, callbackQueue, completion);
}

static void YTKACEApplyProperties(id receiver, SEL selector) {
    if (OriginalApplyProperties != NULL) {
        ((void (*)(id, SEL))OriginalApplyProperties)(receiver, selector);
    }
    if (!YTKACEReplacingTitles()) return;
    id root = YTKACECellRoot(receiver);
    if (root == nil) return;
    id stored = objc_getAssociatedObject(root, YTKACECellVideoIDKey);
    if (![stored isKindOfClass:NSString.class]) return;
    if (YTKACEStoredTitle(stored).length == 0) return;
    YTKACEApplyTitleToCell(root, stored);
}

void YTKACEDeArrowClearCache(void) {
    os_unfair_lock_lock(&YTKACELock);
    [YTKACEStore removeAllObjects];
    [YTKACEImageCache removeAllObjects];
    [YTKACEPendingIDs removeAllObjects];
    [YTKACEPendingCells removeAllObjects];
    os_unfair_lock_unlock(&YTKACELock);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:YTKACEBrandingStoreKey];
}

void YTKACEInstallDeArrow(void) {
    os_unfair_lock_lock(&YTKACELock);
    YTKACELoadStore();
    os_unfair_lock_unlock(&YTKACELock);

    YTKACEInstallInstanceHook(@"ELMImageNode",
        @"downloadImageWithURL:shouldRetry:callbackQueue:downloadProgress:completion:",
        (IMP)YTKACEDownloadImage, &OriginalDownloadImage);
    YTKACEInstallInstanceHook(@"ELMImageNode",
        @"cachedImageWithURL:callbackQueue:completion:",
        (IMP)YTKACECachedImage, &OriginalCachedImage);
    YTKACEInstallInstanceHook(@"ELMTextNode",
        @"controllerDidApplyProperties", (IMP)YTKACEApplyProperties,
        &OriginalApplyProperties);

    [NSNotificationCenter.defaultCenter
        addObserverForName:YTKACEPreferencesDidChangeNotification
                    object:nil queue:nil
                usingBlock:^(__unused NSNotification *note) {
        atomic_store(&YTKACEModeCache, -1);
        atomic_store(&YTKACETitlesCache, -1);
    }];
}
