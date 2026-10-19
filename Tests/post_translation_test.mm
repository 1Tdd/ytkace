#import <Foundation/Foundation.h>
#import "../Tweak/Features/Interface/PostTranslation.h"
#include <cassert>

static NSData *JSON(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }

int main() {
    @autoreleasepool {
        assert(YTKACETranslationChunks(@"", 5).count == 0);
        assert(YTKACETranslationChunks(@"text", 0).count == 0);
        NSString *source = @"First paragraph.\n\nSecond paragraph with punctuation & symbols + % and emoji 🇮🇹 👨‍👩‍👧‍👦. Fine.";
        NSArray *chunks = YTKACETranslationChunks(source, 18);
        assert(chunks.count > 1);
        assert([[chunks componentsJoinedByString:@""] isEqual:source]);
        for (NSString *chunk in chunks) {
            assert(chunk.length > 0);
            assert([chunk dataUsingEncoding:NSUTF8StringEncoding] != nil);
        }
        NSString *longWord = [@"👨‍👩‍👧‍👦" stringByPaddingToLength:5000 withString:@"漢字é🙂" startingAtIndex:0];
        assert([[YTKACETranslationChunks(longWord, 1000) componentsJoinedByString:@""] isEqual:longWord]);
        NSArray *response = @[@[@[@"Ciao ", @"Hello "], @[@"mondo!", @"world!"]], NSNull.null, @"en"];
        NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:NULL];
        assert([YTKACETranslationResponse(data) isEqual:@"Ciao mondo!"]);
        assert(YTKACETranslationResponse(JSON(@"null")) == nil);
        assert(YTKACETranslationResponse(JSON(@"{}")) == nil);
        assert(YTKACETranslationResponse(JSON(@"[]")) == nil);
        assert(YTKACETranslationResponse(JSON(@"[[]]")) == nil);
        assert(YTKACETranslationResponse(JSON(@"[[[null]]]")) == nil);
        assert(YTKACETranslationResponse(JSON(@"[[[123]]]")) == nil);
        assert(YTKACETranslationResponse(JSON(@"[[42]]")) == nil);
        assert(YTKACETranslationResponse(JSON(@"broken JSON")) == nil);
        assert(YTKACETranslationResponse(nil) == nil);
        NSLog(@"Post translation parsing and Unicode chunk tests passed");
    }
    return 0;
}
