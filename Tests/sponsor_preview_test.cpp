#include "SponsorPreview.h"
#include <cassert>
#include <limits>
#include <string>

using Preview = YTKACESponsorPreview;
using Action = Preview::Action;
using Phase = Preview::Phase;

int main(int argc, char **argv) {
    assert(argc == 2);
    std::string test = argv[1];
    Preview preview;
    if (test == "late_seek") {
        assert(preview.begin(10, 20, 60, false));
        assert(preview.leadIn() == 7);
        // Old positions from before the seek must never trigger a cut or finish.
        assert(preview.advance(55) == Action::None);
        assert(preview.advance(10) == Action::None);
        preview.seekCompleted(true);
        assert(preview.advance(7) == Action::None);
        assert(preview.advance(9.99) == Action::None);
        assert(preview.advance(10) == Action::SeekToEnd);
        assert(preview.advance(55) == Action::None);
        preview.seekCompleted(true);
        assert(preview.advance(20) == Action::None);
        assert(preview.advance(22.49) == Action::None);
        assert(preview.advance(22.5) == Action::Finish);
        assert(!preview.active());
    } else if (test == "one_cut") {
        assert(preview.begin(10, 20, 60, false));
        preview.seekCompleted(true);
        assert(preview.advance(10) == Action::SeekToEnd);
        for (int i = 0; i < 100; ++i) assert(preview.advance(10.1) == Action::None);
        preview.seekCompleted(true);
        assert(preview.advance(20) == Action::None);
    } else if (test == "zero_start") {
        assert(preview.begin(0, 20, 60, false));
        assert(preview.leadIn() == 0);
        preview.seekCompleted(true);
        assert(preview.advance(0) == Action::SeekToEnd);
    } else if (test == "near_start") {
        assert(preview.begin(1.25, 2, 60, false));
        assert(preview.leadIn() == 0);
        preview.seekCompleted(true);
        assert(preview.advance(1.24) == Action::None);
        assert(preview.advance(1.25) == Action::SeekToEnd);
    } else if (test == "video_end") {
        assert(preview.begin(10, 60, 60, false));
        assert(preview.targetEnd() == 60);
        preview.seekCompleted(true);
        assert(preview.advance(10) == Action::SeekToEnd);
        // Seeking to EOF must finish without waiting for another time update.
        assert(preview.seekCompleted(true) == Action::Finish);
    } else if (test == "clamp") {
        assert(preview.begin(10, 100, 60, false));
        assert(preview.end() == 60);
        assert(preview.targetEnd() == 60);
        assert(!preview.begin(60, 100, 60, false));
    } else if (test == "cancel_seek") {
        assert(preview.begin(10, 20, 60, false));
        preview.seekCompleted(false);
        assert(!preview.active());
        assert(preview.advance(10) == Action::None);
    } else if (test == "replace_cut") {
        assert(preview.begin(10, 20, 60, false));
        preview.seekCompleted(true);
        assert(preview.advance(10) == Action::SeekToEnd);
        preview.cancel();
        assert(preview.begin(30, 40, 60, false));
        assert(preview.advance(20) == Action::None);
        preview.seekCompleted(true);
        assert(preview.advance(27) == Action::None);
        assert(preview.advance(30) == Action::SeekToEnd);
        assert(preview.end() == 40);
    } else if (test == "mute") {
        assert(preview.begin(10, 50, 60, true));
        preview.seekCompleted(true);
        assert(preview.advance(10) == Action::Mute);
        // A long mute is governed by media time, not a fixed 20-second timer.
        assert(preview.advance(40) == Action::None);
        assert(preview.advance(50) == Action::Unmute);
        assert(preview.advance(52.5) == Action::Finish);
    } else if (test == "mute_end") {
        assert(preview.begin(0, 60, 60, true));
        preview.seekCompleted(true);
        assert(preview.advance(0) == Action::Mute);
        assert(preview.advance(60) == Action::Unmute);
        assert(preview.advance(60) == Action::Finish);
    } else if (test == "unknown_duration") {
        assert(preview.begin(10, 20, 0, false));
        assert(preview.targetEnd() == 22.5);
    } else if (test == "invalid") {
        double nan = std::numeric_limits<double>::quiet_NaN();
        double inf = std::numeric_limits<double>::infinity();
        assert(!preview.begin(10, 10, 60, false));
        assert(!preview.begin(20, 10, 60, false));
        assert(!preview.begin(-1, 10, 60, false));
        assert(!preview.begin(nan, 10, 60, false));
        assert(!preview.begin(0, inf, 60, false));
        assert(!preview.begin(0, 10, nan, false));
        assert(preview.begin(0, 10, 60, false));
        preview.seekCompleted(true);
        assert(preview.advance(nan) == Action::None);
        assert(preview.advance(inf) == Action::None);
        assert(preview.advance(-1) == Action::None);
    } else {
        return 2;
    }
}
