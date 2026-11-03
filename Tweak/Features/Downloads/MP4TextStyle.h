#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace YTKACEMP4 {
inline uint32_t read32(const unsigned char *p) {
    return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
}
inline bool seek(FILE *file, uint64_t offset) {
    if (offset > INT64_MAX) return false;
#ifdef _WIN32
    return _fseeki64(file, static_cast<int64_t>(offset), SEEK_SET) == 0;
#else
    return fseeko(file, static_cast<off_t>(offset), SEEK_SET) == 0;
#endif
}
// Walk only the sample-description hierarchy. Never scan media payload for "tx3g".
inline bool findStyles(FILE *file, uint64_t start, uint64_t end, unsigned depth,
                       std::vector<uint64_t> &offsets) {
    static const char *path[] = {"moov", "trak", "mdia", "minf", "stbl", "stsd", "tx3g"};
    while (start < end) {
        unsigned char header[16];
        if (end - start < 8 || !seek(file, start) || fread(header, 1, 8, file) != 8) return false;
        uint64_t size = read32(header);
        uint64_t headerSize = 8;
        if (size == 1) {
            if (end - start < 16 || fread(header + 8, 1, 8, file) != 8) return false;
            size = uint64_t(read32(header + 8)) << 32 | read32(header + 12);
            headerSize = 16;
        } else if (size == 0) size = end - start;
        if (size < headerSize || size > end - start) return false;
        if (memcmp(header + 4, path[depth], 4) == 0) {
            if (depth == 6) {
                if (size < headerSize + 38) return false;
                offsets.push_back(start + headerSize + 8);
            } else {
                // stsd: version/flags and entry count precede its sample entries.
                uint64_t prefix = depth == 5 ? 8 : 0;
                if (size < headerSize + prefix ||
                    !findStyles(file, start + headerSize + prefix, start + size, depth + 1, offsets)) return false;
            }
        }
        start += size;
    }
    return true;
}

inline bool patchTextStyle(const char *path, int width, int height) {
    FILE *file = fopen(path, "r+b");
    if (!file) return false;
#ifdef _WIN32
    bool ok = _fseeki64(file, 0, SEEK_END) == 0;
    int64_t length = ok ? _ftelli64(file) : -1;
#else
    bool ok = fseeko(file, 0, SEEK_END) == 0;
    int64_t length = ok ? ftello(file) : -1;
#endif
    std::vector<uint64_t> offsets;
    ok = length >= 8 && findStyles(file, 0, uint64_t(length), 0, offsets) && !offsets.empty();
    unsigned char style[30] = {};
    width = std::clamp(width, 0, 65535);
    height = std::clamp(height, 0, 65535);
    style[4] = 1; style[5] = 0xff;
    style[14] = (height >> 8) & 255; style[15] = height & 255;
    style[16] = (width >> 8) & 255; style[17] = width & 255;
    style[23] = 1; style[25] = std::clamp(height / 20, 16, 72);
    memset(style + 26, 0xff, 4);
    // Validate the entire hierarchy before changing any bytes.
    if (ok) for (uint64_t offset : offsets) {
        if (!seek(file, offset) || fwrite(style, 1, sizeof(style), file) != sizeof(style)) { ok = false; break; }
    }
    if (fclose(file) != 0) ok = false;
    return ok;
}
}
