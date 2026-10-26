# Upstream sync — 26 October 2026

Merged upstream `itzzace/ytkace` main through `7ee3429`, starting from our `9216055`.

Included: tab handling for YouTube's glass bar, startup selection when Home is hidden, previous/next button visibility fixes, copied/shared link cleaning, video overflow menu visibility options, and optional AiSList channel reporting. Version metadata is updated to 1.1.4 and the iOS 17 IPA base to YouTube 21.42.4; iOS 16 remains on 21.33.6. Our workflow's fallback URL matches the new default input.

As requested, the upstream SponsorBlock implementation is excluded. The entire `Tweak/Features/SponsorBlock` directory is identical to our pre-merge version, and no upstream `SponsorMenu` module, initialization, declaration, setting, or new SponsorBlock-only translations is included. Our submission editor, previews, votes, channel whitelist, Shorts support, and button placement remain intact.

Shared sheet presentation helpers include upstream improvements also used by AiSList and other menus. They do not install another SponsorBlock interface.

Integration adjustment: the upstream previous/next view lookup now checks for absent or non-object ivars and verifies the resulting value is a UIView, avoiding invalid accesses on different YouTube versions. Our existing cached overlay matching and shopping visibility fixes are preserved.

Validation: local Python suite and GitHub Actions native tests, both tweak variants and IPA bases. Device checks remain needed for YouTube 21.42.4, especially tab selection, overflow menus, and the existing SponsorBlock controls.
