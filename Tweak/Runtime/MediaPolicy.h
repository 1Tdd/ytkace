#pragma once
#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

namespace YTKACEMedia {
struct Interval { double start, end; };

inline bool valid(Interval range) {
    return std::isfinite(range.start) && std::isfinite(range.end) &&
        range.start >= 0.0 && range.end > range.start;
}

inline std::vector<Interval> normalize(std::vector<Interval> ranges) {
    ranges.erase(std::remove_if(ranges.begin(), ranges.end(), [](Interval r) { return !valid(r); }), ranges.end());
    std::sort(ranges.begin(), ranges.end(), [](Interval a, Interval b) { return a.start < b.start; });
    std::vector<Interval> result;
    for (auto range : ranges) {
        if (!result.empty() && range.start <= result.back().end) {
            result.back().end = std::max(result.back().end, range.end);
        } else {
            result.push_back(range);
        }
    }
    return result;
}

// Maps source times to the edited timeline. Cuts must be sorted and merged.
inline double mapTime(double time, const std::vector<Interval> &cuts) {
    if (!std::isfinite(time) || time < 0.0) return 0.0;
    double dropped = 0.0;
    for (auto cut : cuts) {
        if (time <= cut.start) break;
        dropped += std::min(time, cut.end) - cut.start;
    }
    return std::max(0.0, time - dropped);
}

inline double parseTimestamp(std::string text) {
    std::vector<double> values;
    size_t first = text.find_first_not_of(" \t\r\n"), last = text.find_last_not_of(" \t\r\n");
    if (first == std::string::npos) return -1.0;
    text = text.substr(first, last - first + 1);
    size_t pos = 0;
    while (pos < text.size()) {
        double value = 0.0, fraction = 0.1;
        bool decimal = false, digit = false;
        while (pos < text.size() && text[pos] != ':') {
            char c = text[pos++];
            if ((c == '.' || c == ',') && !decimal) {
                decimal = true;
                continue;
            }
            if (c < '0' || c > '9') return -1.0;
            digit = true;
            if (decimal) {
                value += (c - '0') * fraction;
                fraction *= 0.1;
            } else {
                value = value * 10.0 + c - '0';
            }
        }
        if (!digit || !std::isfinite(value)) return -1.0;
        if (pos < text.size() && (decimal || ++pos == text.size())) return -1.0;
        values.push_back(value);
        if (values.size() > 3) return -1.0;
    }
    if (values.empty()) return -1.0;
    if (values.size() > 1 && values.back() >= 60.0) return -1.0;
    if (values.size() == 3 && values[1] >= 60.0) return -1.0;
    double result = 0.0;
    for (double value : values) result = result * 60.0 + value;
    return std::isfinite(result) ? result : -1.0;
}

class PlaybackActivity {
public:
    void play(double now) {
        playing_ = true;
        lastPlaying_ = now;
        pausedAt_ = -1.0;
    }
    void pause(double now) {
        playing_ = false;
        pausedAt_ = now;
        streak_ = 0;
        lastMedia_ = -1.0;
    }
    void observe(double media, double now) {
        if (!std::isfinite(media) || !std::isfinite(now) || media < 0.0 || now < 0.0) return;
        if (media == lastMedia_) return;
        double delta = media - lastMedia_, elapsed = now - lastSample_;
        bool advancing = lastMedia_ >= 0.0 && elapsed > 0.0 && elapsed <= 3.0 &&
            delta > 0.001 && delta <= std::max(0.25, elapsed * 4.0);
        streak_ = advancing ? streak_ + 1 : 0;
        if (advancing && (playing_ || (streak_ >= 2 && (pausedAt_ < 0.0 || now - pausedAt_ > 0.3)))) {
            playing_ = true;
            lastPlaying_ = now;
        }
        lastMedia_ = media;
        lastSample_ = now;
    }
    bool paused(double now) const { return !playing_ || !std::isfinite(now) || now - lastPlaying_ > 3.5; }
private:
    bool playing_ = false;
    unsigned streak_ = 0;
    double lastMedia_ = -1.0, lastSample_ = 0.0, lastPlaying_ = 0.0, pausedAt_ = -1.0;
};
}
