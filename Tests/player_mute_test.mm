#import "../Tweak/Runtime/PlayerMute.h"
#include <cassert>
#include <cstdio>

@interface TestMutePlayer : NSObject {
    BOOL _muted;
}
- (BOOL)muted;
- (void)setMuted:(BOOL)muted;
@end
@implementation TestMutePlayer
- (BOOL)muted { return _muted; }
- (void)setMuted:(BOOL)muted { _muted = muted; }
@end

@interface TestIsMutedPlayer : TestMutePlayer
- (BOOL)isMuted;
@end
@implementation TestIsMutedPlayer
- (BOOL)isMuted { return [self muted]; }
@end

@interface TestMuteController : NSObject {
    id _playbackController;
    id _videoSequencer;
    id _activeVideoController;
    int _player;
}
- (void)connect:(id)child field:(const char *)field;
@end
@implementation TestMuteController
- (void)connect:(id)child field:(const char *)field {
    object_setIvar(self, class_getInstanceVariable([self class], field), child);
}
@end

@interface InvalidMutePlayer : NSObject
- (id)isMuted;
- (void)setMuted:(id)muted;
- (double)player;
@end
@implementation InvalidMutePlayer
- (id)isMuted { assert(false); return nil; }
- (void)setMuted:(id)muted { (void)muted; assert(false); }
- (double)player { assert(false); return 0; }
@end

@interface InvalidMuteSetter : NSObject
- (BOOL)isMuted;
- (void)setMuted:(id)muted;
@end
@implementation InvalidMuteSetter
- (BOOL)isMuted { return NO; }
- (void)setMuted:(id)muted { (void)muted; assert(false); }
@end

int main(void) {
    @autoreleasepool {
        TestMutePlayer *player = [TestMutePlayer new];
        TestMuteController *root = [TestMuteController new];
        TestMuteController *playback = [TestMuteController new];
        TestMuteController *sequencer = [TestMuteController new];
        [root connect:playback field:"_playbackController"];
        [playback connect:sequencer field:"_videoSequencer"];
        [sequencer connect:player field:"_activeVideoController"];
        assert(YTKACEPlayerMuteTarget(root) == player);
        BOOL original = YTKACEReadPlayerMuted(player);
        assert(!original);
        YTKACESetPlayerMuted(player, YES);
        assert(YTKACEReadPlayerMuted(player));
        YTKACESetPlayerMuted(player, original);
        assert(!YTKACEReadPlayerMuted(player));

        [player setMuted:YES];
        original = YTKACEReadPlayerMuted(player);
        YTKACESetPlayerMuted(player, YES);
        YTKACESetPlayerMuted(player, original);
        assert(YTKACEReadPlayerMuted(player));

        TestIsMutedPlayer *singleVideo = [TestIsMutedPlayer new];
        assert(YTKACEPlayerMuteTarget(singleVideo) == singleVideo);
        YTKACESetPlayerMuted(singleVideo, YES);
        assert(YTKACEReadPlayerMuted(singleVideo));
        assert(YTKACEPlayerMuteTarget([InvalidMutePlayer new]) == nil);
        assert(YTKACEPlayerMuteTarget([InvalidMuteSetter new]) == nil);
        assert(YTKACEPlayerMuteTarget(nil) == nil);
        [sequencer connect:root field:"_activeVideoController"];
        assert(YTKACEPlayerMuteTarget(root) == nil);
        puts("Nested mute targets, saved mute state, invalid signatures, and cycles passed.");
    }
}
