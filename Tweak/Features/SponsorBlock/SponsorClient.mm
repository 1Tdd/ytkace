#import "SponsorClient.h"
#import "SponsorPreferences.h"
#import "SponsorThumbnailBadge.h"
#import "../../Runtime/Localization.h"
#import <math.h>

@interface YTKACESponsorClient ()
@property(nonatomic, strong) NSCache<NSString *, NSArray *> *cache;
@property(nonatomic, strong) NSURLSession *session;
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
    if (videoID.length == 0 || categories.count == 0) {
        completion(@[]);
        return;
    }
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", videoID,
                          [categories componentsJoinedByString:@","]];

    NSArray *cached = [self.cache objectForKey:cacheKey];
    if (cached != nil) {
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
    if (resolvedAction.length == 0) {
        resolvedAction = [category isEqualToString:@"poi_highlight"] ? @"poi" : @"skip";
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

    BOOL isFullVideo = [resolvedAction isEqualToString:@"full"];
    NSDictionary *segment = @{
        @"segment": isFullVideo ? @[@(0.0), @(0.0)] : @[@(start), @(end)],
        @"category": category ?: @"sponsor",
        @"actionType": resolvedAction
    };

    NSDictionary *payload = @{
        @"videoID": videoID,
        @"userID": userID,
        @"videoDuration": @(duration > 0.0 ? duration : 0.0),
        @"userAgent": @"YTKACE/1.1.1 (iOS)",
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
        BOOL success = (error == nil && statusCode == 200);
        NSString *message = nil;

        if (success) {
            [weakSelf clearCache];
        } else if (error != nil) {
            message = error.localizedDescription ?: YTKACELocalized(@"Network error");
        } else if (statusCode == 409) {
            message = YTKACELocalized(@"Segment has already been submitted before.");
        } else if (statusCode == 403) {
            NSString *bodyString = data.length > 0
                ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            message = bodyString.length > 0
                ? bodyString
                : YTKACELocalized(@"Submission forbidden or category locked.");
        } else if (statusCode == 429) {
            message = YTKACELocalized(@"Too many submissions. Please wait a moment.");
        } else if (statusCode == 400) {
            NSString *bodyString = data.length > 0
                ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            message = bodyString.length > 0
                ? bodyString
                : YTKACELocalized(@"Invalid segment parameters.");
        } else {
            message = [NSString stringWithFormat:@"%@: %ld",
                       YTKACELocalized(@"Submission failed"), (long)statusCode];
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
