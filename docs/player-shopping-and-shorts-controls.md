# Player shopping pills and Shorts controls

## Shopping pills

Enable **YTKACE → Player → Hide In-Video Shopping Pills** to hide product shopping cards over the video, including landscape fullscreen. This setting defaults to off and does not enable the broader feed and Shorts product filter.

The player filter uses the existing product renderer, shopping overlay, timely shelf, and view visibility hooks. It also recognizes product-card/pill identifiers and `player_overlay_timely_shelf`, found in the supplied YouTube 21.41.5 binary. Element display views inside the main player use the same option. The existing **Remove Products** setting continues to enable the player filter too.

## Shorts shield

The SponsorBlock submit shield has a transparent background and a small icon shadow, matching the download control. Its 44-point touch target is unchanged. It is centered above Download rather than to its left. With Download hidden, it uses the first visible Shorts action as its anchor; if there is no action, it falls back to the upper right. Coordinates are clamped to the host safe area.

## Verification

Local Python suite: 27 tests passed, four native dependency classes skipped. GitHub Actions performs the full native tests and builds both supported IPA bases.

Device checks still required: toggle shopping pills in a video with tagged products, landscape/portrait fullscreen, verify subtitles and playback controls remain usable, and test the transparent shield with both download positions, downloads disabled, rotation, and the old/new Shorts layouts.
