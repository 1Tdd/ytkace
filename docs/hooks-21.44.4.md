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

## Still to confirm on a device
These have no clear replacement, so `docs/TESTING.md` covers them:
- `YTHeaderContentComboView` subheader methods: hiding topics also uses `setMaximumSubheaderHeight:`.
- `ASDisplayNode didLoad`: copying comments also uses three other hooks.
- `YTPivotBarView liquidGlassEffect`: the method moved to `+[YTFrostedGlassView liquidGlassEffect]`.
- `setControlsOverlayVisible:` and `setOverlayVisible:`: overlay buttons also follow layout.

## Deliberately not moved
`spamSignalsDictionary` moved to `+[YTAdShieldUtils …]`. It feeds YouTube's ad
integrity checks, so emptying it again could affect playback. Ads are already
blocked without it, so it stays unhooked.
