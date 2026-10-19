#include "DownloadFormatPolicy.h"
#include <cassert>
#include <limits>
#include <string>

using namespace YTKACEDownloadFormats;
int main(int argc, char **argv) {
    assert(argc == 2);
    std::string test = argv[1];
    Identity original{140, 0, 0, 128000, true, "en.original", "audio/mp4", ""};
    Identity other = original;
    if (test == "tracks") {
        other.track = "it.dubbed";
        assert(!equal(original, other));
    } else if (test == "refreshed") {
        other.bitrate = 129000;
        assert(equal(original, other));
        assert(hash(original) == hash(other));
    } else if (test == "quality") {
        other.itag = 141;
        assert(!equal(original, other));
    } else if (test == "missing_itag") {
        original.itag = other.itag = 0;
        assert(equal(original, other));
        assert(hash(original) == hash(other));
        other.bitrate = 256000;
        assert(!equal(original, other));
        other = original; other.mime = "audio/webm";
        assert(!equal(original, other));
    } else if (test == "media_type") {
        other.audioOnly = false;
        assert(!equal(original, other));
    } else if (test == "sizes") {
        assert(estimatedBytes(1234, 128000, 100) == 1234);
        assert(estimatedBytes(0, 128000, 100) == 1600000);
        assert(estimatedBytes(-1, 128000, -100) == 0);
        assert(estimatedBytes(0, 0, 100) == 0);
        assert(estimatedBytes(0, 128000, std::numeric_limits<double>::infinity()) == 0);
        assert(estimatedBytes(0, 128000, std::numeric_limits<double>::quiet_NaN()) == 0);
        assert(estimatedBytes(0, std::numeric_limits<std::int64_t>::max(), 1e20) == 0);
    } else return 2;
}
