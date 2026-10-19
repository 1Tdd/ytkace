#pragma once
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <string>

namespace YTKACEDownloadFormats {
struct Identity {
    std::int64_t itag = 0, width = 0, height = 0, bitrate = 0;
    bool audioOnly = false;
    std::string track, mime, quality;
};

inline bool equal(const Identity &a, const Identity &b) {
    if (a.audioOnly != b.audioOnly || a.track != b.track) return false;
    if (a.itag > 0 || b.itag > 0) return a.itag == b.itag;
    return a.width == b.width && a.height == b.height && a.bitrate == b.bitrate &&
        a.mime == b.mime && a.quality == b.quality;
}

inline std::size_t hash(const Identity &a) {
    std::size_t value = std::hash<std::int64_t>{}(a.itag) ^ std::hash<std::string>{}(a.track) ^ a.audioOnly;
    if (a.itag > 0) return value;
    return value ^ std::hash<std::int64_t>{}(a.width) ^ std::hash<std::int64_t>{}(a.height) ^
        std::hash<std::int64_t>{}(a.bitrate) ^ std::hash<std::string>{}(a.mime) ^ std::hash<std::string>{}(a.quality);
}

inline std::int64_t estimatedBytes(std::int64_t length, std::int64_t bitrate, double duration) {
    if (length > 0) return length;
    if (bitrate <= 0 || !std::isfinite(duration) || duration <= 0) return 0;
    long double bytes = static_cast<long double>(bitrate) * duration / 8;
    if (bytes >= std::ldexp(1.0L, 63)) return 0;
    return static_cast<std::int64_t>(bytes);
}
}
