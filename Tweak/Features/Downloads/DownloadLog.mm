#import "DownloadLog.h"



static const NSUInteger YTKACEDownloadLogLimit = 512 * 1024;

static NSURL *YTKACEDownloadLogURL(void) {
    static NSURL *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSNumber *> *candidates = @[@(NSDocumentDirectory),
                                            @(NSApplicationSupportDirectory),
                                            @(NSCachesDirectory)];
        for (NSNumber *candidate in candidates) {
            NSURL *base = [NSFileManager.defaultManager
                URLsForDirectory:(NSSearchPathDirectory)candidate.unsignedIntegerValue
                       inDomains:NSUserDomainMask].firstObject;
            if (base == nil) continue;
            NSURL *directory = [[base URLByAppendingPathComponent:@"YTKACE" isDirectory:YES]
                URLByAppendingPathComponent:@"Logs" isDirectory:YES];
            NSError *error = nil;
            if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&error]) {
                continue;
            }
            NSURL *probe = [directory URLByAppendingPathComponent:@"downloads.log"];
            if (![NSFileManager.defaultManager fileExistsAtPath:probe.path] &&
                ![[NSData data] writeToURL:probe atomically:YES]) {
                continue;
            }
            cached = probe;
            break;
        }
        if (cached == nil) {
            cached = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:@"ytkace-downloads.log"]];
        }
        [NSUserDefaults.standardUserDefaults setObject:cached.path
                                                forKey:@"YTKACELogPath"];
    });
    return cached;
}

static dispatch_queue_t YTKACEDownloadLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ytkace.download-log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString * const YTKACEDebugLogsKey = @"YTKACE.Preference.Developer.DebugLogs";

BOOL YTKACEDebugLogsEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:YTKACEDebugLogsKey];
}

void YTKACESetDebugLogsEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:YTKACEDebugLogsKey];
}

static void YTKACEWriteLogLine(NSString *identifier, NSString *message);

void YTKACEDownloadLog(NSString *identifier, NSString *format, ...) {
    if (format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    YTKACEWriteLogLine(identifier, message);
}

void YTKACEDebugLog(NSString *identifier, NSString *format, ...) {
    if (format.length == 0 || !YTKACEDebugLogsEnabled()) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    YTKACEWriteLogLine(identifier, message);
}

static void YTKACEWriteLogLine(NSString *identifier, NSString *message) {
    if (message.length > 4096) message = [message substringToIndex:4096];
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
        NSDate.date, identifier.length == 0 ? @"download" : identifier, message];
    dispatch_async(YTKACEDownloadLogQueue(), ^{
        NSURL *URL = YTKACEDownloadLogURL();
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileManager *manager = NSFileManager.defaultManager;
        if (![manager fileExistsAtPath:URL.path]) [manager createFileAtPath:URL.path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:URL error:nil];
        unsigned long long length = 0;
        if (![handle seekToEndReturningOffset:&length error:nil]) { [handle closeAndReturnError:nil]; return; }
        if (length + lineData.length > YTKACEDownloadLogLimit) {
            [handle closeAndReturnError:nil];
            NSData *existing = [NSData dataWithContentsOfURL:URL] ?: NSData.data;
            NSUInteger keep = MIN(existing.length, YTKACEDownloadLogLimit * 3 / 4);
            NSUInteger start = existing.length - keep;
            const uint8_t *bytes = (const uint8_t *)existing.bytes;
            // Keep complete UTF-8 lines so the log remains readable after rotation.
            while (start < existing.length && bytes[start] != '\n') ++start;
            if (start < existing.length) ++start;
            NSData *tail = [existing subdataWithRange:NSMakeRange(start, existing.length - start)];
            if (![tail writeToURL:URL atomically:YES]) return;
            handle = [NSFileHandle fileHandleForWritingToURL:URL error:nil];
            if (![handle seekToEndReturningOffset:&length error:nil]) { [handle closeAndReturnError:nil]; return; }
        }
        [handle writeData:lineData error:nil];
        [handle closeAndReturnError:nil];
    });
}

NSString *YTKACEDownloadLogContents(void) {
    __block NSString *contents = @"No download activity yet.";
    dispatch_sync(YTKACEDownloadLogQueue(), ^{
        NSString *value = [NSString stringWithContentsOfURL:YTKACEDownloadLogURL()
            encoding:NSUTF8StringEncoding error:nil];
        if (value.length != 0) contents = value;
    });
    return contents;
}

void YTKACEClearDownloadLog(void) {
    dispatch_sync(YTKACEDownloadLogQueue(), ^{
        [NSFileManager.defaultManager removeItemAtURL:YTKACEDownloadLogURL() error:nil];
    });
}
