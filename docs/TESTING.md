# Testing a release

Tests and the build run on every push to `main` and on pull requests. They do
not show that the tweak works in YouTube, so try these on a device with the IPA
before calling a build good. Look in the log for anything unexpected: open
**Download Log** in the About section of the YTKACE settings.

## Startup
- [ ] The app opens without a crash or an unexpected dialog.
- [ ] The log shows `[reload] player path hooked`, not `unavailable`.
- [ ] The `[hooks]` line, written about 40 seconds after launch, lists no new failed hook.

## Playback
- [ ] A video plays; background playback continues after leaving the app.
- [ ] The PiP button opens and closes Picture in Picture.
- [ ] Leaving the app during playback starts PiP automatically.
- [ ] SponsorBlock skips a known segment, and undo works.

## Downloads
- [ ] A video downloads in H.264 and appears in the library.
- [ ] A VP9 or AV1 video downloads with Skip conversion and with an encoding preset.
- [ ] Audio only downloads as M4A and as MP3.
- [ ] Cancelling a running download does not crash.
- [ ] With the Direct method, a download started before leaving the app finishes while
      it is in the background; on return the file is merged and appears in the library.
- [ ] Without a network, a SABR download shows an error within about a minute.
- [ ] Saving to Photos and to the Share Sheet both work.
- [ ] A playlist with a cancelled video counts it as unavailable in the final notice.

## Menus
- [ ] Download sheet: codec tabs, quality strip and size update correctly.
- [ ] Shield button: segments, chapters and full-video labels expand in place.
- [ ] Segment editor: preview plays, the timeline seeks and Cut previews the cut.
- [ ] Community post with several images: the count is right and Save all saves them all.

## Interface
- [ ] The tab bar switches tabs and hides with fullscreen Shorts.
- [ ] The OLED theme gives the expected status bar color.
- [ ] Add to queue works from a video's menu.
- [ ] Shorts play, swipe and show their download button.
- [ ] Holding a comment copies its text.
- [ ] Hiding topics removes the chip bar without leaving a gap.
- [ ] Scrubbing the player bar across a segment does not trigger a skip while dragging.

## After updating the YouTube version
Run the **Hooks** workflow by hand with the new IPA's URL. It lists the hook
targets that no longer exist. Fix them, then accept what is left with:

```bash
python3 Tools/check_hooks.py YouTube.ipa --write-baseline
```
