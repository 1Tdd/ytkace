# Upstream sync — 23 October 2026

Merged `itzzace/ytkace` main through `1afd955` into our main branch, starting from `0b31238`.

Included upstream changes:

- Tab-bar glass modes: Default, YTKACE, YouTube, and Off, with restart handling and compatibility with the former glass toggle.
- Independent keep switches for Shorts shelves in Home, Subscriptions, Search, and channel pages.
- Mix filtering per feed entry instead of dropping an entire section.
- Fullscreen action-bar sizing fixes when its controls are hidden.
- Channel browse-ID detection updates.
- Signed-in playlist requests include the selected channel/account context.

Conflict resolution:

- Kept our existing translations and appended the upstream glass explanation in all 16 languages.
- Kept our create-button visibility guard alongside the upstream glass implementation.
- Combined upstream playlist account handling with our YouTube 21.41.5 fallback version.

Our SponsorBlock preview and Shorts features, Shorts submission control positioning, shopping-pill setting, Community menus and in-app translation, download menus and encoding presets, hardware conversion, runtime hook fixes, and build workflows remain in the merged tree.

Local validation: 27 Python tests passed; four native dependency classes skipped on Windows. The full native suite and both IPA bases are built by GitHub Actions. Playback and visual checks on a physical device remain required.
