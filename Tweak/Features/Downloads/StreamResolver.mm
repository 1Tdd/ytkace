#import "StreamResolver.h"
#import "DownloadLog.h"
#import "SABRDownloader.h"
#import "../../Runtime/Localization.h"

#import <UIKit/UIKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

@implementation YTKACEStreamOption

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[YTKACEStreamOption class]]) return NO;
    YTKACEStreamOption *other = (YTKACEStreamOption *)object;
    if (self.itag > 0 && other.itag > 0 && self.itag == other.itag) return YES;
    return self.height == other.height &&
           self.audioOnly == other.audioOnly &&
           (self.qualityLabel == other.qualityLabel || [self.qualityLabel isEqualToString:other.qualityLabel]) &&
           (self.languageLabel == other.languageLabel || [self.languageLabel isEqualToString:other.languageLabel]);
}

- (NSUInteger)hash {
    return (NSUInteger)self.itag ^ (NSUInteger)self.height ^ (NSUInteger)self.audioOnly;
}

@end

static NSInteger YTKACEHeightForItag(NSInteger itag) {
    switch (itag) {
        case 160: case 278: case 394: return 144;
        case 133: case 242: case 395: return 240;
        case 18: case 134: case 243: case 396: return 360;
        case 135: case 244: case 397: return 480;
        case 22: case 136: case 247: case 298: case 302: case 398: return 720;
        case 137: case 248: case 299: case 303: case 399: return 1080;
        case 271: case 308: case 400: return 1440;
        case 313: case 315: case 401: return 2160;
        default: return 0;
    }
}

static id YTKACEStreamObject(id receiver, NSArray<NSString *> *selectors) {
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
            if (value != nil) {
                return value;
            }
        }
    }
    return nil;
}

static NSInteger YTKACEStreamInteger(id receiver, NSArray<NSString *> *selectors) {
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            return ((NSInteger (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    return 0;
}

static NSArray *YTKACEArrayValue(id receiver, NSArray<NSString *> *selectors) {
    id value = YTKACEStreamObject(receiver, selectors);
    if ([value isKindOfClass:NSArray.class]) return (NSArray *)value;
    if ([value respondsToSelector:@selector(count)] && [value conformsToProtocol:@protocol(NSFastEnumeration)]) {
        NSMutableArray *arr = [NSMutableArray array];
        for (id item in (id<NSFastEnumeration>)value) {
            [arr addObject:item];
        }
        return arr;
    }
    return @[];
}

static NSURL *YTKACEURLValue(id value) {
    if ([value isKindOfClass:NSURL.class]) {
        return value;
    }
    if ([value isKindOfClass:NSString.class]) {
        return [NSURL URLWithString:value];
    }
    return nil;
}

static id YTKACEFindNestedObject(id object,
                                 NSString *target,
                                 NSHashTable *visited,
                                 NSUInteger depth) {
    if (object == nil || depth > 8 || [visited containsObject:object]) {
        return nil;
    }
    [visited addObject:object];
    id value = YTKACEStreamObject(object, @[target]);
    if (value != nil) {
        return value;
    }
    for (NSString *name in @[@"playerData", @"contentPlayerResponse",
                              @"playerResponse", @"playbackData", @"video",
                              @"response", @"shortsPlayerData"]) {
        id nested = YTKACEStreamObject(object, @[name]);
        id found = YTKACEFindNestedObject(nested, target, visited, depth + 1);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

static id YTKACENestedObject(id object, NSString *target) {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    return YTKACEFindNestedObject(object, target, visited, 0);
}

static NSString *YTKACEStringValue(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    for (NSString *name in @[@"text", @"string", @"simpleText"]) {
        id nested = YTKACEStreamObject(value, @[name]);
        if ([nested isKindOfClass:NSString.class]) {
            return nested;
        }
    }
    return nil;
}

static NSInteger YTKACEQualityHeight(NSString *label) {
    NSScanner *scanner = [NSScanner scannerWithString:label ?: @""];
    NSInteger height = 0;
    return [scanner scanInteger:&height] ? height : 0;
}

static NSInteger YTKACEVideoPreference(YTKACEStreamOption *option) {
    NSString *mime = option.mimeType.lowercaseString;
    if ([mime containsString:@"avc1"]) return 4;
    if ([mime containsString:@"av01"] || [mime containsString:@"av1"]) return 3;
    if ([mime containsString:@"vp09"] || [mime containsString:@"vp9"]) return 2;
    if ([mime containsString:@"video/mp4"]) return 1;
    return 0;
}

static BOOL YTKACEHighResolutionSupported(YTKACEStreamOption *option) {
    if (option.height <= 1080) return YES;
    NSString *mime = option.mimeType.lowercaseString;
    if ([mime containsString:@"av01"] || [mime containsString:@"av1"]) {
        return VTIsHardwareDecodeSupported('av01');
    }
    if ([mime containsString:@"vp09"] || [mime containsString:@"vp9"]) {
        return VTIsHardwareDecodeSupported('vp09');
    }
    if ([mime containsString:@"hvc1"] || [mime containsString:@"hev1"] ||
        [mime containsString:@"hevc"]) {
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }
    if ([mime containsString:@"avc1"] || [mime containsString:@"h264"]) {
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_H264);
    }
    return NO;
}

static NSString *YTKACEVideoRejectReason(YTKACEStreamOption *option) {
    if (option.isAudioOnly) return @"audio only";
    if (![option.mimeType hasPrefix:@"video/"] && ![option.mimeType containsString:@"video"]) return @"not video";
    if (option.itag <= 0) return @"no itag";
    if (![option.mimeType containsString:@"video/mp4"] &&
        ![option.mimeType containsString:@"video/webm"] &&
        ![option.mimeType containsString:@"mp4"] &&
        ![option.mimeType containsString:@"webm"]) {
        return @"container unsupported";
    }
    if (option.height <= 0) return @"no height";
    if (!YTKACEHighResolutionSupported(option)) return @"no hardware decode";
    return nil;
}

static id YTKACEPlayerData(id playerResponse) {
    return YTKACENestedObject(playerResponse, @"playerData") ?: playerResponse;
}

static id YTKACEVideoDetails(id playerResponse) {
    return YTKACENestedObject(playerResponse, @"videoDetails") ?:
        YTKACEPlayerData(playerResponse);
}

static id YTKACEStreamingData(id playerResponse) {
    id direct = YTKACEStreamObject(playerResponse, @[@"streamingData"]);
    return direct ?: YTKACEStreamObject(YTKACEPlayerData(playerResponse),
                                         @[@"streamingData"]);
}


static YTKACEStreamOption *YTKACEOptionFromFormat(id format, BOOL adaptive) {
    NSURL *url = YTKACEURLValue(YTKACEStreamObject(format, @[@"URL", @"url"]));
    if (url != nil && ![url.scheme.lowercaseString hasPrefix:@"http"]) {
        url = nil;
    }

    NSString *mime = YTKACEStreamObject(format, @[@"mimeType"]);
    if (![mime isKindOfClass:NSString.class]) {
        mime = @"application/octet-stream";
    }

    YTKACEStreamOption *option = [YTKACEStreamOption new];
    option.URL = url;
    option.mimeType = mime;
    option.qualityLabel = YTKACEStreamObject(format, @[@"qualityLabel", @"audioQuality"]) ?: @"";
    option.xtags = YTKACEStreamObject(format, @[@"xtags"]) ?: @"";
    option.bitrate = YTKACEStreamInteger(format, @[@"bitrate"]);
    option.itag = YTKACEStreamInteger(format, @[@"itag"]);
    option.contentLength = YTKACEStreamInteger(format, @[@"contentLength"]);
    option.lastModified = YTKACEStreamInteger(format, @[@"lastModified"]);
    option.width = YTKACEStreamInteger(format, @[@"width"]);
    option.height = YTKACEStreamInteger(format, @[@"height"]);
    option.audioOnly = [mime hasPrefix:@"audio/"] ||
        (adaptive && ![mime hasPrefix:@"video/"]);
    if (option.itag == 139 || option.itag == 140 || option.itag == 141 ||
        option.itag == 249 || option.itag == 250 || option.itag == 251) {
        option.audioOnly = YES;
    }
    if (!option.audioOnly && option.height <= 0) {
        option.height = YTKACEQualityHeight(option.qualityLabel);
        if (option.height <= 0 && option.width > 0) {
            option.height = MIN(option.width, 1080);
        }
        if (option.height <= 0) {
            option.height = YTKACEHeightForItag(option.itag);
        }
    }
    if (!option.audioOnly && option.qualityLabel.length == 0 && option.height > 0) {
        option.qualityLabel = [NSString stringWithFormat:@"%ldp", (long)option.height];
    }
    option.adaptive = adaptive;
    option.rawFormat = format;
    id audioTrack = YTKACEStreamObject(format, @[@"audioTrack"]);
    NSString *language = YTKACEStringValue(YTKACEStreamObject(
        audioTrack, @[@"displayName", @"display_name", @"name"]));
    if (language.length == 0) {
        NSString *description = [audioTrack description];
        NSRange marker = [description rangeOfString:@"display_name: \""];
        if (marker.location != NSNotFound) {
            NSUInteger start = NSMaxRange(marker);
            NSRange rest = NSMakeRange(start, description.length - start);
            NSRange end = [description rangeOfString:@"\"" options:0 range:rest];
            if (end.location != NSNotFound) {
                language = [description substringWithRange:
                    NSMakeRange(start, end.location - start)];
            }
        }
    }
    option.languageLabel = language.length != 0 ? language : YTKACELocalized(@"Original audio");
    NSString *trackID = YTKACEStringValue(YTKACEStreamObject(
        audioTrack, @[@"id_p", @"audioTrackId", @"audioTrackID"]));
    if (trackID.length == 0) {
        NSString *description = [audioTrack description];
        NSRange marker = [description rangeOfString:@"id: \""];
        if (marker.location != NSNotFound) {
            NSUInteger start = NSMaxRange(marker);
            NSRange rest = NSMakeRange(start, description.length - start);
            NSRange end = [description rangeOfString:@"\"" options:0 range:rest];
            if (end.location != NSNotFound) {
                trackID = [description substringWithRange:
                    NSMakeRange(start, end.location - start)];
            }
        }
    }
    option.audioTrackID = trackID ?: @"";
    option.defaultAudio = YTKACEStreamInteger(
        audioTrack, @[@"audioIsDefault", @"isDefault", @"defaultAudio"]) != 0;
    return option;
}

@implementation YTKACEStreamResolver

+ (NSArray<YTKACEStreamOption *> *)optionsFromPlayerResponse:(id)playerResponse {
    NSString *videoID = [self videoIDFromPlayerResponse:playerResponse];
    if (videoID.length != 0) {
        id cached = YTKACECachedPlayerResponse(videoID);
        if (cached != nil) {
            id cachedStreaming = YTKACEStreamingData(cached);
            if (cachedStreaming != nil) {
                playerResponse = cached;
            }
        }
    }
    id streamingData = YTKACEStreamingData(playerResponse);
    if (streamingData == nil) {
        return @[];
    }
    NSMutableArray<YTKACEStreamOption *> *result = [NSMutableArray array];
    for (id format in YTKACEArrayValue(streamingData, @[@"formatsArray", @"formats"])) {
        YTKACEStreamOption *option = YTKACEOptionFromFormat(format, NO);
        if (option != nil) {
            [result addObject:option];
        }
    }
    for (id format in YTKACEArrayValue(
             streamingData,
             @[@"adaptiveFormatsArray", @"adaptiveFormats"])) {
        YTKACEStreamOption *option = YTKACEOptionFromFormat(format, YES);
        if (option != nil) {
            [result addObject:option];
        }
    }
    return result;
}

+ (NSArray<YTKACEStreamOption *> *)videoOptionsFromPlayerResponse:(id)playerResponse {
    NSArray *options = [self optionsFromPlayerResponse:playerResponse];
    NSMutableDictionary<NSString *, YTKACEStreamOption *> *byQuality =
        [NSMutableDictionary dictionary];
    YTKACEDownloadLog(@"quality", @"formats=%lu video=%@ decode avc1=%d hevc=%d vp9=%d av1=%d",
        (unsigned long)options.count,
        [self videoIDFromPlayerResponse:playerResponse] ?: @"?",
        VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
        VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
        VTIsHardwareDecodeSupported('vp09'),
        VTIsHardwareDecodeSupported('av01'));
    for (YTKACEStreamOption *option in options) {
        if (option.isAudioOnly) continue;
        if (option.height <= 0) {
            option.height = YTKACEQualityHeight(option.qualityLabel);
        }
        if (option.height <= 0 && option.width > 0) {
            option.height = MIN(option.width, 1080);
        }
        if (option.height <= 0) {
            option.height = YTKACEHeightForItag(option.itag);
        }
        if (option.qualityLabel.length == 0 && option.height > 0) {
            option.qualityLabel = [NSString stringWithFormat:@"%ldp", (long)option.height];
        }
        NSString *reason = YTKACEVideoRejectReason(option);
        if (reason != nil) {
            if (option.height >= 1080) {
                YTKACEDownloadLog(@"quality", @"dropped itag=%ld %@ %@ -> %@",
                    (long)option.itag,
                    option.qualityLabel.length != 0 ? option.qualityLabel : @"-",
                    option.mimeType, reason);
            }
            continue;
        }
        NSString *key = option.qualityLabel.length != 0
            ? option.qualityLabel : [NSString stringWithFormat:@"%ldp", (long)option.height];
        YTKACEStreamOption *current = byQuality[key];
        NSInteger preference = YTKACEVideoPreference(option);
        NSInteger currentPreference = YTKACEVideoPreference(current);
        if (current == nil || preference > currentPreference ||
            (preference == currentPreference && option.bitrate > current.bitrate)) {
            byQuality[key] = option;
        }
    }
    // Fallback: if all were rejected, relax constraints to ensure valid video streams are available
    if (byQuality.count == 0) {
        for (YTKACEStreamOption *option in options) {
            if (option.isAudioOnly) continue;
            if (![option.mimeType hasPrefix:@"video/"] && ![option.mimeType containsString:@"video"]) continue;
            NSInteger h = option.height > 0 ? option.height : YTKACEQualityHeight(option.qualityLabel);
            if (h <= 0 && option.width > 0) h = MIN(option.width, 1080);
            if (h <= 0) h = YTKACEHeightForItag(option.itag);
            if (h <= 0) h = 720;
            option.height = h;
            NSString *key = option.qualityLabel.length != 0
                ? option.qualityLabel : [NSString stringWithFormat:@"%ldp", (long)h];
            if (byQuality[key] == nil || option.bitrate > byQuality[key].bitrate) {
                byQuality[key] = option;
            }
        }
    }
    YTKACEDownloadLog(@"quality", @"offering %@",
        [[byQuality.allKeys sortedArrayUsingSelector:@selector(compare:)]
            componentsJoinedByString:@", "]);
    return [byQuality.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(YTKACEStreamOption *left, YTKACEStreamOption *right) {
            if (left.height == right.height) {
                return left.bitrate > right.bitrate ? NSOrderedAscending : NSOrderedDescending;
            }
            return left.height > right.height ? NSOrderedAscending : NSOrderedDescending;
        }];
}

+ (NSArray<YTKACEStreamOption *> *)audioOptionsFromPlayerResponse:(id)playerResponse {
    NSArray *options = [self optionsFromPlayerResponse:playerResponse];
    NSMutableDictionary<NSString *, YTKACEStreamOption *> *byLanguage =
        [NSMutableDictionary dictionary];
    for (YTKACEStreamOption *option in options) {
        if (!option.isAudioOnly && ![option.mimeType hasPrefix:@"audio/"] &&
            option.itag != 139 && option.itag != 140 && option.itag != 141 &&
            option.itag != 249 && option.itag != 250 && option.itag != 251) {
            continue;
        }
        NSString *key = option.languageLabel.length != 0
            ? option.languageLabel : YTKACELocalized(@"Original audio");
        YTKACEStreamOption *current = byLanguage[key];
        BOOL isMp4 = [option.mimeType containsString:@"mp4"] || [option.mimeType containsString:@"mp4a"];
        BOOL currentIsMp4 = [current.mimeType containsString:@"mp4"] || [current.mimeType containsString:@"mp4a"];
        if (current == nil ||
            (!currentIsMp4 && isMp4) ||
            (currentIsMp4 == isMp4 && (option.isDefaultAudio || option.bitrate > current.bitrate))) {
            byLanguage[key] = option;
        }
    }
    return [byLanguage.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(YTKACEStreamOption *left, YTKACEStreamOption *right) {
            if (left.isDefaultAudio != right.isDefaultAudio) {
                return left.isDefaultAudio ? NSOrderedAscending : NSOrderedDescending;
            }
            return [left.languageLabel localizedCaseInsensitiveCompare:right.languageLabel];
        }];
}

+ (YTKACEStreamOption *)bestPiPVideoFromPlayerResponse:(id)playerResponse {
    id streamingData = YTKACEStreamingData(playerResponse);
    NSURL *hls = YTKACEURLValue(YTKACEStreamObject(
        streamingData,
        @[@"hlsManifestURL", @"hlsManifestUrl"]
    ));
    if (hls != nil) {
        YTKACEStreamOption *option = [YTKACEStreamOption new];
        option.URL = hls;
        option.mimeType = @"application/x-mpegURL";
        option.qualityLabel = @"HLS";
        return option;
    }
    return [self bestVideoFromPlayerResponse:playerResponse];
}

+ (YTKACEStreamOption *)bestVideoFromPlayerResponse:(id)playerResponse {
    NSArray<YTKACEStreamOption *> *options = [self optionsFromPlayerResponse:playerResponse];
    NSPredicate *video = [NSPredicate predicateWithBlock:
        ^BOOL(YTKACEStreamOption *option, NSDictionary *bindings) {
            (void)bindings;
            return !option.isAdaptive &&
                !option.isAudioOnly &&
                [option.mimeType hasPrefix:@"video/"];
        }];
    return [[options filteredArrayUsingPredicate:video]
        sortedArrayUsingComparator:^NSComparisonResult(YTKACEStreamOption *left,
                                                        YTKACEStreamOption *right) {
            if (left.bitrate == right.bitrate) {
                return NSOrderedSame;
            }
            return left.bitrate > right.bitrate ? NSOrderedAscending : NSOrderedDescending;
        }].firstObject;
}

+ (YTKACEStreamOption *)bestAudioFromPlayerResponse:(id)playerResponse {
    NSArray<YTKACEStreamOption *> *options = [self optionsFromPlayerResponse:playerResponse];
    NSPredicate *audio = [NSPredicate predicateWithBlock:
        ^BOOL(YTKACEStreamOption *option, NSDictionary *bindings) {
            (void)bindings;
            return option.isAudioOnly || [option.mimeType hasPrefix:@"audio/"];
        }];
    return [[options filteredArrayUsingPredicate:audio]
        sortedArrayUsingComparator:^NSComparisonResult(YTKACEStreamOption *left,
                                                        YTKACEStreamOption *right) {
            if (left.bitrate == right.bitrate) {
                return NSOrderedSame;
            }
            return left.bitrate > right.bitrate ? NSOrderedAscending : NSOrderedDescending;
        }].firstObject;
}

+ (NSString *)titleFromPlayerResponse:(id)playerResponse {
    id details = YTKACEVideoDetails(playerResponse);
    NSString *title = YTKACEStringValue(YTKACEStreamObject(
        details, @[@"title", @"videoTitle", @"headline"]));
    return title.length != 0
        ? title
        : @"YouTube Video";
}

+ (NSString *)authorFromPlayerResponse:(id)playerResponse {
    id details = YTKACEVideoDetails(playerResponse);
    NSString *author = YTKACEStringValue(YTKACEStreamObject(
        details, @[@"author", @"channelTitle", @"ownerChannelName"]));
    return author.length != 0
        ? author : @"YouTube";
}

+ (NSString *)descriptionFromPlayerResponse:(id)playerResponse {
    id details = YTKACEVideoDetails(playerResponse);
    id description = YTKACEStreamObject(details,
        @[@"shortDescription", @"videoDescription", @"descriptionText"]);
    return [description isKindOfClass:NSString.class]
        ? description : @"";
}

+ (NSString *)videoIDFromPlayerResponse:(id)playerResponse {
    id details = YTKACEVideoDetails(playerResponse);
    id videoID = YTKACEStreamObject(details, @[@"videoId", @"videoID"]);
    if (![videoID isKindOfClass:NSString.class] || [videoID length] == 0) {
        videoID = YTKACEStreamObject(playerResponse, @[@"videoId", @"videoID"]);
    }
    return [videoID isKindOfClass:NSString.class] ? videoID : nil;
}

+ (NSURL *)thumbnailURLFromPlayerResponse:(id)playerResponse {
    id details = YTKACEVideoDetails(playerResponse);
    id thumbnail = YTKACEStreamObject(details, @[@"thumbnail"]);
    NSArray *items = YTKACEArrayValue(thumbnail, @[@"thumbnailsArray", @"thumbnails"]);
    id candidate = items.lastObject;
    return YTKACEURLValue(YTKACEStreamObject(candidate, @[@"URL", @"url"]));
}

@end
