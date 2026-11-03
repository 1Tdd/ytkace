#import <Foundation/Foundation.h>
#import "../Tweak/Features/Interface/PostImages.h"
#include <cstdlib>
#include <cstdio>

static void check(bool condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); std::exit(1); }
}

int main() {
    @autoreleasepool {
        NSString *proto = @"image { sources { url: \"https://yt3.ggpht.com/first=s320\" } "
            "sources { url: \"https://yt3.ggpht.com/first=s1080\" } } "
            "image { sources { URL: \"https://yt3.ggpht.com/second=s640\" } } "
            "image { sources { url: \"//lh3.googleusercontent.com/third=s1280\" } }";
        NSArray *URLs = YTKACEPostImageURLsInProto(proto);
        check(URLs.count == 3, "Collect every carousel image without counting size variants twice");
        check([[[URLs objectAtIndex:0] absoluteString] isEqual:@"https://yt3.ggpht.com/first=s320"], "Preserve fallback URL");
        check([[[URLs objectAtIndex:1] path] hasPrefix:@"/second"], "Preserve carousel order");
        check([[YTKACEPostOriginalImageURL([URLs objectAtIndex:0]) absoluteString] isEqual:@"https://yt3.ggpht.com/first=s0"], "Request original resolution");

        NSURL *pressed = [NSURL URLWithString:@"https://yt3.ggpht.com/second=s720?variant=2"];
        check(YTKACEUniquePostImageURLs([URLs arrayByAddingObject:pressed]).count == 3, "Pressed image must not duplicate the carousel entry");
        NSArray *invalid = YTKACEPostImageURLsInProto(@"url: \"file:///tmp/image.jpg\" url: \"https://ggpht.com.evil.invalid/image\" url: \"https://example.com/image\" url: \"ftp://yt3.ggpht.com/image\"");
        check(invalid.count == 0, "Only remote image hosts in an attachment may be parsed");
        check(YTKACEPostImageURLsInProto(@"text: \"https://yt3.ggpht.com/not-an-image-field\"").count == 0, "Ignore URLs mentioned in text");
        check(YTKACEPostImageURLsInProto(@"url: \"https://yt3.ggpht.com/broken").count == 0, "Reject unterminated URLs");
        check(YTKACEPostImageURLsInProto([@"x" stringByPaddingToLength:1024 * 1024 + 1 withString:@"x" startingAtIndex:0]).count == 0, "Bound proto parsing");

        NSArray *escaped = YTKACEPostImageURLsInProto(@"url: \"https:\\/\\/yt3.ggpht.com/photo=s720?x=1\\u0026y=2\"");
        check(escaped.count == 1 && [[[escaped objectAtIndex:0] query] isEqual:@"x=1&y=2"], "Decode escaped URLs");
        NSURL *external = [NSURL URLWithString:@"https://example.com/photo?size=200"];
        check([YTKACEPostOriginalImageURL(external) isEqual:external], "Do not alter unrelated hosts");
        puts("Community image collection, deduplication, ordering, original URLs and malformed input passed.");
    }
    return 0;
}
