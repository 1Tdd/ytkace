#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <cstring>

static inline const char *YTKACEUnqualifiedType(const char *type) {
    while (type != nullptr && *type != '\0' && std::strchr("rnNoORV", *type)) ++type;
    return type;
}

static inline BOOL YTKACEBooleanType(const char *type) {
    type = YTKACEUnqualifiedType(type);
    return type != nullptr && (type[0] == 'B' || type[0] == 'c' ||
        std::strcmp(type, @encode(BOOL)) == 0);
}

static inline SEL YTKACEPlayerMuteGetter(id target) {
    for (NSString *name in @[@"isMuted", @"muted"]) {
        SEL selector = NSSelectorFromString(name);
        NSMethodSignature *signature = [target methodSignatureForSelector:selector];
        if ([target respondsToSelector:selector] && signature.numberOfArguments == 2 &&
            YTKACEBooleanType(signature.methodReturnType)) return selector;
    }
    return nullptr;
}

static inline BOOL YTKACEPlayerHasMuteSetter(id target) {
    SEL selector = NSSelectorFromString(@"setMuted:");
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    const char *result = YTKACEUnqualifiedType(signature.methodReturnType);
    return [target respondsToSelector:selector] && signature.numberOfArguments == 3 &&
        result != nullptr && result[0] == 'v' &&
        YTKACEBooleanType([signature getArgumentTypeAtIndex:2]);
}

static inline id YTKACEPlayerMuteTarget(id root) {
    if (root == nil) return nil;
    NSMutableArray *pending = [NSMutableArray arrayWithObject:root];
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (NSUInteger index = 0; index < pending.count && index < 24; ++index) {
        id target = [pending objectAtIndex:index];
        if ([visited containsObject:target]) continue;
        [visited addObject:target];
        if (YTKACEPlayerMuteGetter(target) && YTKACEPlayerHasMuteSetter(target)) return target;

        for (NSString *name in @[@"activeVideoController", @"player"]) {
            SEL selector = NSSelectorFromString(name);
            NSMethodSignature *signature = [target methodSignatureForSelector:selector];
            const char *result = YTKACEUnqualifiedType(signature.methodReturnType);
            if (![target respondsToSelector:selector] || signature.numberOfArguments != 2 ||
                result == nullptr || result[0] != '@') continue;
            id child = ((id (*)(id, SEL))[target methodForSelector:selector])(target, selector);
            if (child != nil && ![visited containsObject:child]) [pending addObject:child];
        }
        // YouTube 21.41.5 keeps its player behind the playback controller and sequencer.
        for (NSString *name in @[@"_playbackController", @"_videoSequencer", @"_activeVideoController", @"_player"]) {
            Ivar ivar = class_getInstanceVariable(object_getClass(target), name.UTF8String);
            const char *type = ivar ? YTKACEUnqualifiedType(ivar_getTypeEncoding(ivar)) : nullptr;
            if (type == nullptr || type[0] != '@') continue;
            id child = object_getIvar(target, ivar);
            if (child != nil && ![visited containsObject:child]) [pending addObject:child];
        }
    }
    return nil;
}

static inline BOOL YTKACEReadPlayerMuted(id target) {
    SEL selector = YTKACEPlayerMuteGetter(target);
    return selector ? ((BOOL (*)(id, SEL))[target methodForSelector:selector])(target, selector) : NO;
}

static inline void YTKACESetPlayerMuted(id target, BOOL muted) {
    if (!YTKACEPlayerHasMuteSetter(target)) return;
    SEL selector = NSSelectorFromString(@"setMuted:");
    ((void (*)(id, SEL, BOOL))[target methodForSelector:selector])(target, selector, muted);
}
