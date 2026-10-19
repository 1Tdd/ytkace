# Compatibility

## Supplied baseline

The IPA workflow provides YouTube 21.33.6 for iOS 16 and YouTube 21.41.5 for
iOS 17 and newer. The supplied 21.41.5 executable is decrypted and arm64,
with a minimum deployment version of iOS 17.0. Changing Info.plist alone
cannot lower the OS requirement.

The YTKACE dylib itself targets iOS 15 and can be repacked into an older
YouTube baseline that also targets iOS 15.

## Architectures

YTKACE builds arm64. The supplied YouTube executable is arm64, including on
devices that support arm64e.

## YouTube updates

YouTube's internal classes are private and can change without notice. Hooks
resolve classes and selectors at runtime and fail closed. A missing class
disables one feature instead of terminating the app.

The 21.41.5 audit checked the executable's Objective-C method signatures.
Its player view controller exposes `setMuted:` but no mute getter or `player`
accessor. SponsorBlock resolves the active video controller through the
playback controller and sequencer, and accepts only boolean mute methods.
Features that hook the same method chain their implementations in install
order; repeating a registration does not insert it again.

## Install paths

The same repacked IPA can be installed through TrollStore, AppSync-compatible
installers, or re-signed by a developer-certificate sideloader. No runtime
injection environment is required.
