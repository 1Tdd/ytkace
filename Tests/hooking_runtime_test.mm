#import "../Tweak/Runtime/Hooking.h"
#include <cassert>
#include <cstdio>

@interface HookParent : NSObject
- (NSInteger)value;
+ (NSInteger)classValue;
@end
@implementation HookParent
- (NSInteger)value { return 1; }
+ (NSInteger)classValue { return 10; }
@end

@interface HookChild : HookParent
@end
@implementation HookChild
@end

static IMP firstOriginal, secondOriginal, childOriginal;
static IMP classFirstOriginal, classSecondOriginal;

static NSInteger first(id self, SEL selector) {
    assert(firstOriginal != NULL);
    return ((NSInteger (*)(id, SEL))firstOriginal)(self, selector) + 2;
}
static NSInteger second(id self, SEL selector) {
    return ((NSInteger (*)(id, SEL))secondOriginal)(self, selector) * 3;
}
static NSInteger child(id self, SEL selector) {
    return ((NSInteger (*)(id, SEL))childOriginal)(self, selector) + 100;
}
static NSInteger classFirst(id self, SEL selector) {
    return ((NSInteger (*)(id, SEL))classFirstOriginal)(self, selector) + 5;
}
static NSInteger classSecond(id self, SEL selector) {
    return ((NSInteger (*)(id, SEL))classSecondOriginal)(self, selector) * 2;
}

int main(void) {
    @autoreleasepool {
        HookParent *parent = [HookParent new];
        HookChild *instance = [HookChild new];
        assert([parent value] == 1);
        assert(YTKACEInstallInstanceHook(@"HookParent", @"value", (IMP)first, &firstOriginal));
        assert([parent value] == 3);
        assert(YTKACEInstallInstanceHook(@"HookParent", @"value", (IMP)second, &secondOriginal));
        assert([parent value] == 9);

        NSUInteger count = YTKACEInstalledHookCount();
        IMP original = NULL;
        assert(YTKACEInstallInstanceHook(@"HookParent", @"value", (IMP)first, &original));
        assert(original == firstOriginal);
        assert([parent value] == 9);
        assert(YTKACEInstalledHookCount() == count);

        assert([instance value] == 9);
        assert(YTKACEInstallInstanceHook(@"HookChild", @"value", (IMP)child, &childOriginal));
        assert([instance value] == 109);
        assert([parent value] == 9);

        // Reusing an inherited callback would put it in its own call chain.
        original = NULL;
        assert(!YTKACEInstallInstanceHook(@"HookChild", @"value", (IMP)first, &original));
        assert(original == NULL);
        assert([instance value] == 109);
        assert([parent value] == 9);

        assert([HookParent classValue] == 10);
        assert(YTKACEInstallClassHook(@"HookParent", @"classValue", (IMP)classFirst, &classFirstOriginal));
        assert([HookParent classValue] == 15);
        assert(YTKACEInstallClassHook(@"HookParent", @"classValue", (IMP)classSecond, &classSecondOriginal));
        if ([HookParent classValue] != 30) {
            fprintf(stderr, "Class hook returned %ld; original methods return %ld and %ld.\n",
                (long)[HookParent classValue],
                (long)((NSInteger (*)(id, SEL))classFirstOriginal)([HookParent class], @selector(classValue)),
                (long)((NSInteger (*)(id, SEL))classSecondOriginal)([HookParent class], @selector(classValue)));
        }
        assert([HookParent classValue] == 30);
        original = NULL;
        assert(YTKACEInstallClassHook(@"HookParent", @"classValue", (IMP)classFirst, &original));
        assert(original == classFirstOriginal);
        assert([HookParent classValue] == 30);

        original = NULL;
        assert(!YTKACEInstallInstanceHook(@"MissingClass", @"value", (IMP)first, &original));
        assert(!YTKACEInstallInstanceHook(@"HookParent", @"missingSelector", (IMP)first, &original));
        assert(original == NULL);
        puts("Hook chaining, repeat registration, inheritance, class methods, and missing targets passed.");
    }
}
