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

The form exposes formats supported by YTKACE's current media engine. Audio
export is M4A/AAC. MP3 conversion and the reference app's video encoding
presets are not implemented. AV1 and VP9 options require hardware decoding
support on the device.
These codecs can be saved in Downloads or shared; Photos is offered for
H.264, HEVC, and audio converted to a video with artwork.

Other fixes included with the interface:

- Stream identity includes the audio track, so dubbed tracks with the same
  itag remain distinct. Equal objects have equal hashes.
- Codec and bitrate choices survive format grouping and asynchronous refresh.
- Format results from one video cannot populate a later video's form.
- An explicit choice to omit captions overrides automatic-caption settings.
- Size totals include audio; bitrate-based estimates are marked with `~`.
- Photo exports request add-only permission and validate downloaded images.
- Menus use native sheet scrolling, dismissal, accessibility, and Dynamic Type.
