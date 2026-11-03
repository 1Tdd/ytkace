#import "PostImages.h"

static BOOL YTKACEPostImageHost(NSString *host) {
    host = host.lowercaseString;
    return [host isEqualToString:@"ggpht.com"] || [host hasSuffix:@".ggpht.com"] ||
        [host isEqualToString:@"googleusercontent.com"] || [host hasSuffix:@".googleusercontent.com"];
}

NSURL *YTKACEPostOriginalImageURL(NSURL *URL) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (!YTKACEPostImageHost(parts.host)) return URL;
    NSRange options = [parts.path rangeOfString:@"=" options:NSBackwardsSearch];
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
        @"\\burl\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\""
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
