#import "SponsorClient.h"
#import "SponsorPreferences.h"
#import "SponsorThumbnailBadge.h"
#import "../../Runtime/Localization.h"
#import <math.h>

@interface YTKACESponsorClient ()
@property(nonatomic, strong) NSCache<NSString *, NSArray *> *cache;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *localSubmissions;
- (NSArray *)localSegmentsForVideoID:(NSString *)videoID;
@end

@implementation YTKACESponsorClient

+ (instancetype)sharedClient {
    static YTKACESponsorClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [YTKACESponsorClient new];
    });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [NSCache new];
        _cache.countLimit = 128;
        _localSubmissions = [NSMutableDictionary dictionary];

        NSURLSessionConfiguration *configuration =
            NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 10.0;
        configuration.timeoutIntervalForResource = 15.0;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (void)segmentsForVideoID:(NSString *)videoID
                completion:(YTKACESponsorCompletion)completion {
    if (videoID.length == 0) {
        completion(@[]);
        return;
    }

    [self segmentsForVideoID:videoID categories:YTKACESponsorEnabledCategories()
                  completion:completion];
}

- (void)segmentsForVideoID:(NSString *)videoID
                categories:(NSArray<NSString *> *)categories
                completion:(YTKACESponsorCompletion)completion {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self segmentsForVideoID:videoID categories:categories completion:completion]; });
        return;
    }
    if (videoID.length == 0 || categories.count == 0) {
        completion(@[]);
        return;
    }
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", videoID,
                          [categories componentsJoinedByString:@","]];

    NSArray *cached = [self.cache objectForKey:cacheKey];
    if (cached != nil) {
        NSArray *locals = [self localSegmentsForVideoID:videoID];
        if (locals.count > 0) {
            NSMutableArray *merged = [cached mutableCopy];
            BOOL changed = NO;
            for (NSDictionary *local in locals) {
                NSString *cat = local[@"category"];
                if (cat.length > 0 && ![categories containsObject:cat]) continue;
                double lStart = [local[@"start"] doubleValue];
                double lEnd = [local[@"end"] doubleValue];
                BOOL duplicate = NO;
                for (NSDictionary *ex in merged) {
                    if (([local[@"uuid"] length] > 0 && [ex[@"uuid"] isEqualToString:local[@"uuid"]]) ||
                        ([ex[@"category"] isEqualToString:cat] && [ex[@"actionType"] isEqualToString:local[@"actionType"]] &&
                         fabs([ex[@"start"] doubleValue] - lStart) < 0.2 && fabs([ex[@"end"] doubleValue] - lEnd) < 0.2)) {
                        duplicate = YES;
                        break;
                    }
                }
                if (!duplicate) {
                    [merged addObject:local];
                    changed = YES;
                }
            }
            if (changed) {
                [merged sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    return [a[@"start"] compare:b[@"start"]];
                }];
                cached = [merged copy];
                [self.cache setObject:cached forKey:cacheKey];
            }
        }
        completion(cached);
        return;
    }

    NSURLComponents *components =
        [NSURLComponents componentsWithString:@"https://sponsor.ajay.app/api/skipSegments"];
    NSData *categoryData = [NSJSONSerialization dataWithJSONObject:categories
                                                            options:0 error:nil];
    NSString *categoryJSON = categoryData == nil ? @"[]" :
        [[NSString alloc] initWithData:categoryData encoding:NSUTF8StringEncoding];
    NSData *actionTypesData = [NSJSONSerialization dataWithJSONObject:@[@"skip", @"mute", @"full", @"poi"]
                                                              options:0 error:nil];
    NSString *actionTypesJSON = actionTypesData == nil ? @"[\"skip\"]" :
        [[NSString alloc] initWithData:actionTypesData encoding:NSUTF8StringEncoding];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"videoID" value:videoID],
        [NSURLQueryItem queryItemWithName:@"categories" value:categoryJSON],
        [NSURLQueryItem queryItemWithName:@"actionTypes" value:actionTypesJSON]
    ];
    NSURL *url = components.URL;
    if (url == nil) {
        completion(@[]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    __weak YTKACESponsorClient *weakSelf = self;
    NSURLSessionDataTask *task =
        [self.session dataTaskWithRequest:request
                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableArray<NSDictionary<NSString *, id> *> *segments =
            [NSMutableArray array];
        NSHTTPURLResponse *http =
            [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response
                : nil;

        if (error == nil && http.statusCode == 200 && data.length <= 1024 * 1024) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSArray.class]) {
                for (id item in (NSArray *)json) {
                    if (![item isKindOfClass:NSDictionary.class]) {
                        continue;
                    }
                    id category = item[@"category"];
                    id values = item[@"segment"];
                    id actionTypeObj = item[@"actionType"];
                    NSString *actionType = [actionTypeObj isKindOfClass:NSString.class] ? actionTypeObj : @"skip";
                    if (![@[@"skip", @"mute", @"full", @"poi"] containsObject:actionType]) continue;
                    id uuidObj = item[@"UUID"] ?: item[@"uuid"];
                    NSString *uuid = [uuidObj isKindOfClass:NSString.class] ? uuidObj : @"";

                    if (![category isKindOfClass:NSString.class] ||
                        ![categories containsObject:category] ||
                        ![values isKindOfClass:NSArray.class] ||
                        [values count] != 2) {
                        continue;
                    }
                    id startValue = values[0];
                    id endValue = values[1];
                    if (![startValue isKindOfClass:NSNumber.class] ||
                        ![endValue isKindOfClass:NSNumber.class]) {
                        continue;
                    }
                    double start = [startValue doubleValue];
                    double end = [endValue doubleValue];
                    BOOL allowZeroLength = [category isEqualToString:@"poi_highlight"] ||
                                           [actionType isEqualToString:@"poi"] ||
                                           [actionType isEqualToString:@"full"];
                    if (!isfinite(start) || !isfinite(end) || start < 0.0 ||
                        end < start || (end == start && !allowZeroLength)) {
                        continue;
                    }
                    if ([actionType isEqualToString:@"full"]) {
                        YTKACESponsorRecordVideoLabel(videoID, category);
                    }
                    [segments addObject:@{
                        @"start": @(start),
                        @"end": @(end),
                        @"category": category,
                        @"actionType": actionType,
                        @"uuid": uuid
                    }];
                }
            }
        }

        NSArray *locals = [weakSelf localSegmentsForVideoID:videoID];
        if (locals.count > 0) {
            for (NSDictionary *local in locals) {
                NSString *cat = local[@"category"];
                if (cat.length > 0 && ![categories containsObject:cat]) continue;
                double lStart = [local[@"start"] doubleValue];
                double lEnd = [local[@"end"] doubleValue];
                BOOL duplicate = NO;
                for (NSDictionary *ex in segments) {
                    if (([local[@"uuid"] length] > 0 && [ex[@"uuid"] isEqualToString:local[@"uuid"]]) ||
                        ([ex[@"category"] isEqualToString:cat] && [ex[@"actionType"] isEqualToString:local[@"actionType"]] &&
                         fabs([ex[@"start"] doubleValue] - lStart) < 0.2 && fabs([ex[@"end"] doubleValue] - lEnd) < 0.2)) {
                        duplicate = YES;
                        break;
                    }
                }
                if (!duplicate) {
                    [segments addObject:local];
                }
            }
        }

        NSArray *result = [segments sortedArrayUsingComparator:
            ^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
                return [left[@"start"] compare:right[@"start"]];
            }];
        if (result.count != 0) {
            [weakSelf.cache setObject:result forKey:cacheKey];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result);
        });
    }];
    [task resume];
}

- (void)clearCache {
    [self.cache removeAllObjects];
}

- (void)clearCacheForVideoID:(__unused NSString *)videoID {
    [self.cache removeAllObjects];
}

- (NSArray *)localSegmentsForVideoID:(NSString *)videoID {
    @synchronized (self) { return [self.localSubmissions[videoID] copy] ?: @[]; }
}

- (void)addLocalSegment:(NSDictionary<NSString *, id> *)segment forVideoID:(NSString *)videoID {
    if (videoID.length == 0 || segment == nil) return;
    @synchronized (self) {
    NSMutableArray *list = self.localSubmissions[videoID];
    if (list == nil) {
        list = [NSMutableArray array];
        self.localSubmissions[videoID] = list;
    }
    NSString *uuid = segment[@"uuid"];
    double start = [segment[@"start"] doubleValue];
    double end = [segment[@"end"] doubleValue];
    BOOL exists = NO;
    for (NSDictionary *item in list) {
        if (uuid.length > 0 && [item[@"uuid"] isEqualToString:uuid]) {
            exists = YES;
            break;
        }
        if ([item[@"category"] isEqualToString:segment[@"category"]] &&
            [item[@"actionType"] isEqualToString:segment[@"actionType"]] &&
            fabs([item[@"start"] doubleValue] - start) < 0.1 && fabs([item[@"end"] doubleValue] - end) < 0.1) {
            exists = YES;
            break;
        }
    }
    if (!exists) {
        [list addObject:segment];
    }
    }
    [self.cache removeAllObjects];
}

- (void)submitSegmentForVideoID:(NSString *)videoID
                          start:(double)start
                            end:(double)end
                       category:(NSString *)category
                     actionType:(nullable NSString *)actionType
                  videoDuration:(double)duration
                     completion:(nullable void (^)(BOOL success, NSString * _Nullable message))completion {
    NSString *userID = YTKACESponsorUserID();
    if (videoID.length == 0 || userID.length == 0) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, YTKACELocalized(@"Missing video or user ID"));
            });
        }
        return;
    }

    NSString *resolvedAction = actionType;
    BOOL isPOI = [category isEqualToString:@"poi_highlight"] || [resolvedAction isEqualToString:@"poi"];
    if (isPOI) {
        resolvedAction = @"poi";
    } else if (resolvedAction.length == 0) {
        resolvedAction = @"skip";
    }

    // Server compatibility: music_offtopic only accepts 'skip' (not mute or full)
    if ([category isEqualToString:@"music_offtopic"] && ![resolvedAction isEqualToString:@"skip"]) {
        resolvedAction = @"skip";
    }

    // Server compatibility: 'full' is only supported for sponsor and selfpromo
    if ([resolvedAction isEqualToString:@"full"] &&
        ![category isEqualToString:@"sponsor"] &&
        ![category isEqualToString:@"selfpromo"]) {
        resolvedAction = @"skip";
    }

    NSURL *url = [NSURL URLWithString:@"https://sponsor.ajay.app/api/skipSegments"];
    if (url == nil) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, YTKACELocalized(@"Invalid server URL"));
            });
        }
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"YTKACE/1.1.3 (iOS)" forHTTPHeaderField:@"User-Agent"];

    BOOL isFullVideo = [resolvedAction isEqualToString:@"full"];
    double resolvedStart = start;
    // poi_highlight requires segment to be [start, start] (point of interest)
    double resolvedEnd = isPOI ? start : end;
    if (duration > 0.0 && !isFullVideo && !isPOI) {
        if (resolvedEnd > duration) resolvedEnd = duration;
        if (resolvedStart > duration) resolvedStart = duration;
    }
    resolvedStart = round(resolvedStart * 1000.0) / 1000.0;
    resolvedEnd = round(resolvedEnd * 1000.0) / 1000.0;

    if (!isfinite(duration) || duration < 0.0 || !isfinite(resolvedStart) || !isfinite(resolvedEnd) ||
        resolvedStart < 0.0 || resolvedEnd < resolvedStart || (!isFullVideo && !isPOI && resolvedEnd <= resolvedStart)) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, YTKACELocalized(@"End time must be after start time")); });
        return;
    }

    NSDictionary *segment = @{
        @"segment": isFullVideo ? @[@(0.0), @(0.0)] : @[@(resolvedStart), @(resolvedEnd)],
        @"category": category ?: @"sponsor",
        @"actionType": resolvedAction,
        @"description": @""
    };

    NSDictionary *payload = @{
        @"videoID": videoID,
        @"userID": userID,
        @"videoDuration": @(duration > 0.0 ? duration : 0.0),
        @"userAgent": @"YTKACE/1.1.3 (iOS)",
        @"segments": @[segment]
    };

    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload
                                                       options:0
                                                         error:&jsonError];
    if (bodyData == nil || jsonError != nil) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, YTKACELocalized(@"Failed to encode segment data"));
            });
        }
        return;
    }
    request.HTTPBody = bodyData;

    __weak YTKACESponsorClient *weakSelf = self;
    NSURLSessionDataTask *task =
        [self.session dataTaskWithRequest:request
                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        NSInteger statusCode = http != nil ? http.statusCode : 0;
        BOOL success = (error == nil && (statusCode >= 200 && statusCode < 300));
        NSString *message = nil;
        NSString *bodyString = data.length > 0
            ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;

        if (success) {
            id submitted = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            id entry = [submitted isKindOfClass:NSArray.class] ? [submitted firstObject] : nil;
            NSString *serverUUID = [entry isKindOfClass:NSDictionary.class] && [entry[@"UUID"] isKindOfClass:NSString.class] ? entry[@"UUID"] : @"";
            NSDictionary *localSeg = @{
                @"start": @(resolvedStart),
                @"end": @(resolvedEnd),
                @"category": category ?: @"sponsor",
                @"actionType": resolvedAction,
                @"uuid": serverUUID
            };
            [weakSelf addLocalSegment:localSeg forVideoID:videoID];
        } else if (error != nil) {
            message = error.localizedDescription ?: YTKACELocalized(@"Network error");
        } else if (statusCode == 409) {
            message = YTKACELocalized(@"Segment has already been submitted before.");
        } else if (statusCode == 403) {
            if ([bodyString containsString:@"already been submitted"] || [bodyString containsString:@"locked"]) {
                message = [NSString stringWithFormat:@"%@: %@",
                           YTKACELocalized(@"This category is locked or already completed for this video"),
                           YTKACESponsorCategoryTitle(category)];
            } else {
                message = bodyString.length > 0
                    ? bodyString
                    : YTKACELocalized(@"Submission forbidden or category locked.");
            }
        } else if (statusCode == 429) {
            message = YTKACELocalized(@"Too many submissions. Please wait a moment.");
        } else if (statusCode == 400) {
            message = bodyString.length > 0
                ? bodyString
                : YTKACELocalized(@"Invalid segment parameters.");
        } else {
            message = [NSString stringWithFormat:@"%@: %ld%@",
                       YTKACELocalized(@"Submission failed"), (long)statusCode,
                       (bodyString.length > 0 ? [NSString stringWithFormat:@" (%@)", bodyString] : @"")];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(success, message);
            }
        });
    }];
    [task resume];
}

- (void)voteForSegmentUUID:(NSString *)uuid
                      type:(NSInteger)type
                completion:(nullable void (^)(BOOL success, NSString * _Nullable message))completion {
    NSString *userID = YTKACESponsorUserID();
    if (uuid.length == 0 || userID.length == 0) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, YTKACELocalized(@"Missing segment UUID or user ID"));
            });
        }
        return;
    }

    NSURLComponents *components =
        [NSURLComponents componentsWithString:@"https://sponsor.ajay.app/api/voteOnSponsorTime"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"UUID" value:uuid],
        [NSURLQueryItem queryItemWithName:@"userID" value:userID],
        [NSURLQueryItem queryItemWithName:@"type" value:[@(type) stringValue]]
    ];
    NSURL *url = components.URL;
    if (url == nil) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, YTKACELocalized(@"Invalid server URL"));
            });
        }
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    __weak YTKACESponsorClient *weakSelf = self;
    NSURLSessionDataTask *task =
        [self.session dataTaskWithRequest:request
                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        NSInteger statusCode = http != nil ? http.statusCode : 0;
        BOOL success = (error == nil && statusCode == 200);
        NSString *message = nil;
        if (success) {
            [weakSelf clearCache];
        } else {
            NSString *body = data.length > 0
                ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            message = body.length > 0 ? body : (error.localizedDescription ?: YTKACELocalized(@"Voting failed"));
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(success, message);
            }
        });
    }];
    [task resume];
}

@end
