#import "MediaChapterSharing.h"
#include "MediaChapters.h"
#include "../SponsorBlock/SponsorTimeline.h"
#import "../../Runtime/Localization.h"

NSString *YTKACEChapterTextFromChapters(NSArray<NSDictionary *> *chapters) {
    std::vector<YTKACEMediaChapters::Chapter> entries;
    for (id chapter in chapters) {
        YTKACEMedia::Interval range;
        if (!YTKACEReadSponsorInterval(chapter, range)) continue;
        NSString *title = chapter[@"title"];
        if (![title isKindOfClass:NSString.class]) continue;
        entries.push_back({title.UTF8String ?: "", range.start, range.end});
    }
    const auto text = YTKACEMediaChapters::caption(entries);
    return [NSString stringWithUTF8String:text.c_str()] ?: @"";
}

void YTKACEChapterTextForMediaURL(NSURL *URL, void (^completion)(NSString *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::vector<YTKACEMediaChapters::Chapter> chapters;
        std::string message, text;
        if (URL.isFileURL && YTKACEMediaChapters::read(URL.fileSystemRepresentation, chapters, message) >= 0)
            text = YTKACEMediaChapters::caption(chapters);
        NSString *caption = [NSString stringWithUTF8String:text.c_str()] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(caption); });
    });
}

void YTKACEPrepareMediaShareItems(NSArray<NSURL *> *URLs, UIViewController *presenter, void (^completion)(NSArray *)) {
    NSArray<NSURL *> *files = [URLs copy];
    // Separate files have separate timelines; never attach one caption to a batch.
    if (files.count != 1) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(files); });
        return;
    }
    YTKACEChapterTextForMediaURL(files.firstObject, ^(NSString *text) {
        if (text.length == 0) { completion(files); return; }
        // Separate text attachments can become separate messages. Let the user
        // copy the final timeline for the destination's editable media caption.
        UIAlertController *prompt = [UIAlertController alertControllerWithTitle:YTKACELocalized(@"Share chapters")
            message:YTKACELocalized(@"Some players use caption text for chapters. Copy the chapter list, then paste it into the video or audio caption before sending.")
            preferredStyle:UIAlertControllerStyleAlert];
        __weak UIAlertController *weakPrompt = prompt;
        void (^share)(BOOL) = ^(BOOL copy) {
            if (copy) UIPasteboard.generalPasteboard.string = text;
            [weakPrompt dismissViewControllerAnimated:YES completion:^{ completion(files); }];
        };
        [prompt addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Copy chapters and share")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { share(YES); }]];
        [prompt addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Share file only")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { share(NO); }]];
        [prompt addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
            style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:prompt animated:YES completion:nil];
    });
}
