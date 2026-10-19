#include "MediaPolicy.h"
#include <cassert>
#include <limits>
#include <string>
using namespace YTKACEMedia;

int main(int argc, char **argv) {
    assert(argc == 2);
    std::string test = argv[1];
    if (test == "timestamps") {
        assert(parseTimestamp(" 1:02.50 ") == 62.5);
        assert(parseTimestamp("1:02:03,5") == 3723.5);
        assert(parseTimestamp("75:00") == 4500);
        assert(parseTimestamp("0") == 0);
        assert(parseTimestamp("12.25") == 12.25);
    } else if (test == "malformed_timestamps") {
        for (auto text : {"abc:12", "1:garbage", "1::2", "1:2junk", "1:60", "1:60:00", "1.5:00", "1:", ":10", "-1", "NaN", "inf", "1:2:3:4", ".", ""}) assert(parseTimestamp(text) < 0);
        assert(parseTimestamp(std::string(400, '9')) < 0);
    } else if (test == "overlapping_cuts") {
        auto cuts = normalize({{20, 30}, {10, 25}, {15, 19}});
        assert(cuts.size() == 1);
        assert(mapTime(50, cuts) == 30);
    } else if (test == "touching_cuts") {
        auto cuts = normalize({{10, 20}, {20, 30}});
        assert(cuts.size() == 1);
        assert(mapTime(20, cuts) == 10);
        assert(mapTime(30, cuts) == 10);
    } else if (test == "partial_cut") {
        auto cuts = normalize({{10, 20}});
        assert(mapTime(15, cuts) == 10);
        assert(mapTime(25, cuts) == 15);
        assert(mapTime(5, cuts) == 5);
    } else if (test == "fully_cut") {
        auto cuts = normalize({{10, 20}});
        assert(mapTime(12, cuts) == mapTime(18, cuts));
    } else if (test == "spanning_caption") {
        auto cuts = normalize({{10, 20}, {25, 30}});
        assert(mapTime(5, cuts) == 5);
        assert(mapTime(35, cuts) == 20);
    } else if (test == "invalid_cuts") {
        double nan = std::numeric_limits<double>::quiet_NaN();
        double inf = std::numeric_limits<double>::infinity();
        auto cuts = normalize({{-1, 2}, {5, 2}, {2, 2}, {nan, 8}, {0, inf}, {10, 20}});
        assert(cuts.size() == 1);
    } else if (test == "paused_zero") {
        PlaybackActivity state;
        for (int i = 0; i < 100; ++i) state.observe(0, i * 0.1);
        assert(state.paused(10));
    } else if (test == "paused_duplicate") {
        PlaybackActivity state;
        state.play(1);
        state.observe(10, 1);
        state.pause(2);
        for (int i = 0; i < 100; ++i) state.observe(10, 2 + i * 0.1);
        assert(state.paused(12));
    } else if (test == "paused_seek") {
        PlaybackActivity state;
        state.pause(1);
        state.observe(10, 1.1);
        state.observe(100, 1.2);
        state.observe(101, 1.3);
        assert(state.paused(1.3));
    } else if (test == "external_resume") {
        PlaybackActivity state;
        state.pause(1);
        state.observe(10, 2);
        state.observe(10.25, 2.25);
        state.observe(10.5, 2.5);
        assert(!state.paused(2.5));
        assert(state.paused(7));
    } else if (test == "video_reset") {
        PlaybackActivity state;
        state.play(10);
        state.observe(80, 10);
        state.pause(11);
        state.observe(0, 11.1);
        state.observe(0, 11.2);
        assert(state.paused(11.2));
    } else if (test == "invalid_activity") {
        PlaybackActivity state;
        state.observe(std::numeric_limits<double>::quiet_NaN(), 1);
        state.observe(0, std::numeric_limits<double>::infinity());
        state.observe(-1, 2);
        assert(state.paused(2));
    } else return 2;
}
