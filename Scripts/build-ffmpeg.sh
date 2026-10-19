#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
SDK="${SDK:-$THEOS/sdks/iPhoneOS16.5.sdk}"
if [[ ! -d "$SDK" ]]; then
    SDK="$(find "$THEOS/sdks" -maxdepth 1 -type d -name 'iPhoneOS*.sdk' | sort -V | tail -1)"
    if [[ -z "$SDK" ]]; then SDK="$(xcrun -sdk iphoneos --show-sdk-path)"; fi
fi
TOOLCHAIN="$THEOS/toolchain/linux/iphone/bin"
if [[ ! -x "$TOOLCHAIN/clang" ]] || ! "$TOOLCHAIN/clang" --version >/dev/null 2>&1; then
    TOOLCHAIN="$(dirname "$(xcrun -sdk iphoneos -f clang)")"
fi
# LLVM's archive tools handle Mach-O on Linux without cctools' missing
# aarch64-prefixed ranlib helper.
ARCHIVER="$(command -v llvm-ar || printf '%s' "$TOOLCHAIN/ar")"
INDEXER="$(command -v llvm-ranlib || printf '%s' "$TOOLCHAIN/ranlib")"
VERSION="${FFMPEG_VERSION:-8.1.2}"
MINOS="${FFMPEG_MIN_IOS:-15.0}"
BUILD="$ROOT/.build/ffmpeg"
SOURCE="$BUILD/ffmpeg-$VERSION"
OUTPUT="$ROOT/Vendor/FFmpeg"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)}"
X264_REV=31e19f92f00c7003fa115047ce50978bc98c3a0d
DEPS="$BUILD/deps"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"

mkdir -p "$BUILD" "$OUTPUT/lib"
mkdir -p "$DEPS"
if [[ ! -f "$BUILD/lame-3.100.tar.gz" ]]; then
    curl -L --fail --retry 3 --retry-all-errors https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz -o "$BUILD/lame-3.100.tar.gz"
fi
echo "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e  $BUILD/lame-3.100.tar.gz" | shasum -a 256 -c -
if [[ ! -d "$BUILD/lame-3.100" ]]; then tar -xf "$BUILD/lame-3.100.tar.gz" -C "$BUILD"; fi
if [[ ! -f "$BUILD/x264-$X264_REV.tar.gz" ]]; then
    curl -L --fail --retry 3 --retry-all-errors "https://codeload.github.com/mirror/x264/tar.gz/$X264_REV" -o "$BUILD/x264-$X264_REV.tar.gz"
fi
if [[ ! -d "$BUILD/x264-$X264_REV" ]]; then tar -xf "$BUILD/x264-$X264_REV.tar.gz" -C "$BUILD"; fi
(
    export CC="$TOOLCHAIN/clang" AR="$ARCHIVER" RANLIB="$INDEXER"
    export CFLAGS="-target arm64-apple-ios$MINOS -isysroot $SDK -miphoneos-version-min=$MINOS -fPIC -O2"
    export LDFLAGS="$CFLAGS"
    cd "$BUILD/lame-3.100"
    ./configure --host=aarch64-apple-darwin --prefix="$DEPS" --enable-static --disable-shared --disable-frontend --disable-decoder --disable-asm
    make -j"$JOBS"; make install
    cd "$BUILD/x264-$X264_REV"
    ./configure --host=aarch64-apple-darwin --prefix="$DEPS" --enable-static --enable-pic --disable-cli --disable-asm --disable-opencl --bit-depth=8 \
        --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" --sysroot="$SDK"
    make -j"$JOBS"; make install
)
if [[ ! -f "$BUILD/ffmpeg-$VERSION.tar.xz" ]]; then
    curl -L --fail --retry 3 --retry-all-errors "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" \
        -o "$BUILD/ffmpeg-$VERSION.tar.xz"
fi
if [[ ! -d "$SOURCE" ]]; then
    tar -xf "$BUILD/ffmpeg-$VERSION.tar.xz" -C "$BUILD"
fi

build_arch() {
    local arch="$1"
    local target="$2"
    local directory="$BUILD/build-$arch"
    local prefix="$BUILD/install-$arch"
    rm -rf "$directory" "$prefix"
    mkdir -p "$directory" "$prefix"
    cd "$directory"
    "$SOURCE/configure" \
        --prefix="$prefix" \
        --target-os=darwin \
        --arch=aarch64 \
        --enable-cross-compile \
        --sysroot="$SDK" \
        --cc="$TOOLCHAIN/clang" \
        --cxx="$TOOLCHAIN/clang++" \
        --ar="$ARCHIVER" \
        --ranlib="$INDEXER" \
        --nm="$TOOLCHAIN/nm" \
        --strip="$TOOLCHAIN/strip" \
        --extra-cflags="-target $target -isysroot $SDK -miphoneos-version-min=$MINOS -fPIC -fvisibility=hidden -I$DEPS/include" \
        --extra-cxxflags="-target $target -isysroot $SDK -miphoneos-version-min=$MINOS -fPIC -fvisibility=hidden" \
        --extra-ldflags="-target $target -isysroot $SDK -miphoneos-version-min=$MINOS -L$DEPS/lib" \
        --pkg-config=pkg-config \
        --enable-static \
        --disable-shared \
        --enable-pic \
        --enable-small \
        --disable-asm \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-autodetect \
        --disable-network \
        --disable-everything \
        --enable-avutil \
        --enable-avcodec \
        --enable-avformat \
        --disable-avdevice \
        --disable-avfilter \
        --enable-swscale \
        --enable-swresample \
        --enable-gpl \
        --enable-libx264 \
        --enable-libmp3lame \
        --enable-protocol=file \
        --enable-demuxer=mov,matroska,image2,mp3 \
        --enable-muxer=mp4,mp3,matroska \
        --enable-bsf=aac_adtstoasc \
        --enable-parser=h264,hevc,vp9,av1,aac,opus,mpegaudio,mjpeg,png \
        --enable-decoder=h264,hevc,vp9,av1,aac,opus,mp3float,mjpeg,png \
        --enable-encoder=h264_videotoolbox,hevc_videotoolbox,libx264,libmp3lame,aac \
        --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,vp9_videotoolbox,av1_videotoolbox \
        --disable-iconv \
        --disable-zlib \
        --disable-bzlib \
        --disable-lzma \
        --disable-securetransport \
        --enable-videotoolbox \
        --disable-audiotoolbox \
        --disable-avfoundation
    make -j"$JOBS"
    make install
}

build_arch arm64 "arm64-apple-ios$MINOS"

rm -rf "$OUTPUT/include"
cp -R "$BUILD/install-arm64/include" "$OUTPUT/include"
for library in avformat avcodec avutil swscale swresample; do
    cp "$BUILD/install-arm64/lib/lib$library.a" "$OUTPUT/lib/lib$library.a"
done
cp "$DEPS/lib/libx264.a" "$DEPS/lib/libmp3lame.a" "$OUTPUT/lib/"
cp "$BUILD/x264-$X264_REV/COPYING" "$OUTPUT/COPYING.x264"
cp "$BUILD/lame-3.100/COPYING" "$OUTPUT/COPYING.LAME"
cp "$SOURCE/COPYING.GPLv2" "$OUTPUT/COPYING.GPLv2"
cp "$SOURCE/COPYING.LGPLv2.1" "$OUTPUT/COPYING.LGPLv2.1"
cp "$SOURCE/COPYING.LGPLv3" "$OUTPUT/COPYING.LGPLv3"
