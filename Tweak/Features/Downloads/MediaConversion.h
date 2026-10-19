#pragma once

#include <functional>
#include <map>
#include <string>
#include <vector>

namespace YTKACEMediaConversion {
struct Options {
    // An empty preset produces audio only. Video presets use H.264 CRF 20.
    std::string videoPreset;
    std::string audioFormat = "aac";
    int audioBitrate = 160000;
    std::map<std::string, std::string> metadata;
};

// Returns a libav error code. Failed/cancelled output is removed.
int convert(const std::string &input, const std::string &output,
            const Options &options, const std::function<bool()> &cancelled,
            const std::function<void(double)> &progress, std::string &message);
int embedMP3Artwork(const std::string &input, const std::string &output,
                    const std::vector<unsigned char> &jpeg, std::string &message);
}
