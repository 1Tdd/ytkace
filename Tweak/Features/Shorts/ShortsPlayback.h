#import <Foundation/Foundation.h>

// Resolve through the player hierarchy, never through a global visible overlay:
// YouTube can keep the previous and next Shorts players alive simultaneously.
BOOL YTKACEResolveShortsPlayback(id player, NSString **videoID);
BOOL YTKACEShortsPlayerIsScrubbing(id player);
