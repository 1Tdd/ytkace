#import "../Tweak/Features/Downloads/MediaImportFiles.h"
#include <cstdlib>

static void check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); std::exit(1); }
}

int main() {
    @autoreleasepool {
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        check([manager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:NULL], "Create test directory");
        NSURL *source = [root URLByAppendingPathComponent:@"source.webm"];
        const unsigned char bytes[] = {0, 255, 42, 0, 127, 128};
        NSData *payload = [NSData dataWithBytes:bytes length:sizeof(bytes)];
        check([payload writeToURL:source atomically:YES], "Write binary fixture");
        NSURL *destination = [root URLByAppendingPathComponent:@"imported.webm"];
        NSError *error = nil;
        check(YTKACEImportCopy(source, destination, NO, &error), "Import succeeds");
        check([[NSData dataWithContentsOfURL:destination] isEqual:payload], "Import preserves all bytes without remuxing");
        NSData *old = [@"existing subtitle" dataUsingEncoding:NSUTF8StringEncoding];
        NSURL *sidecar = [root URLByAppendingPathComponent:@"imported.srt"];
        [old writeToURL:sidecar atomically:YES];
        check(!YTKACEImportCopy([root URLByAppendingPathComponent:@"missing"], sidecar, YES, &error) && error != nil, "Missing source reports an error");
        check([[NSData dataWithContentsOfURL:sidecar] isEqual:old], "Failed replacement preserves original subtitles");
        check(!YTKACEImportCopy(source, sidecar, NO, &error), "New import never overwrites an existing destination");
        check([[NSData dataWithContentsOfURL:sidecar] isEqual:old], "Destination collision preserves original bytes");
        check(YTKACEImportCopy(source, sidecar, YES, &error), "Valid replacement succeeds");
        check([[NSData dataWithContentsOfURL:sidecar] isEqual:payload], "Replacement contains complete new bytes");
        check(!YTKACEImportCopy(root, sidecar, YES, &error), "Directories are not accepted as media files");
        check(!YTKACEImportCopy(source, root, YES, &error), "Failed final rename reports an error");
        for (NSString *entry in [manager contentsOfDirectoryAtPath:root.path error:NULL]) {
            check(![entry hasSuffix:@"-import"], "Failures clean up partial staging files");
        }
        NSURL *unique = YTKACEUniqueImportURL(root, @"IMPORTED", @"mp4");
        check([unique.lastPathComponent isEqual:@"IMPORTED 2.mp4"], "Different containers and letter case cannot share sidecars");
        [old writeToURL:[root URLByAppendingPathComponent:@"orphan.jpg"] atomically:YES];
        check([YTKACEUniqueImportURL(root, @"orphan", @"m4a").lastPathComponent isEqual:@"orphan 2.m4a"], "Orphaned sidecar must not attach to an unrelated import");
        [old writeToURL:[root URLByAppendingPathComponent:@"chapter.ytkace.json"] atomically:YES];
        check([YTKACEUniqueImportURL(root, @"chapter", @"mp4").lastPathComponent isEqual:@"chapter 2.mp4"], "Compound metadata sidecar reserves its media stem");
        NSURL *renamed = [root URLByAppendingPathComponent:@"renamed.webm"];
        NSURL *newSubtitle = [root URLByAppendingPathComponent:@"renamed.srt"];
        [old writeToURL:newSubtitle atomically:YES];
        check(!YTKACERenameMediaFile(destination, renamed, &error), "Rename refuses sidecar collisions before moving media");
        check([manager fileExistsAtPath:destination.path] && [[NSData dataWithContentsOfURL:sidecar] isEqual:payload], "Failed rename retains both media and its subtitles");
        [manager removeItemAtURL:newSubtitle error:NULL];
        check(YTKACERenameMediaFile(destination, renamed, &error), "Rename moves media and existing sidecars together");
        check(![manager fileExistsAtPath:destination.path] && [[NSData dataWithContentsOfURL:newSubtitle] isEqual:payload], "Renamed subtitles remain associated with their media");
        check(!YTKACEDeleteMediaFile(destination, &error), "Deleting missing media reports failure");
        check(YTKACEDeleteMediaFile(renamed, &error), "Delete media and its sidecars");
        check(![manager fileExistsAtPath:newSubtitle.path], "Successful delete removes associated subtitles");
        NSString *longName = [@"🎵e\u0301" stringByPaddingToLength:400 withString:@"🎵e\u0301" startingAtIndex:0];
        NSString *safe = YTKACESafeImportName(longName);
        check(safe.length > 0 && [safe lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 180, "Multibyte names leave room for suffixes");
        check(![YTKACESafeImportName(@".hidden") hasPrefix:@"."], "Imported files cannot be hidden");
        check([YTKACESafeImportName(@" \n ") isEqual:@"Imported Media"], "Empty names have a visible fallback");
        for (NSString *extension in @[@"mkv", @"wav", @"flac", @"ogg", @"opus", @"webm"]) {
            check([YTKACEVideoExtensions() containsObject:extension] || [YTKACEAudioExtensions() containsObject:extension], "Imported formats remain visible in the library");
        }
        [manager removeItemAtURL:root error:NULL];
        puts("Media import: byte preservation, atomic replacement, failure cleanup, name collisions and Unicode passed.");
    }
}
