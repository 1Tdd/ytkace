#import "YTKACE.h"
#import "Features/Downloads/SABRDownloader.h"
#import "Features/Downloads/DownloadLog.h"
#import "Features/SponsorBlock/DeArrow.h"
#import "Features/SponsorBlock/SponsorThumbnailBadge.h"
#import "Runtime/Hooking.h"
#import "Runtime/Preferences.h"

#import <UIKit/UIKit.h>

#ifndef YTKACE_COMBINED_SABR
#define YTKACE_COMBINED_SABR 0
#endif

NSString * const YTKACEVersion = @YTKACE_VERSION_STRING;

static void YTKACEInstallModules(void) {
    YTKACEInstallSideloadCompatibilityHooks();
    YTKACEInstallCastCompatibilityHooks();
    YTKACEInstallAdsHooks();
    YTKACEInstallPromoHooks();
    YTKACEInstallSponsorBlockHooks();
    YTKACEInstallSponsorThumbnailBadgeHooks();
    YTKACEInstallDeArrow();
    YTKACEInstallOLEDHooks();
    YTKACEInstallStartupHooks();
    YTKACEInstallPremiumLogoHooks();
    YTKACEInstallBackgroundPlaybackHooks();
    YTKACEInstallSpeedHooks();
    YTKACEInstallLoopHooks();
    YTKACEInstallLinkCleaningHooks();
    YTKACEInstallHapticHooks();
    YTKACEInstallAutoplayHooks();
    YTKACEInstallCaptionHooks();
    YTKACEInstallTranscriptHooks();
    YTKACEInstallSleepTimerHooks();
    YTKACEInstallPiPHooks();
    YTKACEInstallPlaybackFixHooks();
    YTKACEInstallDownloadHooks();
    YTKACESABRRestoreSeed();
    YTKACERestorePlayerRequest();
    YTKACEInstallPlaylistDownloaderHooks();
    YTKACEInstallFeedDownloadHooks();
    YTKACEInstallQueueHooks();
    YTKACEInstallGlobalDownloadMiniPlayer();
    YTKACEInstallDoubleTapHooks();
    YTKACEInstallVideoZoomHooks();
    YTKACEInstallShortsLimitHooks();
    YTKACEInstallShortsStartupHooks();
    YTKACEInstallShortsPinchHooks();
    YTKACEInstallShortsPiPHooks();
    YTKACEInstallProgressBarHooks();
    YTKACEInstallStreamingHooks();
    YTKACEInstallHLSPlaybackHooks();
    YTKACEInstallShortsHooks();
    YTKACEInstallTabBarHooks();
    YTKACEInstallNavigationBehaviorHooks();
    YTKACEInstallPlayerGestureHooks();
    YTKACEInstallOverlayVisibilityHooks();
    YTKACEInstallContentVisibilityHooks();
    YTKACEInstallNavigationVisibilityHooks();
    YTKACEInstallMiscellaneousHooks();
    YTKACEInstallCopyCommentHooks();
    YTKACEInstallProfilePictureHooks();
    YTKACEInstallPostImageSaverHooks();
    YTKACEInstallNativeShareHooks();
    YTKACEInstallSettingsEntryHooks();
    YTKACEInstallNativeSettingsHooks();
    // Some hooks retry for about 30 seconds while YouTube loads its services.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSArray<NSString *> *failed = YTKACEFailedHooks();
        YTKACEDownloadLog(@"hooks", @"installed=%lu failed=%lu %@", (unsigned long)YTKACEInstalledHookCount(),
            (unsigned long)failed.count, [failed componentsJoinedByString:@" "]);
    });
}

__attribute__((constructor))
static void YTKACEEntryPoint(void) {
    @autoreleasepool {
        YTKACEClearDownloadLog();
        YTKACERegisterDefaults();
        YTKACEScheduleFirstLaunch();
        YTKACEInstallModules();
    }
}
