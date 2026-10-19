#import "StreamResolver.h"
#include "DownloadFormatPolicy.h"

static YTKACEDownloadFormats::Identity YTKACEStreamIdentity(YTKACEStreamOption *option) {
    return {option.itag, option.width, option.height, option.bitrate, static_cast<bool>(option.audioOnly),
        option.audioTrackKey.UTF8String ?: "", option.mimeType.UTF8String ?: "", option.qualityLabel.UTF8String ?: ""};
}

@implementation YTKACEStreamOption
- (NSString *)codecIdentifier {
    NSString *mime = self.mimeType.lowercaseString;
    if ([mime containsString:@"av01"] || [mime containsString:@"av1"]) return @"av01";
    if ([mime containsString:@"vp09"] || [mime containsString:@"vp9"]) return @"vp9";
    if ([mime containsString:@"hvc1"] || [mime containsString:@"hev1"] || [mime containsString:@"hevc"]) return @"hevc";
    if (self.audioOnly) return [mime containsString:@"opus"] ? @"opus" : @"aac";
    return @"avc1";
}
- (NSString *)audioTrackKey {
    if (self.audioTrackID.length) return self.audioTrackID;
    return self.languageLabel.length ? self.languageLabel.lowercaseString : @"default";
}
- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:YTKACEStreamOption.class]) return NO;
    YTKACEStreamOption *other = object;
    return YTKACEDownloadFormats::equal(YTKACEStreamIdentity(self), YTKACEStreamIdentity(other));
}
- (NSUInteger)hash {
    return YTKACEDownloadFormats::hash(YTKACEStreamIdentity(self));
}
@end
