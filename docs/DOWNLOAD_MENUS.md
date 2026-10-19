# Download and Community menus

The video menu uses expandable rows for thumbnails, captions, information,
transcripts, and external players. Download opens a separate form with codec
tabs, quality and size choices, audio language, captions, SponsorBlock cuts,
and destination. Audio-only mode includes bitrate selection and title/artist
metadata, which is written into the M4A file.

Community posts have their own panel, opened by holding the post. It includes
copy/translate text, save/copy the post as an image, and image actions. When
multiple images are available in the post's loaded nodes, the panel offers
individual images and Save all images. The image viewer's download button
opens the dedicated image actions. These use the existing Save Post Images
and Hold to Copy Text preferences. The post link appears when its ID can be
resolved from YouTube's model.
Both Community actions are enabled by default; explicit saved preferences
remain in effect.

The implementation follows the supplied screenshots and the reference app's
observed menu capabilities. It uses UIKit and SF Symbols; no reference-app
implementation or bundled assets are included.

AV1 and VP9 have an Encoding preset section: Skip conversion preserves the
source codec; Ultra fast, Very fast, and Medium convert to H.264 using the
corresponding x264 presets at CRF 20. Converted video can be sent to Photos.
AV1 currently requires hardware decoding support. VP9 can also be decoded
in software. HDR conversion is rejected with an explicit error rather than
silently producing incorrect colours; its source can be kept with Skip conversion.

Audio export offers M4A/AAC and MP3. AAC and Opus source bitrates are retained
in the quality list. Opus is converted to the requested output format; video
downloads use AAC audio. MP3 export includes title/artist metadata and cover
art. Audio sent to Photos becomes a video with artwork. Source download sizes
are shown separately from the variable size after re-encoding.

Conversion runs on a serial queue, reports progress, and supports cancellation.
SponsorBlock cuts are applied before video/MP3 conversion; captions are adjusted
to the resulting cut timeline. Retry retains the chosen preset and audio format.
The Community menu opens from a hold on either text or a photo, including nested
image cells; ordinary comments are excluded from post detection.

Translate post opens an in-app panel with source/target language selectors,
original text, selectable translated text, and a Copy button. It calls Google's
online translation service directly; no browser or external app is opened.
Long posts are split at Unicode-safe boundaries, stale requests are cancelled
on language changes/dismissal, and failures can be retried inside the panel.

Other fixes included with the interface:

- Stream identity includes the audio track, so dubbed tracks with the same
  itag remain distinct. Equal objects have equal hashes.
- Codec and bitrate choices survive format grouping and asynchronous refresh.
- Format results from one video cannot populate a later video's form.
- An explicit choice to omit captions overrides automatic-caption settings.
- Size totals include audio; bitrate-based estimates are marked with `~`.
- Photo exports request add-only permission and validate downloaded images.
- Menus use native sheet scrolling, dismissal, accessibility, and Dynamic Type.
