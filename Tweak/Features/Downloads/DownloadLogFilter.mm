#import "DownloadLogFilter.h"

// Entries look like "2026-11-05 08:22:03 +0000 [tag] message". A line without that
// start continues the entry above it.
static NSString *YTKACELogTag(NSString *line) {
    if (line.length < 20 || [line characterAtIndex:0] < '0' || [line characterAtIndex:0] > '9') return nil;
    NSRange open = [line rangeOfString:@" ["];
    if (open.location == NSNotFound || open.location > 40) return nil;
    NSUInteger start = NSMaxRange(open);
    NSRange close = [line rangeOfString:@"]" options:0 range:NSMakeRange(start, line.length - start)];
    if (close.location == NSNotFound) return nil;
    return [line substringWithRange:NSMakeRange(start, close.location - start)];
}

// Each download job writes under its own UUID.
static BOOL YTKACELogTagIsJob(NSString *tag) {
    if (tag.length != 36) return NO;
    return [tag characterAtIndex:8] == '-' && [tag characterAtIndex:13] == '-' &&
        [tag characterAtIndex:18] == '-' && [tag characterAtIndex:23] == '-';
}

static BOOL YTKACELogEntryIsError(NSString *entry) {
    NSString *text = entry.lowercaseString;
    for (NSString *harmless in @[@"error=none", @"error=(null)", @"error=0", @"failed=0", @"retries=0"]) {
        text = [text stringByReplacingOccurrencesOfString:harmless withString:@""];
    }
    for (NSString *marker in @[@"error", @"fail", @"mismatch", @"rejected", @"could not",
                               @"retry", @"status=4", @"status=5"]) {
        if ([text rangeOfString:marker].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL YTKACELogEntryMatches(NSString *entry, NSString *tag, YTKACELogFilter filter) {
    NSArray<NSString *> *tags = nil;
    switch (filter) {
        case YTKACELogFilterAll:
            return YES;
        case YTKACELogFilterErrors:
            return YTKACELogEntryIsError(entry);
        case YTKACELogFilterDownloads:
            if (YTKACELogTagIsJob(tag)) return YES;
            tags = @[@"download", @"resolve", @"subs", @"merge", @"photos", @"chapters", @"convert",
                     @"playlist", @"caption", @"hls", @"direct", @"save", @"quality", @"tv", @"library",
                     @"nsolver", @"token", @"reload", @"progress", @"prepare", @"cache", @"backup"];
            break;
        case YTKACELogFilterPosts:
            tags = @[@"posts"];
            break;
        case YTKACELogFilterFeed:
            tags = @[@"feed", @"shorts", @"home", @"aislist", @"autoplay"];
            break;
        case YTKACELogFilterInterface:
            tags = @[@"tabbar", @"glass", @"haptics"];
            break;
        case YTKACELogFilterStartup:
            tags = @[@"hooks", @"debug", @"spoof", @"fix"];
            break;
    }
    return tag != nil && [tags containsObject:tag];
}

NSString *YTKACEFilteredLog(NSString *contents, YTKACELogFilter filter, NSString *query) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in [query ?: @"" componentsSeparatedByCharactersInSet:
                               NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (word.length != 0) [words addObject:word];
    }
    if (filter == YTKACELogFilterAll && words.count == 0) return contents;

    NSMutableString *result = [NSMutableString string];
    NSMutableString *entry = nil;
    NSString *tag = nil;
    NSArray<NSString *> *lines = [contents componentsSeparatedByString:@"\n"];
    for (NSUInteger index = 0; index <= lines.count; index++) {
        NSString *line = nil;
        if (index < lines.count) line = [lines objectAtIndex:index];
        NSString *lineTag = line != nil ? YTKACELogTag(line) : nil;
        if (line != nil && lineTag == nil && entry != nil) {
            if (line.length != 0) [entry appendFormat:@"\n%@", line];
            continue;
        }
        if (entry != nil && YTKACELogEntryMatches(entry, tag, filter)) {
            BOOL matches = YES;
            for (NSString *word in words) {
                if ([entry rangeOfString:word options:NSCaseInsensitiveSearch].location == NSNotFound) {
                    matches = NO;
                    break;
                }
            }
            if (matches) [result appendFormat:@"%@\n", entry];
        }
        entry = line != nil ? [line mutableCopy] : nil;
        tag = lineTag;
    }
    return result;
}
