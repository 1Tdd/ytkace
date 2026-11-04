#pragma once
#import <Foundation/Foundation.h>
#include <cerrno>
#include <cstdio>

static inline NSSet<NSString *> *YTKACEVideoExtensions(void) {
    return [NSSet setWithArray:@[@"mp4", @"m4v", @"mov", @"webm", @"mkv"]];
}

static inline NSSet<NSString *> *YTKACEAudioExtensions(void) {
    return [NSSet setWithArray:@[@"m4a", @"mp3", @"aac", @"wav", @"flac", @"ogg", @"opus", @"webm"]];
}

static inline NSString *YTKACESafeImportName(NSString *name) {
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableCharacterSet *invalid = [[NSCharacterSet controlCharacterSet] mutableCopy];
    [invalid addCharactersInString:@"/\\:?%*|\"<>"];
    NSString *safe = [[[name componentsSeparatedByCharactersInSet:invalid]
        componentsJoinedByString:@"-"] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Leave room for numeric suffixes, extensions and associated sidecars.
    while ([safe lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 180) {
        NSRange last = [safe rangeOfComposedCharacterSequenceAtIndex:safe.length - 1];
        safe = [safe substringToIndex:last.location];
    }
    if (safe.length == 0 || [safe isEqual:@"."] || [safe isEqual:@".."]) return @"Imported Media";
    // Hidden names would disappear from the download library.
    return [safe hasPrefix:@"."] ? [@"Imported " stringByAppendingString:safe] : safe;
}

static inline NSURL *YTKACEUniqueImportURL(NSURL *directory, NSString *name, NSString *extension) {
    NSMutableSet *stems = [NSMutableSet set];
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory.path error:NULL]) {
        NSString *lower = entry.lowercaseString;
        [stems addObject:[lower hasSuffix:@".ytkace.json"]
            ? [lower substringToIndex:lower.length - @".ytkace.json".length]
            : lower.stringByDeletingPathExtension];
    }
    NSString *candidate = name;
    NSUInteger suffix = 2;
    // Artwork and subtitles are keyed by stem, so a different media extension
    // must not reuse an existing stem either.
    while ([stems containsObject:candidate.lowercaseString]) {
        candidate = [NSString stringWithFormat:@"%@ %lu", name, (unsigned long)suffix++];
    }
    return [directory URLByAppendingPathComponent:[candidate stringByAppendingPathExtension:extension]];
}

static inline BOOL YTKACEImportCopy(NSURL *source, NSURL *destination, BOOL replace, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSDictionary *attributes = [manager attributesOfItemAtPath:source.path error:error];
    if (attributes == nil) return NO;
    if (![[attributes objectForKey:NSFileType] isEqual:NSFileTypeRegular]) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError
            userInfo:@{NSLocalizedDescriptionKey: @"The selected item is not a regular file."}];
        return NO;
    }
    NSURL *staging = [destination.URLByDeletingLastPathComponent URLByAppendingPathComponent:
        [NSString stringWithFormat:@".%@-import", NSUUID.UUID.UUIDString]];
    if (![manager copyItemAtURL:source toURL:staging error:error]) {
        [manager removeItemAtURL:staging error:NULL];
        return NO;
    }
    BOOL success;
    if (replace) {
        // Same-directory rename replaces atomically and leaves the old file
        // intact on failure. Never remove the old sidecar before copying.
        success = rename(staging.path.fileSystemRepresentation, destination.path.fileSystemRepresentation) == 0;
        if (!success && error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    } else {
        success = [manager moveItemAtURL:staging toURL:destination error:error];
    }
    if (!success) [manager removeItemAtURL:staging error:NULL];
    return success;
}

static inline NSArray<NSURL *> *YTKACESidecarURLs(NSURL *URL) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *extension in @[@"jpg", @"png", @"ytkace.json", @"srt", @"vtt"]) {
        [result addObject:[URL.URLByDeletingPathExtension URLByAppendingPathExtension:extension]];
    }
    return result;
}

static inline BOOL YTKACERenameMediaFile(NSURL *source, NSURL *destination, NSError **error) {
    if ([source.path isEqual:destination.path]) return YES;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray *oldURLs = [@[source] arrayByAddingObjectsFromArray:YTKACESidecarURLs(source)];
    NSArray *newURLs = [@[destination] arrayByAddingObjectsFromArray:YTKACESidecarURLs(destination)];
    for (NSURL *URL in newURLs) {
        if ([manager fileExistsAtPath:URL.path]) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteFileExistsError
                userInfo:@{NSFilePathErrorKey: URL.path}];
            return NO;
        }
    }
    NSMutableArray *moved = [NSMutableArray array];
    for (NSUInteger index = 0; index < oldURLs.count; index++) {
        NSURL *oldURL = [oldURLs objectAtIndex:index];
        if (index != 0 && ![manager fileExistsAtPath:oldURL.path]) continue;
        if (![manager moveItemAtURL:oldURL toURL:[newURLs objectAtIndex:index] error:error]) {
            for (NSNumber *number in moved.reverseObjectEnumerator) {
                NSUInteger previous = number.unsignedIntegerValue;
                NSError *rollbackError = nil;
                if (![manager moveItemAtURL:[newURLs objectAtIndex:previous]
                    toURL:[oldURLs objectAtIndex:previous] error:&rollbackError] && error) {
                    *error = rollbackError;
                }
            }
            return NO;
        }
        [moved addObject:@(index)];
    }
    return YES;
}

static inline BOOL YTKACEDeleteMediaFile(NSURL *URL, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager removeItemAtURL:URL error:error]) return NO;
    BOOL success = YES;
    for (NSURL *sidecar in YTKACESidecarURLs(URL)) {
        if ([manager fileExistsAtPath:sidecar.path] && ![manager removeItemAtURL:sidecar error:error]) success = NO;
    }
    return success;
}
