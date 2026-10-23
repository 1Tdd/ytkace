#include "ShortsSubmitPlacement.h"
#include <cassert>

using YTKACEShorts::Rect;
using YTKACEShorts::submitFrame;

static bool overlaps(Rect a, Rect b) {
    return a.x < b.x + b.width && a.x + a.width > b.x &&
        a.y < b.y + b.height && a.y + a.height > b.y;
}

int main() {
    for (double width : {320.0, 390.0, 844.0}) {
        Rect area{8, 55, width - 16, 700};
        Rect download{width - 48, 112, 36, 36};
        Rect top = submitFrame(area, download, true, true);
        assert(!overlaps(top, download));
        assert(top.y + top.height / 2 == download.y + download.height / 2);
        assert(top.x + top.width < download.x);
        assert(top.y >= 100); // Stays below the Shorts header.

        download.y = 430;
        Rect rail = submitFrame(area, download, true, false);
        assert(!overlaps(rail, download));
        assert(rail.x + rail.width / 2 == download.x + download.width / 2);
        assert(rail.y + rail.height < download.y);

        Rect action{width - 54, 500, 44, 60};
        Rect noDownload = submitFrame(area, action, true, false);
        assert(!overlaps(noDownload, action));
        Rect fallback = submitFrame(area, {}, false, false);
        assert(fallback.x >= area.x && fallback.x + 44 <= area.x + area.width);
        assert(fallback.y >= area.y && fallback.y + 44 <= area.y + area.height);
    }
    Rect clamped = submitFrame({8, 55, 304, 700}, {-20, 0, 36, 36}, true, true);
    assert(clamped.x == 8 && clamped.y == 55);
}
