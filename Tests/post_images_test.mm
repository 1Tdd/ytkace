#import <Foundation/Foundation.h>
#import "../Tweak/Features/Interface/PostImages.h"
#include <cstdlib>
#include <cstdio>

static void check(bool condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); std::exit(1); }
}

int main(int argc, char **argv) {
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
        NSURL *cropped = [NSURL URLWithString:@"https://yt3.ggpht.com/photo=s288-c-fcrop64=1,00000000ffffffff-nd-v1"];
        NSURL *larger = [NSURL URLWithString:@"https://yt3.ggpht.com/photo=s1080-c-fcrop64=1,00000000ffffffff-nd-v1"];
        check([YTKACEPostOriginalImageURL(cropped).absoluteString isEqual:@"https://yt3.ggpht.com/photo=s0"], "Strip the entire crop suffix from the first equals sign");
        check(YTKACEUniquePostImageURLs(@[cropped, larger]).count == 1, "Cropped size variants are one image");
        NSString *postID = @"Ugkxl-E2JnvJtYVwWcqHBBE67gxh8WcJ8WqC";
        for (NSString *text in @[
            [@"https://youtube.com/post/" stringByAppendingString:postID],
            [NSString stringWithFormat:@"post_id: \"%@\"", postID],
            [NSString stringWithFormat:@"{\"postId\":\"%@\"}", postID]
        ]) check([YTKACEPostIDInText(text) isEqual:postID], "Find post identity in navigation URLs and bound data");
        check(YTKACEPostIDInText(@"post_id: \"../../other\"") == nil, "Reject invalid post identifiers");
        NSString *serialized = [NSString stringWithFormat:@"data: \"\\022$%@J\\005\"", postID];
        check([YTKACEPostIDInText(serialized) isEqual:postID], "Find a post ID inside serialized command bytes");
        NSString *otherID = @"UgkxoZWla5GNUdOgoW-7rWFnYZzEkOXsutA6";
        check(YTKACEPostIDInText([NSString stringWithFormat:@"a: \"\\022$%@\" b: \"\\022$%@\"", postID, otherID]) == nil,
              "Serialized bytes naming two posts are ambiguous");
        check(YTKACEIsPostImageURL([NSURL URLWithString:@"https://yt3.ggpht.com/photo=s720"]), "Accept post image hosts");
        check(!YTKACEIsPostImageURL([NSURL URLWithString:@"https://i.ytimg.com/vi/abc/hqdefault.jpg"]), "Video thumbnails are not post images");
        check(argc == 2, "Supply the real four-image post fixture");
        NSString *fixture = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]
            encoding:NSUTF8StringEncoding error:NULL];
        check(fixture.length != 0, "Read real post fixture");
        NSString *page = [NSString stringWithFormat:@"<script>var ytInitialData = %@;</script>", fixture];
        NSArray *all = YTKACEPostImageURLsInPage(page, postID);
        check(all.count == 4, "The reported post contains four images, excluding the author avatar and size variants");
        check([[[all objectAtIndex:0] absoluteString] containsString:@"EteJ4fHNV9WE_09mzPf7Ol8zMGeEAg8mDINo5GanolVRPmdyc2-Q0n3xlf9b8UeoaIlF8u0Z6AhJwQ=s1080"], "Preserve post order and highest-resolution fallback");
        check([[[all objectAtIndex:3] absoluteString] containsString:@"syVEyVeB6csleZKB0BMnP_BMRs3Iep-k1dyee3fui3h-677d_voVcT1qliyv01sm8ZsFwT1PUcZ14w"], "Include the final offscreen carousel image");
        check(YTKACEPostImageURLsInPage(page, @"UgDifferentPostIdentifier1234567890").count == 0, "Never include images belonging to another post");
        check(YTKACEPostImageURLsInPage(@"var ytInitialData = { broken", postID).count == 0, "Truncated page must not pretend to be complete");
        NSString *wrapped = [NSString stringWithFormat:@"window[\"ytInitialData\"] = %@; another = {}", fixture];
        check(YTKACEPostImageURLsInPage(wrapped, postID).count == 4, "Handle window assignment and ignore following script objects");
        NSString *escapedPage = [page stringByReplacingOccurrencesOfString:@"\"contents\":" withString:@"\"text\":\"brace } and escaped \\\" quote\",\"contents\":"];
        check(YTKACEPostImageURLsInPage(escapedPage, postID).count == 4, "Braces and escaped quotes in text cannot truncate JSON");
        puts("Community image collection, deduplication, ordering, original URLs and malformed input passed.");
    }
    return 0;
}
