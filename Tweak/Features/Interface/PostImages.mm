#import "PostImages.h"

static BOOL YTKACEPostImageHost(NSString *host) {
    host = host.lowercaseString;
    return [host isEqualToString:@"ggpht.com"] || [host hasSuffix:@".ggpht.com"] ||
        [host isEqualToString:@"googleusercontent.com"] || [host hasSuffix:@".googleusercontent.com"];
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
    return nil;
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
