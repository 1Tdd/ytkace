#import "DirectDownloader.h"
#import "StreamResolver.h"
#import "DownloadLog.h"
#import "../../Runtime/Preferences.h"

#import <objc/message.h>

NSString * const YTKACEDownloadMethodKey = @"YTKACE.Preference.Downloads.Method";

static NSString * const YTKACEDirectUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 "
     "(KHTML, like Gecko) Version/26.0 Safari/605.1.15";
static NSString * const YTKACEDirectVisitorKey = @"YTKACE.Cache.DirectVisitor";
static const NSTimeInterval YTKACEDirectVisitorLifetime = 7.0 * 24.0 * 60.0 * 60.0;
static const int64_t YTKACEDirectChunkSize = 8 * 1024 * 1024;
static const NSInteger YTKACEDirectChunkAttempts = 4;

static NSInteger YTKACEDownloadMethod(void) {
    id stored = YTKACEPreferenceObject(YTKACEDownloadMethodKey);
    if ([stored respondsToSelector:@selector(integerValue)]) return [stored integerValue];
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Downloads.TVClient") ? 2 : 0;
}

BOOL YTKACEDirectDownloadsEnabled(void) {
    return YTKACEDownloadMethod() == 1;
}

BOOL YTKACETVDownloadsEnabled(void) {
    return YTKACEDownloadMethod() == 2;
}

@interface YTKACEDirectTask ()
@property(atomic, assign) BOOL cancelled;
@property(atomic, strong) NSURLSessionTask *currentTask;
@end

@implementation YTKACEDirectTask
- (void)cancel {
    self.cancelled = YES;
    [self.currentTask cancel];
}
@end

static NSError *YTKACEDirectError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"YTKACEDirect" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSDictionary *YTKACEDirectContext(NSString *visitor) {
    NSMutableDictionary *client = [@{
        @"clientName": @"VISIONOS", @"clientVersion": @"1.02",
        @"osName": @"visionOS", @"osVersion": @"26.5.23O471",
        @"deviceMake": @"Apple", @"deviceModel": @"RealityDevice17,1",
        @"userAgent": YTKACEDirectUserAgent,
        @"hl": @"en", @"gl": @"US"} mutableCopy];
    if (visitor.length != 0) client[@"visitorData"] = visitor;
    return @{@"client": client};
}

static NSData *YTKACEDirectFetch(NSURLRequest *request, YTKACEDirectTask *task,
                                 NSInteger *status, NSError **error) {
    __block NSData *result = nil;
    __block NSInteger code = 0;
    __block NSError *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *dataTask = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
            result = data;
            failure = taskError;
            code = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            dispatch_semaphore_signal(done);
        }];
    task.currentTask = dataTask;
    if (task.cancelled) [dataTask cancel];
    else [dataTask resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(90 * NSEC_PER_SEC))) != 0) {
        [dataTask cancel];
        task.currentTask = nil;
        if (error != NULL) *error = YTKACEDirectError(2, @"request timed out");
        if (status != NULL) *status = 0;
        return nil;
    }
    task.currentTask = nil;
    if (status != NULL) *status = code;
    if (error != NULL) *error = failure;
    return result;
}

@interface YTKACEDirectChunkReceiver : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSMutableData *data;
@property(atomic, assign) NSInteger status;
@property(nonatomic, assign) int64_t rangeStart;
@property(nonatomic, assign) int64_t rangeEnd;
@property(nonatomic, assign) int64_t totalLength;
@property(nonatomic, assign) int64_t expectedBytes;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, strong) dispatch_semaphore_t done;
@property(nonatomic, copy) void (^received)(int64_t bytes);
@property(nonatomic, assign) CFAbsoluteTime lastReport;
@property(atomic, assign) CFAbsoluteTime lastActivity;
@end

@implementation YTKACEDirectChunkReceiver

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    (void)dataTask;
    self.status = [response isKindOfClass:NSHTTPURLResponse.class]
        ? ((NSHTTPURLResponse *)response).statusCode : 0;
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    BOOL valid = NO;
    if (self.status == 206) {
        NSString *range = [http valueForHTTPHeaderField:@"Content-Range"] ?: @"";
        NSScanner *scanner = [NSScanner scannerWithString:range];
        scanner.charactersToBeSkipped = nil;
        long long start = -1, end = -1, total = -1;
        valid = [scanner scanString:@"bytes " intoString:nil] &&
            [scanner scanLongLong:&start] && [scanner scanString:@"-" intoString:nil] &&
            [scanner scanLongLong:&end] && [scanner scanString:@"/" intoString:nil] &&
            [scanner scanLongLong:&total] && scanner.isAtEnd &&
            start == self.rangeStart && end >= start && end <= self.rangeEnd && total > end &&
            (self.totalLength <= 0 || self.totalLength == total);
        if (valid) { self.totalLength = total; self.expectedBytes = end - start + 1; }
    } else if (self.status == 200) {
        // A server that ignores Range must never send a whole large video into memory.
        const int64_t length = response.expectedContentLength;
        valid = self.rangeStart == 0 && length > 0 && length <= YTKACEDirectChunkSize &&
            (self.totalLength <= 0 || self.totalLength == length);
        if (valid) { self.totalLength = length; self.expectedBytes = length; }
    }
    if (!valid) self.error = YTKACEDirectError(5, @"Server returned an invalid byte range");
    completionHandler(valid ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    (void)dataTask;
    if ((int64_t)self.data.length + (int64_t)data.length > self.expectedBytes) {
        self.error = YTKACEDirectError(5, @"Server exceeded the requested byte range");
        [dataTask cancel];
        return;
    }
    [self.data appendData:data];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    self.lastActivity = now;
    if (self.received != nil && now - self.lastReport >= 0.1) {
        self.lastReport = now;
        self.received((int64_t)self.data.length);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    (void)session;
    (void)task;
    if (self.error == nil) self.error = error;
    dispatch_semaphore_signal(self.done);
}

@end

static NSData *YTKACEDirectFetchChunk(NSURLRequest *request, YTKACEDirectTask *task,
                                      void (^received)(int64_t bytes),
                                      int64_t start, int64_t end, int64_t *total,
                                      NSInteger *status, NSError **error) {
    YTKACEDirectChunkReceiver *receiver = [YTKACEDirectChunkReceiver new];
    receiver.data = [NSMutableData data];
    receiver.done = dispatch_semaphore_create(0);
    receiver.received = received;
    receiver.rangeStart = start;
    receiver.rangeEnd = end;
    receiver.totalLength = *total;
    NSURLSessionDataTask *dataTask = [NSURLSession.sharedSession dataTaskWithRequest:request];
    dataTask.delegate = receiver;
    task.currentTask = dataTask;
    receiver.lastActivity = CFAbsoluteTimeGetCurrent();
    if (task.cancelled) [dataTask cancel];
    else [dataTask resume];
    // The limit applies to inactivity: a slow link may need longer for a whole chunk.
    BOOL timedOut = NO;
    while (dispatch_semaphore_wait(receiver.done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(5 * NSEC_PER_SEC))) != 0) {
        if (CFAbsoluteTimeGetCurrent() - receiver.lastActivity >= 90.0) {
            [dataTask cancel];
            timedOut = YES;
            break;
        }
    }
    task.currentTask = nil;
    NSError *failure = timedOut ? YTKACEDirectError(2, @"request timed out") : receiver.error;
    if (!timedOut && !failure && (int64_t)receiver.data.length != receiver.expectedBytes)
        failure = YTKACEDirectError(5, @"Incomplete byte range");
    if (!timedOut && !failure) *total = receiver.totalLength;
    if (status != NULL) *status = receiver.status;
    if (error != NULL) *error = failure;
    return failure == nil ? receiver.data : nil;
}

static NSMutableURLRequest *YTKACEDirectAPIRequest(NSString *path, NSDictionary *body,
                                                   NSString *visitor) {
    NSURL *URL = [NSURL URLWithString:
        [@"https://youtubei.googleapis.com/youtubei/v1/" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:YTKACEDirectUserAgent forHTTPHeaderField:@"User-Agent"];
    if (visitor.length != 0) [request setValue:visitor forHTTPHeaderField:@"X-Goog-Visitor-Id"];
    return request;
}

static NSString *YTKACEDirectVisitor(BOOL refresh, YTKACEDirectTask *task) {
    NSDictionary *cached = YTKACEPreferenceObject(YTKACEDirectVisitorKey);
    if (!refresh && [cached isKindOfClass:NSDictionary.class]) {
        NSString *value = cached[@"id"];
        NSNumber *time = cached[@"time"];
        if ([value isKindOfClass:NSString.class] && value.length != 0 &&
            [time isKindOfClass:NSNumber.class] &&
            NSDate.date.timeIntervalSince1970 - time.doubleValue < YTKACEDirectVisitorLifetime) {
            return value;
        }
    }
    NSString *visitor = nil;
    for (NSInteger attempt = 0; attempt < 3 && visitor.length == 0 && !task.cancelled; attempt++) {
        if (attempt > 0) [NSThread sleepForTimeInterval:0.4];
        NSData *data = YTKACEDirectFetch(YTKACEDirectAPIRequest(
            @"guide?prettyPrint=false&fields=responseContext.visitorData",
            @{@"context": YTKACEDirectContext(nil)}, nil), task, NULL, NULL);
        id json = data.length != 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id value = [json isKindOfClass:NSDictionary.class] ? json[@"responseContext"][@"visitorData"] : nil;
        visitor = [value isKindOfClass:NSString.class] ? value : nil;
    }
    if (visitor.length == 0) return nil;
    YTKACESetPreferenceObject(YTKACEDirectVisitorKey,
        @{@"id": visitor, @"time": @(NSDate.date.timeIntervalSince1970)});
    return visitor;
}

static NSArray<YTKACEStreamOption *> *YTKACEDirectOptions(NSString *videoID, YTKACEDirectTask *task,
                                                          NSString **reason) {
    Class responseClass = NSClassFromString(@"YTIPlayerResponse");
    SEL initSelector = NSSelectorFromString(@"initWithData:error:");
    if (responseClass == Nil || ![responseClass instancesRespondToSelector:initSelector]) {
        if (reason != NULL) *reason = @"player response class unavailable";
        return @[];
    }
    for (NSInteger attempt = 0; attempt < 2 && !task.cancelled; attempt++) {
        NSString *visitor = YTKACEDirectVisitor(attempt > 0, task);
        NSDictionary *body = @{@"context": YTKACEDirectContext(visitor), @"videoId": videoID,
                               @"contentCheckOk": @YES, @"racyCheckOk": @YES};
        NSInteger status = 0;
        NSData *proto = YTKACEDirectFetch(
            YTKACEDirectAPIRequest(@"player?alt=proto", body, visitor), task, &status, NULL);
        id response = proto.length != 0
            ? ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
                [responseClass alloc], initSelector, proto, NULL) : nil;
        NSMutableArray<YTKACEStreamOption *> *options = [NSMutableArray array];
        for (YTKACEStreamOption *option in [YTKACEStreamResolver optionsFromPlayerResponse:response]) {
            if (option.URL != nil && option.adaptive) [options addObject:option];
        }
        if (options.count != 0) return options;
        id playability = [response valueForKey:@"playabilityStatus"];
        if (reason != NULL) {
            *reason = [NSString stringWithFormat:@"no direct formats http=%ld reason=%@",
                (long)status, [playability valueForKey:@"reason"] ?: @"none"];
        }
    }
    return @[];
}

static NSString *YTKACEDirectCodec(YTKACEStreamOption *option) {
    NSString *mime = option.mimeType ?: @"";
    NSRange codecs = [mime rangeOfString:@"codecs=\""];
    if (codecs.location == NSNotFound) return mime;
    NSString *rest = [mime substringFromIndex:NSMaxRange(codecs)];
    NSRange dot = [rest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".\""]];
    NSString *family = dot.location == NSNotFound ? rest : [rest substringToIndex:dot.location];
    NSString *container = [mime componentsSeparatedByString:@";"].firstObject ?: @"";
    return [NSString stringWithFormat:@"%@|%@", container, family];
}

static YTKACEStreamOption *YTKACEDirectMatch(NSArray<YTKACEStreamOption *> *options,
                                             YTKACEStreamOption *wanted, BOOL audio) {
    NSMutableArray<YTKACEStreamOption *> *pool = [NSMutableArray array];
    for (YTKACEStreamOption *option in options) {
        if (option.audioOnly == audio) [pool addObject:option];
    }
    if (pool.count == 0) return nil;
    if (wanted == nil) return pool.firstObject;
    BOOL wantsTrack = audio && wanted.audioTrackID.length != 0;
    for (YTKACEStreamOption *option in pool) {
        if (option.itag == wanted.itag &&
            (!wantsTrack || [option.audioTrackID isEqualToString:wanted.audioTrackID])) {
            return option;
        }
    }
    for (YTKACEStreamOption *option in pool) {
        if (option.itag == wanted.itag) return option;
    }
    NSString *codec = YTKACEDirectCodec(wanted);
    for (YTKACEStreamOption *option in pool) {
        if (![YTKACEDirectCodec(option) isEqualToString:codec]) continue;
        if (audio) {
            if (!wantsTrack || [option.audioTrackID isEqualToString:wanted.audioTrackID]) return option;
        } else if (option.height == wanted.height) {
            return option;
        }
    }
    return nil;
}

// One file split into ranges. Every range is queued in a background session up
// front, so iOS keeps fetching them while the app is suspended.
@interface YTKACEDirectTransfer : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, assign) int64_t total;
@property(nonatomic, copy) void (^progress)(int64_t bytes);
@property(nonatomic, strong) dispatch_semaphore_t changed;
@property(nonatomic, strong) NSMutableIndexSet *finished;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *failed;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *written;
@property(nonatomic, assign) CFAbsoluteTime lastReport;
@end

@implementation YTKACEDirectTransfer
- (NSUInteger)chunkCount {
    return (NSUInteger)((self.total + YTKACEDirectChunkSize - 1) / YTKACEDirectChunkSize);
}
- (int64_t)lengthOfChunk:(NSUInteger)index {
    return MIN(YTKACEDirectChunkSize, self.total - (int64_t)index * YTKACEDirectChunkSize);
}
- (NSURL *)fileForChunk:(NSUInteger)index {
    return [self.directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%lu", (unsigned long)index]];
}
@end

@interface YTKACEDirectBackgroundSession : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSString *, YTKACEDirectTransfer *> *transfers;
@end

@implementation YTKACEDirectBackgroundSession

+ (instancetype)shared {
    static YTKACEDirectBackgroundSession *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [YTKACEDirectBackgroundSession new]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _transfers = [NSMutableDictionary dictionary];
        NSString *identifier = [NSBundle.mainBundle.bundleIdentifier ?: @"YTKACE" stringByAppendingString:@".ytkace.direct"];
        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:identifier];
        configuration.discretionary = NO;
        // Nothing here can handle a launch: finished ranges are collected on return to the app.
        configuration.sessionSendsLaunchEvents = NO;
        configuration.HTTPMaximumConnectionsPerHost = 4;
        configuration.timeoutIntervalForResource = 6.0 * 60.0 * 60.0;
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];
        // Ranges left by an earlier launch have no download waiting for them.
        [_session getAllTasksWithCompletionHandler:^(NSArray<NSURLSessionTask *> *tasks) {
            for (NSURLSessionTask *task in tasks) {
                if ([self transferForTask:task index:NULL] == nil) [task cancel];
            }
        }];
    }
    return self;
}

- (YTKACEDirectTransfer *)transferForTask:(NSURLSessionTask *)task index:(NSUInteger *)index {
    NSArray<NSString *> *parts = [task.taskDescription componentsSeparatedByString:@":"];
    if (parts.count != 2) return nil;
    if (index != NULL) *index = (NSUInteger)parts[1].integerValue;
    @synchronized (self.transfers) {
        return self.transfers[parts[0]];
    }
}

- (void)addTransfer:(YTKACEDirectTransfer *)transfer {
    @synchronized (self.transfers) {
        self.transfers[transfer.identifier] = transfer;
    }
}

- (void)fetchChunk:(NSUInteger)index ofTransfer:(YTKACEDirectTransfer *)transfer URL:(NSURL *)URL {
    int64_t start = (int64_t)index * YTKACEDirectChunkSize;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", start, start + [transfer lengthOfChunk:index] - 1]
        forHTTPHeaderField:@"Range"];
    [request setValue:YTKACEDirectUserAgent forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:request];
    task.taskDescription = [NSString stringWithFormat:@"%@:%lu", transfer.identifier, (unsigned long)index];
    [task resume];
}

- (void)removeTransfer:(YTKACEDirectTransfer *)transfer {
    @synchronized (self.transfers) {
        [self.transfers removeObjectForKey:transfer.identifier];
    }
    NSString *prefix = [transfer.identifier stringByAppendingString:@":"];
    [self.session getAllTasksWithCompletionHandler:^(NSArray<NSURLSessionTask *> *tasks) {
        for (NSURLSessionTask *task in tasks) {
            if ([task.taskDescription hasPrefix:prefix]) [task cancel];
        }
    }];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)session;
    (void)bytesWritten;
    (void)totalBytesExpectedToWrite;
    NSUInteger index = 0;
    YTKACEDirectTransfer *transfer = [self transferForTask:task index:&index];
    if (transfer == nil) return;
    int64_t sum = 0;
    @synchronized (transfer) {
        transfer.written[@(index)] = @(totalBytesWritten);
        for (NSNumber *bytes in transfer.written.allValues) sum += bytes.longLongValue;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (transfer.progress != nil && now - transfer.lastReport >= 0.1) {
        transfer.lastReport = now;
        transfer.progress(sum);
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
didFinishDownloadingToURL:(NSURL *)location {
    (void)session;
    NSUInteger index = 0;
    YTKACEDirectTransfer *transfer = [self transferForTask:task index:&index];
    if (transfer == nil) return;
    NSInteger status = [task.response isKindOfClass:NSHTTPURLResponse.class]
        ? ((NSHTTPURLResponse *)task.response).statusCode : 0;
    NSNumber *size = nil;
    [location getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    NSURL *file = [transfer fileForChunk:index];
    [NSFileManager.defaultManager removeItemAtURL:file error:NULL];
    BOOL saved = (status == 206 || status == 200) && size.longLongValue == [transfer lengthOfChunk:index] &&
        [NSFileManager.defaultManager moveItemAtURL:location toURL:file error:NULL];
    @synchronized (transfer) {
        if (saved) [transfer.finished addIndex:index];
        else transfer.failed[@(index)] = @(status);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session;
    (void)error;
    NSUInteger index = 0;
    YTKACEDirectTransfer *transfer = [self transferForTask:task index:&index];
    if (transfer == nil) return;
    @synchronized (transfer) {
        if (![transfer.finished containsIndex:index]) {
            transfer.failed[@(index)] = transfer.failed[@(index)] ?: @0;
            [transfer.written removeObjectForKey:@(index)];
        }
    }
    dispatch_semaphore_signal(transfer.changed);
}

@end

@interface YTKACEDirectJob : NSObject
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) YTKACEDirectTask *task;
@property(nonatomic, copy) NSArray<YTKACEStreamOption *> *options;
@end

@implementation YTKACEDirectJob

- (BOOL)refreshOptions {
    NSString *reason = nil;
    NSArray *options = YTKACEDirectOptions(self.videoID, self.task, &reason);
    if (options.count == 0) {
        YTKACEDownloadLog(self.identifier, @"direct refresh failed %@", reason ?: @"");
        return NO;
    }
    self.options = options;
    return YES;
}

- (BOOL)fetchOptionInBackground:(YTKACEStreamOption *)option
                          audio:(BOOL)audio
                         toFile:(NSURL *)file
                       progress:(void (^)(int64_t bytes))progress
                          error:(NSError **)error {
    YTKACEDirectBackgroundSession *background = YTKACEDirectBackgroundSession.shared;
    YTKACEDirectTransfer *transfer = [YTKACEDirectTransfer new];
    transfer.identifier = NSUUID.UUID.UUIDString;
    transfer.total = (int64_t)option.contentLength;
    transfer.directory = [file.URLByDeletingLastPathComponent URLByAppendingPathComponent:
        [@"parts-" stringByAppendingString:transfer.identifier] isDirectory:YES];
    transfer.progress = progress;
    transfer.changed = dispatch_semaphore_create(0);
    transfer.finished = [NSMutableIndexSet indexSet];
    transfer.failed = [NSMutableDictionary dictionary];
    transfer.written = [NSMutableDictionary dictionary];
    if (![NSFileManager.defaultManager createDirectoryAtURL:transfer.directory
            withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    [background addTransfer:transfer];

    YTKACEStreamOption *current = option;
    NSUInteger count = [transfer chunkCount];
    for (NSUInteger index = 0; index < count; index++) {
        [background fetchChunk:index ofTransfer:transfer URL:current.URL];
    }
    NSMutableDictionary<NSNumber *, NSNumber *> *attempts = [NSMutableDictionary dictionary];
    while (YES) {
        dispatch_semaphore_wait(transfer.changed, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)));
        if (self.task.cancelled) {
            [background removeTransfer:transfer];
            if (error != NULL) *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            return NO;
        }
        NSDictionary<NSNumber *, NSNumber *> *failed = nil;
        NSUInteger finished = 0;
        @synchronized (transfer) {
            failed = [transfer.failed copy];
            [transfer.failed removeAllObjects];
            finished = transfer.finished.count;
        }
        if (finished == count) break;
        for (NSNumber *index in failed) {
            NSInteger attempt = attempts[index].integerValue + 1;
            attempts[index] = @(attempt);
            NSInteger status = failed[index].integerValue;
            YTKACEDownloadLog(self.identifier, @"direct background retry itag=%ld chunk=%@ http=%ld",
                (long)current.itag, index, (long)status);
            if (attempt >= YTKACEDirectChunkAttempts) {
                [background removeTransfer:transfer];
                if (error != NULL) *error = YTKACEDirectError(3, [NSString stringWithFormat:
                    @"chunk %@ failed http=%ld", index, (long)status]);
                return NO;
            }
            if ((status == 403 || status == 410 || attempt == 2) && [self refreshOptions]) {
                YTKACEStreamOption *renewed = YTKACEDirectMatch(self.options, current, audio);
                // Ranges already saved can only be continued from the same format.
                if (renewed != nil && renewed.itag == current.itag) current = renewed;
            }
            [background fetchChunk:index.unsignedIntegerValue ofTransfer:transfer URL:current.URL];
        }
    }
    [background removeTransfer:transfer];

    [NSFileManager.defaultManager createFileAtPath:file.path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:file error:error];
    if (handle == nil) return NO;
    BOOL written = YES;
    NSError *failure = nil;
    for (NSUInteger index = 0; index < count && written; index++) {
        NSURL *part = [transfer fileForChunk:index];
        @autoreleasepool {
            NSError *partError = nil;
            NSData *data = [NSData dataWithContentsOfURL:part options:NSDataReadingMappedIfSafe error:&partError];
            written = data != nil && [handle writeData:data error:&partError];
            failure = partError;
        }
        [NSFileManager.defaultManager removeItemAtURL:part error:NULL];
    }
    [handle closeFile];
    [NSFileManager.defaultManager removeItemAtURL:transfer.directory error:NULL];
    if (!written && error != NULL) *error = failure;
    if (written && progress != nil) progress(transfer.total);
    return written;
}

- (BOOL)downloadOption:(YTKACEStreamOption *)option
                 audio:(BOOL)audio
                toFile:(NSURL *)file
              progress:(void (^)(int64_t bytes))progress
                 error:(NSError **)error {
    if (option.contentLength > 0) {
        return [self fetchOptionInBackground:option audio:audio toFile:file progress:progress error:error];
    }
    [NSFileManager.defaultManager createFileAtPath:file.path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:file error:error];
    if (handle == nil) return NO;
    YTKACEStreamOption *current = option;
    int64_t total = MAX((int64_t)current.contentLength, 0);
    int64_t offset = 0;
    BOOL finished = NO;
    const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    while (!finished) {
      @autoreleasepool {
        if (self.task.cancelled) {
            [handle closeAndReturnError:nil];
            if (error != NULL) *error = [NSError errorWithDomain:NSURLErrorDomain
                code:NSURLErrorCancelled userInfo:nil];
            return NO;
        }
        NSData *chunk = nil;
        NSInteger status = 0;
        for (NSInteger attempt = 0; attempt < YTKACEDirectChunkAttempts && chunk == nil; attempt++) {
            if (self.task.cancelled) break;
            if (attempt > 0) [NSThread sleepForTimeInterval:0.6 * attempt];
            int64_t end = total > 0 ? MIN(offset + YTKACEDirectChunkSize, total) - 1
                                    : offset + YTKACEDirectChunkSize - 1;
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:current.URL];
            [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", offset, end]
                forHTTPHeaderField:@"Range"];
            [request setValue:YTKACEDirectUserAgent forHTTPHeaderField:@"User-Agent"];
            request.timeoutInterval = 45.0;
            NSError *fetchError = nil;
            int64_t chunkStart = offset;
            NSData *data = YTKACEDirectFetchChunk(request, self.task, ^(int64_t bytes) {
                if (progress != nil) progress(chunkStart + bytes);
            }, offset, end, &total, &status, &fetchError);
            BOOL ok = fetchError == nil && data.length != 0;
            if (ok) {
                chunk = data;
                break;
            }
            YTKACEDownloadLog(self.identifier, @"direct chunk retry itag=%ld offset=%lld http=%ld error=%@",
                (long)current.itag, offset, (long)status, fetchError.localizedDescription ?: @"none");
            if ((status == 403 || status == 410 || attempt == 1) && [self refreshOptions]) {
                YTKACEStreamOption *renewed = YTKACEDirectMatch(self.options, current, audio);
                // Bytes already written can only be continued from the same format.
                if (renewed != nil && (offset == 0 || (renewed.itag == current.itag &&
                    [renewed.audioTrackID ?: @"" isEqualToString:current.audioTrackID ?: @""] &&
                    (renewed.contentLength <= 0 || total <= 0 || (int64_t)renewed.contentLength == total)))) {
                    current = renewed;
                    if (offset == 0) total = MAX((int64_t)current.contentLength, 0);
                }
            }
        }
        if (chunk == nil) {
            [handle closeAndReturnError:nil];
            if (error != NULL) {
                *error = self.task.cancelled
                    ? [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]
                    : YTKACEDirectError(3, [NSString stringWithFormat:
                        @"chunk failed at %lld http=%ld", offset, (long)status]);
            }
            return NO;
        }
        if (![handle writeData:chunk error:error]) {
            [handle closeAndReturnError:nil];
            return NO;
        }
        offset += (int64_t)chunk.length;
        if (progress != nil) progress(offset);
        finished = total > 0 ? offset >= total : (int64_t)chunk.length < YTKACEDirectChunkSize;
      }
    }
    if (![handle closeAndReturnError:error]) return NO;
    const CFAbsoluteTime elapsed = MAX(CFAbsoluteTimeGetCurrent() - started, 0.001);
    YTKACEDownloadLog(self.identifier, @"direct %@ bytes=%lld seconds=%.2f speed=%.2fMiB/s",
        audio ? @"audio" : @"video", offset, elapsed, (double)offset / 1048576.0 / elapsed);
    return YES;
}

@end

@implementation YTKACEDirectDownloader

+ (void)fetchOptionsForVideoID:(NSString *)videoID
                    completion:(void (^)(NSArray<YTKACEStreamOption *> *options))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *reason = nil;
        NSArray *options = videoID.length == 0 ? @[] :
            YTKACEDirectOptions(videoID, [YTKACEDirectTask new], &reason);
        YTKACEDownloadLog(@"direct", @"formats video=%@ count=%lu %@", videoID,
            (unsigned long)options.count, reason ?: @"");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(options); });
    });
}

+ (NSString *)codecNameForOption:(YTKACEStreamOption *)option {
    NSString *mime = option.mimeType.lowercaseString ?: @"";
    if ([mime containsString:@"avc1"]) return @"H.264";
    if ([mime containsString:@"av01"]) return @"AV1";
    if ([mime containsString:@"vp9"] || [mime containsString:@"vp09"]) return @"VP9";
    if ([mime containsString:@"opus"]) return @"Opus";
    if ([mime containsString:@"mp4a"]) return @"AAC";
    return [mime componentsSeparatedByString:@";"].firstObject ?: @"";
}

+ (YTKACEDirectTask *)downloadVideoID:(NSString *)videoID
                          videoOption:(YTKACEStreamOption *)videoOption
                          audioOption:(YTKACEStreamOption *)audioOption
                            audioOnly:(BOOL)audioOnly
                           identifier:(NSString *)identifier
                             progress:(YTKACESABRProgress)progress
                           completion:(YTKACESABRCompletion)completion {
    YTKACEDirectTask *task = [YTKACEDirectTask new];
    YTKACEDirectJob *job = [YTKACEDirectJob new];
    job.videoID = videoID;
    job.identifier = identifier;
    job.task = task;
    void (^finish)(NSURL *, NSURL *, NSError *) = ^(NSURL *video, NSURL *audio, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(video, audio, error); });
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (videoID.length == 0) {
            finish(nil, nil, YTKACEDirectError(1, @"missing video id"));
            return;
        }
        if (![job refreshOptions]) {
            finish(nil, nil, YTKACEDirectError(1, @"no direct formats"));
            return;
        }
        YTKACEStreamOption *video = audioOnly ? nil : YTKACEDirectMatch(job.options, videoOption, NO);
        YTKACEStreamOption *audio = YTKACEDirectMatch(job.options, audioOption, YES);
        if (audio == nil || (!audioOnly && video == nil)) {
            finish(nil, nil, YTKACEDirectError(4, @"selected format not offered directly"));
            return;
        }
        YTKACEDownloadLog(identifier, @"direct start video=%ld audio=%ld",
            (long)video.itag, (long)audio.itag);
        NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"YTKACE-%@",
                NSUUID.UUID.UUIDString] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *(^extension)(YTKACEStreamOption *) = ^NSString *(YTKACEStreamOption *option) {
            return [option.mimeType containsString:@"webm"] ? @"webm" :
                ([option.mimeType hasPrefix:@"audio/"] ? @"m4a" : @"mp4");
        };
        NSURL *videoURL = video == nil ? nil : [directory URLByAppendingPathComponent:
            [@"video." stringByAppendingString:extension(video)]];
        NSURL *audioURL = [directory URLByAppendingPathComponent:
            [@"audio." stringByAppendingString:extension(audio)]];
        __block int64_t videoBytes = 0;
        __block int64_t audioBytes = 0;
        int64_t videoTotal = MAX((int64_t)video.contentLength, 1);
        int64_t audioTotal = MAX((int64_t)audio.contentLength, 1);
        void (^report)(NSInteger) = ^(NSInteger phase) {
            if (progress == nil) return;
            double audioProgress = MIN(1.0, (double)audioBytes / (double)audioTotal);
            double videoProgress = MIN(1.0, (double)videoBytes / (double)videoTotal);
            int64_t a = audioBytes, v = videoBytes;
            dispatch_async(dispatch_get_main_queue(), ^{
                progress(audioProgress, videoProgress, a, v, phase);
            });
        };
        NSError *error = nil;
        if (video != nil && ![job downloadOption:video audio:NO toFile:videoURL
                progress:^(int64_t bytes) { videoBytes = bytes; report(0); } error:&error]) {
            [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
            YTKACEDownloadLog(identifier, @"direct video failed %@", error.localizedDescription);
            finish(nil, nil, error);
            return;
        }
        if (![job downloadOption:audio audio:YES toFile:audioURL
                progress:^(int64_t bytes) { audioBytes = bytes; report(1); } error:&error]) {
            [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
            YTKACEDownloadLog(identifier, @"direct audio failed %@", error.localizedDescription);
            finish(nil, nil, error);
            return;
        }
        YTKACEDownloadLog(identifier, @"direct complete video=%lld audio=%lld",
            videoBytes, audioBytes);
        finish(videoURL, audioURL, nil);
    });
    return task;
}

@end
