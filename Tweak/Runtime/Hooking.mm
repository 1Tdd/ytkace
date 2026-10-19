#import "Hooking.h"
#include <cstdlib>

#if !defined(YTKACE_HOOK_TEST)
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <string.h>
#import "../Features/Downloads/DownloadLog.h"
#endif

static NSObject *YTKACEHookLock(void) {
    static NSObject *lock = [NSObject new];
    return lock;
}

static NSMutableSet<NSString *> *YTKACEHookKeys(void) {
    static NSMutableSet<NSString *> *keys = [NSMutableSet new];
    return keys;
}

static NSMutableDictionary<NSString *, NSValue *> *YTKACEHookOriginals(void) {
    static NSMutableDictionary *originals = [NSMutableDictionary new];
    return originals;
}

static NSString *YTKACEHookKey(Class cls, SEL selector, BOOL classMethod, IMP replacement) {
    return [NSString stringWithFormat:@"%s|%@|%@|%p", class_getName(cls),
        classMethod ? @"+" : @"-", NSStringFromSelector(selector), (void *)replacement];
}

static BOOL YTKACEHookChainContains(Class cls, SEL selector, BOOL classMethod, IMP current, IMP replacement) {
    for (NSUInteger depth = 0; current != NULL && depth < 128; ++depth) {
        if (current == replacement) return YES;
        NSValue *entry = nil;
        for (Class owner = cls; owner != Nil; owner = class_getSuperclass(owner)) {
            entry = [YTKACEHookOriginals() objectForKey:YTKACEHookKey(owner, selector, classMethod, current)];
            if (entry != nil) break;
        }
        if (entry == nil) return NO;
        current = (IMP)[entry pointerValue];
    }
    return current != NULL;
}

static BOOL YTKACEInstallHook(NSString *className,
                              NSString *selectorName,
                              BOOL classMethod,
                              IMP replacement,
                              IMP *originalStorage) {
    if (className.length == 0 || selectorName.length == 0 || replacement == NULL) {
        return NO;
    }

    Class cls = NSClassFromString(className);
    if (cls == Nil) {
        return NO;
    }

    Class targetClass = classMethod ? object_getClass(cls) : cls;
    if (targetClass == Nil) {
        return NO;
    }

    SEL selector = NSSelectorFromString(selectorName);
    NSString *key = YTKACEHookKey(targetClass, selector, classMethod, replacement);

    @synchronized (YTKACEHookLock()) {
        NSValue *registered = [YTKACEHookOriginals() objectForKey:key];
        if (registered != nil) {
            if (originalStorage != NULL) *originalStorage = (IMP)[registered pointerValue];
            return YES;
        }

        Method method = class_getInstanceMethod(targetClass, selector);
        if (method == NULL) return NO;
        selector = method_getName(method);
        IMP original = method_getImplementation(method);
        const char *types = method_getTypeEncoding(method);
        if (YTKACEHookChainContains(targetClass, selector, classMethod, original, replacement)) return NO;
        if (originalStorage != NULL) *originalStorage = original;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(targetClass, &methodCount);
        Method directMethod = NULL;
        for (unsigned int index = 0; index < methodCount; ++index) {
            if (sel_isEqual(method_getName(methods[index]), selector)) {
                directMethod = methods[index];
                break;
            }
        }
        std::free(methods);
        if (directMethod != NULL) {
            method_setImplementation(directMethod, replacement);
        } else if (!class_addMethod(targetClass, selector, replacement, types)) {
            return NO;
        }

        [YTKACEHookOriginals() setObject:[NSValue valueWithPointer:(const void *)original] forKey:key];
        [YTKACEHookKeys() addObject:key];
        return YES;
    }
}

BOOL YTKACEInstallInstanceHook(NSString *className,
                               NSString *selectorName,
                               IMP replacement,
                               IMP *originalStorage) {
    return YTKACEInstallHook(className, selectorName, NO, replacement, originalStorage);
}

BOOL YTKACEInstallClassHook(NSString *className,
                            NSString *selectorName,
                            IMP replacement,
                            IMP *originalStorage) {
    return YTKACEInstallHook(className, selectorName, YES, replacement, originalStorage);
}

BOOL YTKACEAddInstanceMethod(NSString *className,
                             NSString *selectorName,
                             IMP implementation,
                             const char *typeEncoding) {
    if (className.length == 0 || selectorName.length == 0 ||
        implementation == NULL || typeEncoding == NULL) {
        return NO;
    }

    Class cls = NSClassFromString(className);
    if (cls == Nil) {
        return NO;
    }

    NSString *key = [NSString stringWithFormat:@"%@|add|%@", className, selectorName];
    @synchronized (YTKACEHookLock()) {
        if ([YTKACEHookKeys() containsObject:key]) {
            return YES;
        }

        BOOL added = class_addMethod(cls,
                                     NSSelectorFromString(selectorName),
                                     implementation,
                                     typeEncoding);
        if (added) {
            [YTKACEHookKeys() addObject:key];
        }
        return added;
    }
}

NSUInteger YTKACEInstalledHookCount(void) {
    @synchronized (YTKACEHookLock()) {
        return YTKACEHookKeys().count;
    }
}

#if !defined(YTKACE_HOOK_TEST)
typedef struct {
    void *isa;
    void *superclass;
    void *cacheBuckets;
    void *cacheMask;
    uintptr_t bits;
} YTKACEClassLayout;

static const uintptr_t YTKACESwiftFlags = 3;
static const uintptr_t YTKACEDataMask = 0x00007ffffffffff8UL;
static const uint32_t YTKACERealizedFlag = 1u << 31;

static const char *YTKACESafeClassName(Class cls) {
    if (cls == Nil) return NULL;
    const uintptr_t bits =
        ((const YTKACEClassLayout *)(__bridge const void *)cls)->bits;
    if (bits & YTKACESwiftFlags) return NULL;
    const uintptr_t data = bits & YTKACEDataMask;
    if (data == 0) return NULL;
    if (*(const uint32_t *)data & YTKACERealizedFlag) {
        return class_getName(cls);
    }
    return *(const char *const *)(data + 24);
}

static void YTKACECollectSection(const struct mach_header *header,
                                 const char *segment,
                                 NSMutableArray<NSString *> *names) {
    unsigned long size = 0;
    void *section = getsectiondata(
        (const struct mach_header_64 *)header, segment, "__objc_classlist", &size);
    if (section == NULL) return;
    uintptr_t *list = (uintptr_t *)section;
    for (unsigned long index = 0; index < size / sizeof(uintptr_t); index++) {
        const char *name =
            YTKACESafeClassName((__bridge Class)(void *)list[index]);
        if (name == NULL) continue;
        if (strncmp(name, "_Tt", 3) == 0) continue;
        if (strstr(name, "$s") != NULL) continue;
        NSString *value = [NSString stringWithUTF8String:name];
        if (value.length != 0) [names addObject:value];
    }
}

NSArray<NSString *> *YTKACEAppClassNames(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    const uint32_t imageCount = _dyld_image_count();
    for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
        const char *path = _dyld_get_image_name(imageIndex);
        if (path == NULL) continue;
        if (strstr(path, "/System/") != NULL) continue;
        if (strstr(path, "/usr/lib/") != NULL) continue;
        const struct mach_header *header = _dyld_get_image_header(imageIndex);
        if (header == NULL) continue;
        YTKACECollectSection(header, "__DATA_CONST", names);
        YTKACECollectSection(header, "__AUTH_CONST", names);
        YTKACECollectSection(header, "__DATA", names);
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACEDownloadLog(@"scan", @"%lu objc classes across %u images",
                          (unsigned long)names.count, imageCount);
    });
    return names;
}
#endif
