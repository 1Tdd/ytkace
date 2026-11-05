#import "../Tweak/Features/Downloads/DownloadLogFilter.h"

#import <stdio.h>

static int failures = 0;

static void expect(NSString *name, NSString *actual, NSString *wanted) {
    if ([actual isEqualToString:wanted]) return;
    failures++;
    printf("FAIL %s\n  got: %s\n  want: %s\n", name.UTF8String, actual.UTF8String, wanted.UTF8String);
}

int main(void) {
    @autoreleasepool {
        NSString *job = @"2026-11-05 08:23:52 +0000 [5DB37226-F118-4E61-832C-81A510673993] response 0 status=200 error=none\n";
        NSString *merge = @"2026-11-05 08:24:14 +0000 [merge] packet copy error=none\n";
        NSString *post = @"2026-11-05 08:22:22 +0000 [posts] post image list status=404 images=0\n";
        NSString *glass = @"2026-11-05 08:22:06 +0000 [glass] YTColdConfig original=0\n";
        NSString *hooks = @"2026-11-05 08:22:07 +0000 [hooks] installed=572 failed=62\n";
        NSString *multi = @"2026-11-05 08:22:08 +0000 [feed] first line\nsecond line\n";
        NSString *log = [@[job, merge, post, glass, hooks, multi] componentsJoinedByString:@""];

        expect(@"all returns everything", YTKACEFilteredLog(log, YTKACELogFilterAll, nil), log);
        expect(@"downloads keeps jobs and their helpers",
               YTKACEFilteredLog(log, YTKACELogFilterDownloads, nil), [job stringByAppendingString:merge]);
        expect(@"posts", YTKACEFilteredLog(log, YTKACELogFilterPosts, @""), post);
        expect(@"interface", YTKACEFilteredLog(log, YTKACELogFilterInterface, nil), glass);
        expect(@"startup", YTKACEFilteredLog(log, YTKACELogFilterStartup, nil), hooks);
        expect(@"a continuation stays with its entry", YTKACEFilteredLog(log, YTKACELogFilterFeed, nil), multi);
        expect(@"errors skip error=none and failed=0",
               YTKACEFilteredLog([log stringByAppendingString:
                   @"2026-11-05 08:30:00 +0000 [hooks] installed=572 failed=0\n"], YTKACELogFilterErrors, nil),
               [post stringByAppendingString:hooks]);
        expect(@"every word must match, in any case",
               YTKACEFilteredLog(log, YTKACELogFilterAll, @"IMAGES post"), post);
        expect(@"the query narrows the category",
               YTKACEFilteredLog(log, YTKACELogFilterDownloads, @"packet"), merge);
        expect(@"no match is empty", YTKACEFilteredLog(log, YTKACELogFilterPosts, @"packet"), @"");
        expect(@"text matches a continuation line",
               YTKACEFilteredLog(log, YTKACELogFilterAll, @"second"), multi);
    }
    if (failures != 0) return 1;
    printf("log filter test passed\n");
    return 0;
}
