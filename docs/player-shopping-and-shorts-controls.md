# Player shopping pills and Shorts controls

## Shopping pills

Enable **YTKACE → Watch Page → Remove Products** to hide product shopping cards over the video, including landscape fullscreen, along with shopping/product tags in Shorts and feeds. There is one product visibility switch.

The player filter uses the existing product renderer, shopping overlay, timely shelf, and view visibility hooks. It also recognizes product-card/pill identifiers and `player_overlay_timely_shelf`, found in the supplied YouTube 21.41.5 binary. Element display views inside the main player use the same option.

The separate player-only shopping-pill toggle was added in our fork and has been removed. If it was enabled, its state migrates to **Remove Products** on the next launch. The original Remove Products setting predates that fork change. All shopping-pill detection improvements remain enabled by the single switch.

## Shorts shield

The SponsorBlock submit shield has a transparent background and a small icon shadow, matching the download control. Its 44-point touch target is unchanged. In the side action column, it is centered above Download. With Download at the top, the shield sits to its left on the same row, keeping it below the Shorts header and away from its touch controls. With Download hidden, it uses the first visible Shorts action as its anchor; if there is no action, it falls back to the upper right. Coordinates are clamped to the host safe area.

The placement regression test exercises top and side positions, hidden downloads, different widths/rotation, safe-area clamping, and non-overlapping touch targets using the same geometry function as the app.

## Verification

Local Python suite: 27 tests passed, four native dependency classes skipped. GitHub Actions performs the full native tests and builds both supported IPA bases.

Device checks still required: toggle shopping pills in a video with tagged products, landscape/portrait fullscreen, verify subtitles and playback controls remain usable, and test the transparent shield with both download positions, downloads disabled, rotation, and the old/new Shorts layouts.
