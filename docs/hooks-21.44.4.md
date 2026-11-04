# Hook targets on YouTube 21.44.4

`Tools/hook_baselines/21.44.4.txt` lists hook targets that the IPA's metadata
does not show. Nothing here is known to break a feature. This is why each group
was accepted; the `[hooks]` log line shows what really failed on a device.

## Probably inherited
Most `maybe-inherited` entries are UIKit methods such as `layoutSubviews` and
`viewDidAppear:`, which the class gets from its system parent. Hooks on them are
added to the class at install time.

## Older versions, with a replacement in use
- `YTHeaderLogoView`, `YTLogoView`: the logo is also hidden through `YTQTMButton`.
- `YTPlayerViewController playerBarDidBeginScrubbing:` and `playerBarDidEndScrubbing:`:
  the overlay scrub hooks set the same state.
- `singleVideo:currentVideoTimeDidChange:`: replaced by
  `potentiallyMutatedSingleVideo:currentVideoTimeDidChange:`, which is hooked.
- `setVideoCountText:…` without `headerHidden:`: a fallback for older versions.
- `+[YTReelContentModel makeContentModelForEntry:]` is hooked; the instance and
  `YTReelDataSource` variants, and `YTReelInfinitePlaybackDataSource`, are older forms.
- `SSOKeychainCore`: `SSOKeychainHelper` provides the same values and is hooked.
- `decorateContext:`: `decorateContext:serviceType:` is hooked on the account-scoped decorator.
- `YTPaidContent*` setters: `hasPaidContentOverlay` and `paidContentOverlay` remove the overlay.

## Candidate names that never matched
The `YTISlimVideo…ActionBarRenderer` array accessors and `YTIElementRenderer contentsArray`
are guesses at protobuf fields that this version does not have.

## Confirmed on a device
These have no direct replacement, but the features work on 21.44.4:
- `ASDisplayNode didLoad`: the runtime hook installs and copying comments works.
- `YTPivotBarView liquidGlassEffect`: the method moved to `+[YTFrostedGlassView liquidGlassEffect]`;
  the tab bar glass options still work.
- `setControlsOverlayVisible:` and `setOverlayVisible:`: overlay buttons follow the controls.
- The OLED theme and removing the startup animation work despite the failed palette and Rive hooks.

## Filter chips
Remove Filter Chips did not work: the bar comes from `YTElementsSubheaderChipBarController`
and `YTFilterChipBarView`, which are hooked now. The `YTHeaderContentComboView`
height methods remain unmatched.

## Deliberately not moved
`spamSignalsDictionary` moved to `+[YTAdShieldUtils …]`. It feeds YouTube's ad
integrity checks, so emptying it again could affect playback. Ads are already
blocked without it, so it stays unhooked.
