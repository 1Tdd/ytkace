#include "MediaConversion.h"
#include <iostream>
#include <fstream>
#include <iterator>

int main(int argc, char **argv) {
    if (argc != 5) return 2;
    if (std::string(argv[3]) == "artwork") {
        std::ifstream file(argv[4], std::ios::binary);
        std::vector<unsigned char> jpeg((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        std::string message;
        int result = YTKACEMediaConversion::embedMP3Artwork(argv[1], argv[2], jpeg, message);
        if (result < 0) { std::cerr << message << '\n'; return 1; }
        return 0;
    }
    YTKACEMediaConversion::Options options;
    options.videoPreset = std::string(argv[3]) == "audio" ? "" : argv[3];
    options.audioFormat = argv[4];
    options.audioBitrate = 128000;
    options.metadata = {{"title", "Conversion test"}, {"artist", "YTKACE"}};
    bool stop = false;
    if (options.audioFormat == "cancel") options.audioFormat = "aac";
    std::string message;
    YTKACEMediaConversion::Statistics statistics;
    const int result = YTKACEMediaConversion::convert(argv[1], argv[2], options,
        [&]() { return stop; }, [&](double fraction) {
            std::cout << fraction << '\n';
            if (std::string(argv[4]) == "cancel" && fraction > 0.05) stop = true;
        }, message, &statistics);
    std::cerr << "encoder=" << statistics.videoEncoder << " hardware_attempted=" << statistics.hardwareAttempted
              << " direct=" << statistics.directHardwareFrames << " converted=" << statistics.convertedFrames << '\n';
    if (result < 0) { std::cerr << message << '\n'; return 1; }
    return 0;
}
