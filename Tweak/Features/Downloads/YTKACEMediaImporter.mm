#import "YTKACEMediaImporter.h"
#import "MediaImportFiles.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>

static NSString * const YTKACEImportErrorDomain = @"YTKACEMediaImport";

static NSError *YTKACEImportError(NSString *message) {
    return [NSError errorWithDomain:YTKACEImportErrorDomain code:1
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"Import failed"}];
}

static NSSet<NSString *> *YTKACEImageExtensions(void) {
    return [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"heic", @"webp"]];
}

static NSSet<NSString *> *YTKACESubtitleExtensions(void) {
    return [NSSet setWithArray:@[@"srt", @"vtt"]];
}

static NSString *YTKACEMediaStem(NSString *value) {
    NSString *stem = value.lowercaseString;
    for (NSString *suffix in @[
        @"-thumbnail", @"_thumbnail", @" thumbnail",
        @"-artwork", @"_artwork", @" artwork",
        @"-thumb", @"_thumb", @" thumb"
    ]) {
        if ([stem hasSuffix:suffix]) {
            stem = [stem substringToIndex:stem.length - suffix.length];
            break;
        }
    }
    return stem;
}

static NSURL *YTKACEMatchingURL(NSArray<NSURL *> *URLs, NSString *stem,
                                BOOL allowFallback) {
    NSString *mediaStem = YTKACEMediaStem(stem);
    for (NSURL *URL in URLs) {
        NSString *candidate = YTKACEMediaStem(
            URL.lastPathComponent.stringByDeletingPathExtension);
        if ([candidate isEqualToString:mediaStem]) {
            return URL;
        }
    }
    return allowFallback && URLs.count == 1 ? URLs.firstObject : nil;
}

static NSData *YTKACEJPEGData(NSURL *URL) {
    UIImage *image = [UIImage imageWithContentsOfFile:URL.path];
    return image == nil ? nil : UIImageJPEGRepresentation(image, 0.9);
}

@implementation YTKACEMediaImporter

+ (void)importURLs:(NSArray<NSURL *> *)URLs
          category:(NSString *)category
        completion:(YTKACEMediaImportCompletion)completion {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ queue = dispatch_queue_create("com.ytkace.media-import", DISPATCH_QUEUE_SERIAL); });
    URLs = [URLs copy];
    category = [category copy];
    dispatch_async(queue, ^{
        if (![@[@"Video", @"Audio", @"Shorts"] containsObject:category]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(0, YTKACEImportError(@"Invalid media category")); });
            return;
        }
        BOOL audioCategory = [category isEqualToString:@"Audio"];
        NSSet *mediaExtensions = audioCategory
            ? YTKACEAudioExtensions() : YTKACEVideoExtensions();
        NSMutableArray<NSURL *> *media = [NSMutableArray array];
        NSMutableArray<NSURL *> *images = [NSMutableArray array];
        NSMutableArray<NSURL *> *subtitles = [NSMutableArray array];
        for (NSURL *URL in URLs) {
            NSString *extension = URL.pathExtension.lowercaseString;
            if ([mediaExtensions containsObject:extension]) [media addObject:URL];
            else if ([YTKACEImageExtensions() containsObject:extension]) [images addObject:URL];
            else if ([YTKACESubtitleExtensions() containsObject:extension]) [subtitles addObject:URL];
        }
        NSURL *downloads = [YTKACEApplicationSupportDirectory()
            URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
        NSURL *directory = [downloads URLByAppendingPathComponent:category isDirectory:YES];
        NSError *lastError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                withIntermediateDirectories:YES attributes:nil error:&lastError]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(0, lastError); });
            return;
        }
        NSUInteger imported = 0;
        for (NSURL *source in media) {
            NSError *operationError = nil;
            NSString *stem = YTKACESafeImportName(
                source.lastPathComponent.stringByDeletingPathExtension);
            // Import preserves the selected container, tracks, chapters and metadata.
            // Conversion belongs to the explicit download/export options.
            NSURL *destination = YTKACEUniqueImportURL(directory, stem, source.pathExtension.lowercaseString);
            if (!YTKACEImportCopy(source, destination, NO, &operationError)) {
                lastError = operationError;
                continue;
            }
            imported++;
            NSURL *image = YTKACEMatchingURL(images,
                source.lastPathComponent.stringByDeletingPathExtension,
                media.count == 1);
            if (image != nil) {
                NSData *artwork = YTKACEJPEGData(image);
                NSURL *sidecar = [destination.URLByDeletingPathExtension URLByAppendingPathExtension:@"jpg"];
                if (artwork.length == 0) lastError = YTKACEImportError(@"The selected artwork could not be read.");
                else if (![artwork writeToURL:sidecar options:NSDataWritingAtomic error:&operationError]) lastError = operationError;
            }
            NSURL *subtitle = YTKACEMatchingURL(subtitles,
                source.lastPathComponent.stringByDeletingPathExtension,
                media.count == 1);
            if (subtitle != nil && !audioCategory) {
                NSURL *sidecar = [destination.URLByDeletingPathExtension
                    URLByAppendingPathExtension:subtitle.pathExtension.lowercaseString];
                if (!YTKACEImportCopy(subtitle, sidecar, YES, &operationError)) lastError = operationError;
            }
        }
        if (media.count == 0) {
            NSArray<NSURL *> *attachments = audioCategory ? images : [images arrayByAddingObjectsFromArray:subtitles];
            NSArray<NSURL *> *library = [NSFileManager.defaultManager
                contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil
                options:NSDirectoryEnumerationSkipsHiddenFiles error:&lastError] ?: @[];
            for (NSURL *attachment in attachments) {
                BOOL isImage = [YTKACEImageExtensions() containsObject:attachment.pathExtension.lowercaseString];
                NSString *stem = attachment.lastPathComponent.stringByDeletingPathExtension;
                if (isImage) stem = YTKACEMediaStem(stem);
                BOOL matched = NO;
                for (NSURL *existing in library) {
                    if ([existing.lastPathComponent.stringByDeletingPathExtension
                            caseInsensitiveCompare:stem] != NSOrderedSame ||
                        ![mediaExtensions containsObject:existing.pathExtension.lowercaseString]) continue;
                    matched = YES;
                    NSURL *sidecar = [existing.URLByDeletingPathExtension URLByAppendingPathExtension:
                        isImage ? @"jpg" : attachment.pathExtension.lowercaseString];
                    NSError *copyError = nil;
                    BOOL copied = NO;
                    if (isImage) {
                        NSData *artwork = YTKACEJPEGData(attachment);
                        if (artwork.length != 0) copied = [artwork writeToURL:sidecar options:NSDataWritingAtomic error:&copyError];
                        else copyError = YTKACEImportError(@"The selected artwork could not be read.");
                    } else copied = YTKACEImportCopy(attachment, sidecar, YES, &copyError);
                    if (copied) imported++;
                    else lastError = copyError;
                    break;
                }
                if (!matched) lastError = YTKACEImportError([NSString stringWithFormat:
                    @"No matching media for %@", attachment.lastPathComponent]);
            }
        }
        if (imported == 0 && lastError == nil) {
            lastError = YTKACEImportError(@"No matching media was selected");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"YTKACEDownloadLibraryChanged" object:nil];
            completion(imported, lastError);
        });
    });
}

@end
