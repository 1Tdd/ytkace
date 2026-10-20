#pragma once

#include <functional>
#include <map>
#include <string>
#include <vector>

namespace YTKACEMediaConversion {
struct Options {
    // Empty: audio only. hardware: VideoToolbox with veryfast fallback.
    // ultrafast/veryfast/medium: software H.264 at CRF 20.
    std::string videoPreset;
    std::string audioFormat = "aac";
    int audioBitrate = 160000;
    std::map<std::string, std::string> metadata;
};

struct Statistics {
    std::string videoEncoder;
    bool hardwareAttempted = false;
    int hardwareInitError = 0;
    unsigned long long directHardwareFrames = 0;
    unsigned long long convertedFrames = 0;
};

// Returns a libav error code. Failed/cancelled output is removed.
int convert(const std::string &input, const std::string &output,
            const Options &options, const std::function<bool()> &cancelled,
            const std::function<void(double)> &progress, std::string &message,
            Statistics *statistics = nullptr);
int embedMP3Artwork(const std::string &input, const std::string &output,
                    const std::vector<unsigned char> &jpeg, std::string &message);
}
