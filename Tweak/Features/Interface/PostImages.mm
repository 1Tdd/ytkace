#import "PostImages.h"
#include <string.h>

static BOOL YTKACEPostImageHost(NSString *host) {
    host = host.lowercaseString;
    return [host isEqualToString:@"ggpht.com"] || [host hasSuffix:@".ggpht.com"] ||
        [host isEqualToString:@"googleusercontent.com"] || [host hasSuffix:@".googleusercontent.com"];
}

BOOL YTKACEIsPostImageURL(NSURL *URL) {
    return YTKACEPostImageHost(URL.host);
}

NSURL *YTKACEPostOriginalImageURL(NSURL *URL) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (!YTKACEPostImageHost(parts.host)) return URL;
    // Crop options themselves contain '=' (e.g. '=s1080-c-fcrop64=1,...').
    NSRange options = [parts.path rangeOfString:@"="];
    if (options.location != NSNotFound)
        parts.path = [[parts.path substringToIndex:options.location] stringByAppendingString:@"=s0"];
    return parts.URL ?: URL;
}

NSArray<NSURL *> *YTKACEUniquePostImageURLs(NSArray<NSURL *> *URLs) {
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id value in URLs) {
        if (![value isKindOfClass:NSURL.class]) continue;
        NSURL *URL = value;
        if (![@[@"http", @"https"] containsObject:URL.scheme.lowercaseString] || !URL.host.length) continue;
        NSURLComponents *identity = [NSURLComponents componentsWithURL:YTKACEPostOriginalImageURL(URL) resolvingAgainstBaseURL:NO];
        identity.fragment = nil;
        if (YTKACEPostImageHost(identity.host)) { identity.query = nil; identity.scheme = @"https"; }
        NSString *key = identity.string;
        if (!key || [seen containsObject:key]) continue;
        [seen addObject:key];
        [result addObject:URL]; // Preserve a working fallback if the original-size URL fails.
        if (result.count == 64) break;
    }
    return result;
}

NSArray<NSURL *> *YTKACEPostImageURLsInProto(NSString *proto) {
    if (![proto isKindOfClass:NSString.class] || proto.length > 1024 * 1024) return @[];
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:
        @"\\b(?:url|image_url|string_value)\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\""
        options:NSRegularExpressionCaseInsensitive error:NULL];
    NSMutableArray *URLs = [NSMutableArray array];
    for (NSTextCheckingResult *match in [expression matchesInString:proto options:0 range:NSMakeRange(0, proto.length)]) {
        NSRange range = [match rangeAtIndex:1];
        NSString *quoted = [proto substringWithRange:NSMakeRange(range.location - 1, range.length + 2)];
        NSString *wrapped = [NSString stringWithFormat:@"[%@]", quoted];
        id parsed = [NSJSONSerialization JSONObjectWithData:[wrapped dataUsingEncoding:NSUTF8StringEncoding]
            options:0 error:NULL];
        id value = [parsed isKindOfClass:NSArray.class] && [parsed count] == 1 ? [parsed objectAtIndex:0] : nil;
        if (![value isKindOfClass:NSString.class]) continue;
        if ([value hasPrefix:@"//"]) value = [@"https:" stringByAppendingString:value];
        NSURL *URL = [NSURL URLWithString:value];
        if (URL && YTKACEPostImageHost(URL.host)) [URLs addObject:URL];
    }
    return YTKACEUniquePostImageURLs(URLs);
}

NSString *YTKACEPostIDInText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length > 1024 * 1024) return nil;
    for (NSString *pattern in @[
        @"(?:youtube\\.com/post/|/post/)(Ug[A-Za-z0-9_-]{20,100})",
        @"(?:post_?id|backstage_?post_?id)\\s*[\\\"]?\\s*[:=]\\s*[\\\"](Ug[A-Za-z0-9_-]{20,100})[\\\"]"
    ]) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
            options:NSRegularExpressionCaseInsensitive error:NULL];
        NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (match) return [text substringWithRange:[match rangeAtIndex:1]];
    }
    // Bound ELM command data can expose protobuf fields by number instead of
    // name. Accept a standalone post ID only when the component is unambiguous.
    NSRegularExpression *rawID = [NSRegularExpression regularExpressionWithPattern:
        @"\"(Ug[A-Za-z0-9_-]{26,60})\"" options:0 error:NULL];
    NSMutableSet *IDs = [NSMutableSet set];
    for (NSTextCheckingResult *match in [rawID matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        [IDs addObject:[text substringWithRange:[match rangeAtIndex:1]]];
    }
    if (IDs.count == 1) return IDs.anyObject;
    if (IDs.count > 1) return nil;
    // Commands embedded as serialized bytes print the ID unquoted, directly after
    // its length prefix and before the next field tag, so it has no end delimiter.
    NSRegularExpression *serializedID = [NSRegularExpression regularExpressionWithPattern:
        @"(?<![A-Za-z0-9_-])Ugkx[A-Za-z0-9_-]{32}" options:0 error:NULL];
    for (NSTextCheckingResult *match in [serializedID matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        [IDs addObject:[text substringWithRange:match.range]];
    }
    return IDs.count == 1 ? IDs.anyObject : nil;
}

static const NSUInteger YTKACEElementDataLimit = 1024 * 1024;

BOOL YTKACEElementDataHasPostImage(NSData *data) {
    if (![data isKindOfClass:NSData.class] || !data.length || data.length > YTKACEElementDataLimit) return NO;
    NSData *marker = [NSData dataWithBytes:"-nd-v1" length:6];
    return [data rangeOfData:marker options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

// A shelf cell can hold several posts, whose images must not be mixed together.
static NSSet<NSString *> *YTKACEPostIDsInElementData(NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    NSMutableSet *IDs = [NSMutableSet set];
    if (!text) return IDs;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:
        @"(?<![A-Za-z0-9_-])Ugkx[A-Za-z0-9_-]{32}" options:0 error:NULL];
    for (NSTextCheckingResult *match in [expression matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        [IDs addObject:[text substringWithRange:match.range]];
    }
    return IDs;
}

NSString *YTKACEPostIDInElementData(NSData *data) {
    if (![data isKindOfClass:NSData.class] || !data.length || data.length > YTKACEElementDataLimit) return nil;
    if (YTKACEPostIDsInElementData(data).count > 1) return nil;
    return YTKACEPostIDInText([[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding]);
}

// Protobuf strings have no terminator, so the end comes from the varint length before them.
static NSUInteger YTKACEElementStringEnd(const uint8_t *bytes, NSUInteger count, NSUInteger start) {
    NSUInteger length = 0;
    if (start >= 2 && bytes[start - 1] < 0x80 && bytes[start - 2] >= 0x80) {
        length = (bytes[start - 2] & 0x7F) | ((NSUInteger)bytes[start - 1] << 7);
    } else if (start >= 1 && bytes[start - 1] < 0x80) {
        length = bytes[start - 1];
    }
    BOOL prefixed = length >= 8 && start + length <= count;
    NSUInteger limit = prefixed ? start + length : count;
    NSUInteger end = start;
    while (end < limit && bytes[end] > 0x20 && bytes[end] < 0x7F) end++;
    return end;
}

NSArray<NSURL *> *YTKACEPostImageURLsInElementData(NSData *data) {
    if (!YTKACEElementDataHasPostImage(data) || YTKACEPostIDsInElementData(data).count > 1) return @[];
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger count = data.length, cursor = 0;
    NSData *slashes = [NSData dataWithBytes:"//" length:2];
    NSMutableArray *URLs = [NSMutableArray array];
    while (cursor < count) {
        NSRange found = [data rangeOfData:slashes options:0 range:NSMakeRange(cursor, count - cursor)];
        if (found.location == NSNotFound) break;
        NSUInteger start = found.location;
        if (start >= 6 && memcmp(bytes + start - 6, "https:", 6) == 0) start -= 6;
        else if (start >= 5 && memcmp(bytes + start - 5, "http:", 5) == 0) start -= 5;
        NSUInteger end = YTKACEElementStringEnd(bytes, count, start);
        cursor = MAX(end, NSMaxRange(found));
        NSString *value = [[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSASCIIStringEncoding];
        if ([value hasPrefix:@"//"]) value = [@"https:" stringByAppendingString:value];
        NSURL *URL = value ? [NSURL URLWithString:value] : nil;
        // The suffix separates post images from the author avatar and custom emoji.
        if (URL && YTKACEPostImageHost(URL.host) && [URL.path containsString:@"-nd-v1"]) [URLs addObject:URL];
    }
    return YTKACEUniquePostImageURLs(URLs);
}

NSArray<NSData *> *YTKACEElementDataMentioningImage(NSArray<NSData *> *candidates, NSURL *image) {
    if (!YTKACEPostImageHost(image.host)) return @[];
    // The part up to the first '=' identifies the image; the rest only picks its size.
    NSString *path = image.path;
    NSRange options = [path rangeOfString:@"="];
    if (options.location != NSNotFound) path = [path substringToIndex:NSMaxRange(options)];
    NSData *identity = [path dataUsingEncoding:NSASCIIStringEncoding];
    if (identity.length < 6) return @[];
    NSMutableArray *matches = [NSMutableArray array];
    for (NSData *data in candidates) {
        if ([data rangeOfData:identity options:0 range:NSMakeRange(0, data.length)].location != NSNotFound) [matches addObject:data];
    }
    return matches;
}

static id YTKACEPostPageData(NSString *page) {
    if (![page isKindOfClass:NSString.class] || page.length > 8 * 1024 * 1024) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
        @"(?:\\bytInitialData|window\\[\\\"ytInitialData\\\"\\])\\s*=\\s*\\{"
        options:0 error:NULL];
    for (NSTextCheckingResult *match in [regex matchesInString:page options:0 range:NSMakeRange(0, page.length)]) {
        NSUInteger start = NSMaxRange(match.range) - 1, depth = 0;
        BOOL quoted = NO, escaped = NO;
        for (NSUInteger index = start; index < page.length; index++) {
            unichar c = [page characterAtIndex:index];
            if (quoted) {
                if (escaped) escaped = NO;
                else if (c == '\\') escaped = YES;
                else if (c == '"') quoted = NO;
                continue;
            }
            if (c == '"') quoted = YES;
            else if (c == '{') depth++;
            else if (c == '}' && --depth == 0) {
                NSData *data = [[page substringWithRange:NSMakeRange(start, index - start + 1)] dataUsingEncoding:NSUTF8StringEncoding];
                id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if (result) return result;
                break;
            }
        }
    }
    return nil;
}

NSArray<NSURL *> *YTKACEPostImageURLsInPage(NSString *page, NSString *postID) {
    id root = YTKACEPostPageData(page);
    if (!root || !postID.length) return @[];
    NSMutableArray *pending = [NSMutableArray arrayWithObject:root];
    for (NSUInteger index = 0; index < pending.count && index < 20000; index++) {
        id item = [pending objectAtIndex:index];
        if ([item isKindOfClass:NSDictionary.class]) {
            NSDictionary *post = item;
            if ([[post objectForKey:@"postId"] isEqual:postID]) {
                id attachment = [post objectForKey:@"backstageAttachment"];
                if ([attachment isKindOfClass:NSDictionary.class]) {
                    id multi = [attachment objectForKey:@"postMultiImageRenderer"];
                    id images = [multi isKindOfClass:NSDictionary.class] ? [multi objectForKey:@"images"] : nil;
                    if (![images isKindOfClass:NSArray.class]) images = @[attachment];
                    NSMutableArray *URLs = [NSMutableArray array];
                    for (id entry in images) {
                        if (![entry isKindOfClass:NSDictionary.class]) continue;
                        id renderer = [entry objectForKey:@"backstageImageRenderer"];
                        id image = [renderer isKindOfClass:NSDictionary.class] ? [renderer objectForKey:@"image"] : nil;
                        id thumbnails = [image isKindOfClass:NSDictionary.class] ? [image objectForKey:@"thumbnails"] : nil;
                        if (![thumbnails isKindOfClass:NSArray.class]) continue;
                        // Prefer the largest working fallback; original URL is tried first when saving.
                        NSURL *best = nil;
                        double area = -1;
                        for (id thumbnail in thumbnails) {
                            if (![thumbnail isKindOfClass:NSDictionary.class]) continue;
                            id raw = [thumbnail objectForKey:@"url"];
                            NSURL *URL = [raw isKindOfClass:NSString.class] ? [NSURL URLWithString:raw] : nil;
                            if (!URL || !YTKACEPostImageHost(URL.host)) continue;
                            id width = [thumbnail objectForKey:@"width"], height = [thumbnail objectForKey:@"height"];
                            double size = [width respondsToSelector:@selector(doubleValue)] && [height respondsToSelector:@selector(doubleValue)]
                                ? [width doubleValue] * [height doubleValue] : 0;
                            if (size >= area) { area = size; best = URL; }
                        }
                        if (best) [URLs addObject:best];
                    }
                    NSArray *result = YTKACEUniquePostImageURLs(URLs);
                    if (result.count) return result;
                }
            }
            for (id child in [post allValues]) {
                if (pending.count >= 20000) break;
                if ([child isKindOfClass:NSDictionary.class] || [child isKindOfClass:NSArray.class]) [pending addObject:child];
            }
        } else if ([item isKindOfClass:NSArray.class]) {
            for (id child in item) {
                if (pending.count >= 20000) break;
                if ([child isKindOfClass:NSDictionary.class] || [child isKindOfClass:NSArray.class]) [pending addObject:child];
            }
        }
    }
    return @[];
}
