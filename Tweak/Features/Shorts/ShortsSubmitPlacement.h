#pragma once
#include <algorithm>

namespace YTKACEShorts {
struct Rect { double x, y, width, height; };

// Top Download shares a row with Submit; the action rail stacks them vertically.
inline Rect submitFrame(Rect available, Rect anchor, bool hasAnchor, bool topDownload) {
    constexpr double size = 44.0;
    double x = available.x + available.width - size;
    double y = available.y + 56.0;
    if (hasAnchor) {
        x = topDownload ? anchor.x - size - 8.0
                        : anchor.x + anchor.width / 2.0 - size / 2.0;
        y = topDownload ? anchor.y + anchor.height / 2.0 - size / 2.0
                        : anchor.y - size - 8.0;
    }
    x = std::max(available.x, std::min(x, available.x + available.width - size));
    y = std::max(available.y, std::min(y, available.y + available.height - size));
    return {x, y, size, size};
}
}
