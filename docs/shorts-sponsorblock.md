# SponsorBlock in Shorts

Enable **Settings → YTKACE → SponsorBlock → SponsorBlock in Shorts** together with the main SponsorBlock switch. The Shorts option defaults to off.

Shorts uses the existing category settings, automatic/manual skip and mute actions, channel whitelist, skip statistics, and notice preferences. Auto-advance remains controlled by the existing Shorts settings.

Playback changes:

- Resolve Shorts through the current player's controller hierarchy.
- Ignore inactive Shorts players, which YouTube may keep for preloading.
- Reload segments when a reused player changes video, and reject responses from earlier requests, including a rapid A → B → A sequence.
- Restore the original mute state when leaving a clip or disabling the feature.
- Suspend segment actions while the Shorts scrubber is active.
- Reset segment state on loops and backward seeks, preserving the Unskip grace period.
- Bind Skip, Mute, and Unskip notices to the video and request that created them.
- Apply request identity checks to manual segment refreshes too.

English and Italian setting labels are included. Other languages use the English fallback.

## Verification

Local Python suite: 27 tests passed, with four test classes skipped because this Windows environment lacks their native compiler/FFmpeg dependencies. GitHub Actions runs the full native suite and builds both supported IPA bases.

Device checks still required:

1. With Shorts support off, ordinary videos retain SponsorBlock and Shorts play normally.
2. With both switches on, play a Short with known automatic skip and mute segments.
3. Test manual Skip/Mute and Unskip, then swipe while the notice is visible.
4. Swipe rapidly between clips while segment requests are pending; return to the first clip.
5. Let a Short loop, seek backward, and drag the scrubber through a segment.
6. Turn off the Shorts or main switch during a mute segment; confirm the previous volume state returns.
7. Check a whitelisted channel and the existing Shorts auto-advance/loop controls.

No physical-device playback or performance measurements were made in the development environment.
