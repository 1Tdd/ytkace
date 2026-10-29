#include "MediaChapters.h"
#include <cerrno>
#include <cstdio>
#include <limits>
#include <stdexcept>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
}

namespace YTKACEMediaChapters {
namespace {
struct Failure { int code; const char *stage; };
void check(int code, const char *stage) { if (code < 0) throw Failure{code, stage}; }
struct Session {
    AVFormatContext *input = nullptr, *output = nullptr;
    AVPacket *packet = av_packet_alloc();
    ~Session() {
        av_packet_free(&packet);
        avformat_close_input(&input);
        if (output) {
            if (output->pb) avio_closep(&output->pb);
            avformat_free_context(output);
        }
    }
};
}

int write(const std::string &inputPath, const std::string &outputPath,
          const std::vector<Chapter> &chapters,
          const std::vector<YTKACEMedia::Interval> &removed,
          const std::function<bool()> &cancelled, std::string &message) {
    if (inputPath == outputPath) return AVERROR(EINVAL);
    int result = 0;
    try {
        Session s;
        if (!s.packet) throw Failure{AVERROR(ENOMEM), "Allocate chapter packet"};
        const auto stop = [&]() { if (cancelled && cancelled()) throw Failure{AVERROR_EXIT, "Cancelled"}; };
        stop();
        check(avformat_open_input(&s.input, inputPath.c_str(), nullptr, nullptr), "Open chapter input");
        check(avformat_find_stream_info(s.input, nullptr), "Read chapter input");
        check(avformat_alloc_output_context2(&s.output, nullptr, nullptr, outputPath.c_str()), "Create chapter output");
        check(av_dict_copy(&s.output->metadata, s.input->metadata, 0), "Copy chapter file tags");
        std::vector<int> streams(s.input->nb_streams, -1);
        for (unsigned i = 0; i < s.input->nb_streams; ++i) {
            AVStream *source = s.input->streams[i];
            const auto type = source->codecpar->codec_type;
            // MOV chapter data tracks are regenerated from the new chapter table.
            if (type != AVMEDIA_TYPE_AUDIO && type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_SUBTITLE) continue;
            AVStream *track = avformat_new_stream(s.output, nullptr);
            if (!track) throw Failure{AVERROR(ENOMEM), "Allocate chapter stream"};
            check(avcodec_parameters_copy(track->codecpar, source->codecpar), "Copy chapter stream");
            track->codecpar->codec_tag = 0;
            track->time_base = source->time_base;
            track->avg_frame_rate = source->avg_frame_rate;
            track->disposition = source->disposition;
            check(av_dict_copy(&track->metadata, source->metadata, 0), "Copy chapter stream tags");
            streams[i] = track->index;
        }
        if (s.output->nb_streams == 0) throw Failure{AVERROR_STREAM_NOT_FOUND, "Find chapter media"};
        double duration = s.input->duration > 0 && s.input->duration != AV_NOPTS_VALUE
            ? s.input->duration / static_cast<double>(AV_TIME_BASE) : 0.0;
        const auto finalChapters = adjusted(chapters, removed, duration);
        s.output->chapters = static_cast<AVChapter **>(av_calloc(finalChapters.size(), sizeof(AVChapter *)));
        if (!finalChapters.empty() && !s.output->chapters) throw Failure{AVERROR(ENOMEM), "Allocate chapters"};
        for (const auto &chapter : finalChapters) {
            // Millisecond boundaries are shared by MOV chapters and ID3 CHAP.
            if (chapter.end >= static_cast<double>(std::numeric_limits<int64_t>::max()) / 1000.0) continue;
            int64_t start = std::llround(chapter.start * 1000.0), end = std::llround(chapter.end * 1000.0);
            if (end <= start) continue;
            AVChapter *entry = static_cast<AVChapter *>(av_mallocz(sizeof(AVChapter)));
            if (!entry) throw Failure{AVERROR(ENOMEM), "Allocate chapter"};
            s.output->chapters[s.output->nb_chapters++] = entry;
            entry->id = s.output->nb_chapters - 1;
            entry->time_base = AVRational{1, 1000};
            entry->start = start;
            entry->end = end;
            check(av_dict_set(&entry->metadata, "title", chapter.title.c_str(), 0), "Write chapter title");
        }
        if (!(s.output->oformat->flags & AVFMT_NOFILE))
            check(avio_open(&s.output->pb, outputPath.c_str(), AVIO_FLAG_WRITE), "Open chapter output");
        AVDictionary *options = nullptr;
        if (std::string(s.output->oformat->name).find("mp3") != std::string::npos)
            av_dict_set(&options, "id3v2_version", "3", 0);
        else av_dict_set(&options, "movflags", "+faststart", 0);
        result = avformat_write_header(s.output, &options);
        av_dict_free(&options);
        check(result, "Write chapter header");
        while ((result = av_read_frame(s.input, s.packet)) >= 0) {
            stop();
            int index = s.packet->stream_index;
            if (streams[index] >= 0) {
                AVStream *track = s.output->streams[streams[index]];
                av_packet_rescale_ts(s.packet, s.input->streams[index]->time_base, track->time_base);
                s.packet->stream_index = track->index;
                s.packet->pos = -1;
                check(av_interleaved_write_frame(s.output, s.packet), "Write chapter media");
            }
            av_packet_unref(s.packet);
        }
        if (result != AVERROR_EOF) check(result, "Read chapter packet");
        stop();
        check(av_write_trailer(s.output), "Finish chapters");
        result = 0;
    } catch (const Failure &failure) {
        char error[AV_ERROR_MAX_STRING_SIZE] = {};
        av_strerror(failure.code, error, sizeof(error));
        result = failure.code;
        message = std::string(failure.stage) + ": " + error;
    } catch (const std::exception &error) { result = AVERROR(ENOMEM); message = error.what(); }
    if (result < 0) std::remove(outputPath.c_str());
    return result;
}
}
