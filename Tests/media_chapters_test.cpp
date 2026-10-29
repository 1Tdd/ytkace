#include "MediaChapters.h"
#include <cassert>
#include <iostream>
#include <limits>

int main(int argc, char **argv) {
    using namespace YTKACEMediaChapters;
    if (argc == 2 && std::string(argv[1]) == "timeline") {
        const double nan = std::numeric_limits<double>::quiet_NaN();
        auto chapters = adjusted({{"Finale", 20, 30}, {"Intro", 0, 10}, {"Ad", 10, 20},
            {"Invalid", nan, 10}, {"Negative", -1, 3}, {"Empty", 3, 3}, {"", 1, 2}},
            {{10, 16}, {15, 20}, {-1, 0}, {nan, 5}}, 18);
        assert(chapters.size() == 2);
        assert(chapters[0].title == "Intro" && chapters[0].start == 0 && chapters[0].end == 10);
        assert(chapters[1].title == "Finale" && chapters[1].start == 10 && chapters[1].end == 18);
        chapters = adjusted({{"Intro", 0, 10}, {"Main", 10, 20}}, {{0, 3}, {7, 12}}, 12);
        assert(chapters.size() == 2);
        assert(chapters[0].start == 0 && chapters[0].end == 4);
        assert(chapters[1].start == 4 && chapters[1].end == 12);
        chapters = adjusted({{"One", 0, 8}, {"Duplicate", 0, 8}, {"Two", 5, 10}}, {}, 7);
        assert(chapters.size() == 2 && chapters[0].end == 5 && chapters[1].end == 7);
        assert(adjusted({{"Gone", 0, 3}}, {{0, 3}}, 3).empty());
        return 0;
    }
    if (argc != 4) return 2;
    std::vector<Chapter> chapters = {{"Introduzione", 0, .6}, {"Caffè & musica 日本語", .6, 1.2}, {"Finale", 1.2, 100}};
    std::vector<YTKACEMedia::Interval> cuts;
    if (std::string(argv[3]) == "cuts") {
        chapters = {{"Introduzione", 0, .6}, {"Ad", .6, 1.0}, {"Finale", 1.0, 2.1}};
        cuts = {{.6, .8}, {.75, 1.0}};
    }
    std::string message;
    int result = write(argv[1], argv[2], chapters, cuts,
        [&]() { return std::string(argv[3]) == "cancel"; }, message);
    if (result < 0) { std::cerr << message << '\n'; return 1; }
    return 0;
}
