#pragma once
#include "../../Runtime/MediaPolicy.h"
#include <functional>
#include <string>
#include <vector>

namespace YTKACEMediaChapters {
struct Chapter { std::string title; double start, end; };

// The input file has already been cut. Use the actual applied cuts, not the
// requested SponsorBlock ranges, to map its original chapter boundaries.
inline std::vector<Chapter> adjusted(std::vector<Chapter> chapters,
                                    const std::vector<YTKACEMedia::Interval> &removed,
                                    double duration) {
    const auto cuts = YTKACEMedia::normalize(removed);
    std::vector<Chapter> result;
    for (auto chapter : chapters) {
        if (chapter.title.empty() || !YTKACEMedia::valid({chapter.start, chapter.end})) continue;
        chapter.start = YTKACEMedia::mapTime(chapter.start, cuts);
        chapter.end = YTKACEMedia::mapTime(chapter.end, cuts);
        if (std::isfinite(duration) && duration > 0.0) chapter.end = std::min(chapter.end, duration);
        if (chapter.end > chapter.start) result.push_back(chapter);
    }
    std::stable_sort(result.begin(), result.end(), [](const Chapter &a, const Chapter &b) { return a.start < b.start; });
    std::vector<Chapter> unique;
    for (const auto &chapter : result) {
        if (!unique.empty() && chapter.start == unique.back().start) continue;
        if (!unique.empty()) unique.back().end = std::min(unique.back().end, chapter.start);
        unique.push_back(chapter);
    }
    return unique;
}

// Remux MP4/M4A or MP3 with embedded chapters, preserving audio/video,
// subtitles, artwork and tags without re-encoding. Removes failed output.
int write(const std::string &input, const std::string &output,
          const std::vector<Chapter> &chapters,
          const std::vector<YTKACEMedia::Interval> &removed,
          const std::function<bool()> &cancelled, std::string &message);
}
