#include "MediaConversion.h"
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/error.h>
#include <libavutil/hwcontext.h>
#ifdef __APPLE__
#include <libavutil/hwcontext_videotoolbox.h>
#endif
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

namespace YTKACEMediaConversion {
namespace {
struct Failure { int code; std::string stage; };
void check(int code, const char *stage) { if (code < 0) throw Failure{code, stage}; }

struct Session {
    AVFormatContext *input = nullptr, *output = nullptr;
    AVPacket *packet = av_packet_alloc(), *encoded = av_packet_alloc();
    AVFrame *decoded = av_frame_alloc(), *software = av_frame_alloc(), *video = av_frame_alloc();
    AVFrame *upload = av_frame_alloc();
    AVCodecContext *videoDecoder = nullptr, *videoEncoder = nullptr;
    AVCodecContext *audioDecoder = nullptr, *audioEncoder = nullptr;
    SwsContext *scaler = nullptr;
    SwrContext *resampler = nullptr;
    AVAudioFifo *fifo = nullptr;
    AVBufferRef *hardware = nullptr;
    AVBufferRef *encoderFrames = nullptr;
    bool hardwareEncoder = false;
    Statistics *statistics = nullptr;
    int videoIndex = -1, audioIndex = -1;
    AVStream *videoOut = nullptr, *audioOut = nullptr;
    int64_t audioPTS = 0, nextVideoPTS = 0;
    std::function<bool()> cancelled;
    ~Session() {
        av_packet_free(&packet); av_packet_free(&encoded);
        av_frame_free(&decoded); av_frame_free(&software); av_frame_free(&video);
        av_frame_free(&upload);
        avcodec_free_context(&videoDecoder); avcodec_free_context(&videoEncoder);
        avcodec_free_context(&audioDecoder); avcodec_free_context(&audioEncoder);
        sws_freeContext(scaler); swr_free(&resampler);
        if (fifo) av_audio_fifo_free(fifo);
        av_buffer_unref(&encoderFrames); av_buffer_unref(&hardware);
        avformat_close_input(&input);
        if (output) {
            if (output->pb) avio_closep(&output->pb);
            avformat_free_context(output);
        }
    }
    void stopIfCancelled() { if (cancelled && cancelled()) throw Failure{AVERROR_EXIT, "Cancelled"}; }
    static int interrupt(void *opaque) {
        auto *session = static_cast<Session *>(opaque);
        return session->cancelled && session->cancelled();
    }
    static AVPixelFormat pixelFormat(AVCodecContext *, const AVPixelFormat *formats) {
        for (const AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; ++p)
            if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
        for (const AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; ++p) {
            const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(*p);
            if (desc && !(desc->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
        }
        return AV_PIX_FMT_NONE;
    }
    AVCodecContext *decoder(int index) {
        const AVCodec *codec = avcodec_find_decoder(input->streams[index]->codecpar->codec_id);
        if (!codec) throw Failure{AVERROR_DECODER_NOT_FOUND, "Find decoder"};
        AVCodecContext *context = avcodec_alloc_context3(codec);
        if (!context) throw Failure{AVERROR(ENOMEM), "Allocate decoder"};
        try {
            check(avcodec_parameters_to_context(context, input->streams[index]->codecpar), "Read codec parameters");
            context->pkt_timebase = input->streams[index]->time_base;
            context->thread_count = 2;
#ifdef __APPLE__
            if (context->codec_type == AVMEDIA_TYPE_VIDEO) {
                for (int i = 0; ; i++) {
                    const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
                    if (!config) break;
                    if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
                        (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
                        if (av_hwdevice_ctx_create(&hardware, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0) >= 0) {
                            context->hw_device_ctx = av_buffer_ref(hardware);
                            context->get_format = pixelFormat;
                        }
                        break;
                    }
                }
            }
#endif
            check(avcodec_open2(context, codec, nullptr), "Open decoder");
        } catch (...) { avcodec_free_context(&context); throw; }
        return context;
    }
    void openVideoEncoder(bool accelerated, const std::string &preset) {
        const char *name = accelerated ? "h264_videotoolbox" : "libx264";
        const AVCodec *codec = avcodec_find_encoder_by_name(name);
        if (!codec) throw Failure{AVERROR_ENCODER_NOT_FOUND, "Find H.264 encoder"};
        videoEncoder = avcodec_alloc_context3(codec);
        if (!videoEncoder) throw Failure{AVERROR(ENOMEM), "Allocate H.264 encoder"};
        auto *e = videoEncoder;
        e->width = (videoDecoder->width + 1) & ~1;
        e->height = (videoDecoder->height + 1) & ~1;
        e->framerate = av_guess_frame_rate(input, input->streams[videoIndex], nullptr);
        if (e->framerate.num <= 0 || e->framerate.den <= 0) e->framerate = {30, 1};
        e->time_base = {1, 90000}; e->sample_aspect_ratio = videoDecoder->sample_aspect_ratio;
        e->color_primaries = videoDecoder->color_primaries; e->color_trc = videoDecoder->color_trc;
        e->colorspace = videoDecoder->colorspace; e->color_range = videoDecoder->color_range;
        if (e->color_trc == AVCOL_TRC_SMPTE2084 || e->color_trc == AVCOL_TRC_ARIB_STD_B67)
            throw Failure{AVERROR(ENOTSUP), "HDR conversion requires tone mapping; choose Skip conversion"};
        if (output->oformat->flags & AVFMT_GLOBALHEADER) e->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if (accelerated) {
            if (!hardware) check(av_hwdevice_ctx_create(&hardware, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                nullptr, nullptr, 0), "Create hardware encoding device");
            encoderFrames = av_hwframe_ctx_alloc(hardware);
            if (!encoderFrames) throw Failure{AVERROR(ENOMEM), "Allocate hardware frame pool"};
            auto *frames = reinterpret_cast<AVHWFramesContext *>(encoderFrames->data);
            frames->format = AV_PIX_FMT_VIDEOTOOLBOX; frames->sw_format = AV_PIX_FMT_NV12;
            frames->width = e->width; frames->height = e->height;
#ifdef __APPLE__
            reinterpret_cast<AVVTFramesContext *>(frames->hwctx)->color_range = e->color_range;
#endif
            check(av_hwframe_ctx_init(encoderFrames), "Create hardware frame pool");
            e->hw_frames_ctx = av_buffer_ref(encoderFrames);
            if (!e->hw_frames_ctx) throw Failure{AVERROR(ENOMEM), "Retain hardware frame pool"};
            e->pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX; e->sw_pix_fmt = AV_PIX_FMT_NV12;
            // Apple hardware rate control uses bitrate, not x264's CRF scale.
            double rate = double(e->width) * e->height * av_q2d(e->framerate) * 0.12;
            e->bit_rate = static_cast<int64_t>(std::clamp(rate, 256000.0, 80000000.0));
            e->gop_size = std::max(1, static_cast<int>(std::lround(av_q2d(e->framerate) * 2)));
            e->max_b_frames = 0;
            check(av_opt_set_int(e->priv_data, "allow_sw", 0, 0), "Require hardware encoder");
            check(av_opt_set_int(e->priv_data, "realtime", 0, 0), "Set offline encoding");
            check(av_opt_set_int(e->priv_data, "prio_speed", 1, 0), "Prioritize encoding speed");
        } else {
            e->pix_fmt = AV_PIX_FMT_YUV420P; e->thread_count = 2;
            check(av_opt_set(e->priv_data, "preset", preset.c_str(), 0), "Set encoding preset");
            check(av_opt_set(e->priv_data, "crf", "20", 0), "Set encoding quality");
        }
        check(avcodec_open2(e, codec, nullptr), "Open H.264 encoder");
        hardwareEncoder = accelerated;
        if (statistics) statistics->videoEncoder = name;
    }
    void drainEncoder(AVCodecContext *encoder, AVStream *stream) {
        for (;;) {
            stopIfCancelled();
            int result = avcodec_receive_packet(encoder, encoded);
            if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return;
            check(result, "Receive encoded packet");
            av_packet_rescale_ts(encoded, encoder->time_base, stream->time_base);
            encoded->stream_index = stream->index;
            check(av_interleaved_write_frame(output, encoded), "Write encoded packet");
            av_packet_unref(encoded);
        }
    }
    void encode(AVCodecContext *encoder, AVStream *stream, AVFrame *frame) {
        stopIfCancelled();
        int result = avcodec_send_frame(encoder, frame);
        if (result == AVERROR(EAGAIN)) {
            drainEncoder(encoder, stream);
            result = avcodec_send_frame(encoder, frame);
        }
        check(result, "Encode frame");
        drainEncoder(encoder, stream);
    }
    void videoFrame() {
        AVStream *stream = input->streams[videoIndex];
        int64_t pts = decoded->best_effort_timestamp;
        int64_t origin = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
        int64_t outputPTS = pts == AV_NOPTS_VALUE ? nextVideoPTS : av_rescale_q(pts - origin, stream->time_base, videoEncoder->time_base);
        nextVideoPTS = outputPTS + std::max<int64_t>(1, av_rescale_q(1, av_inv_q(videoEncoder->framerate), videoEncoder->time_base));
        if (hardwareEncoder && decoded->format == AV_PIX_FMT_VIDEOTOOLBOX && decoded->hw_frames_ctx &&
            decoded->width == videoEncoder->width && decoded->height == videoEncoder->height) {
            auto *frames = reinterpret_cast<AVHWFramesContext *>(decoded->hw_frames_ctx->data);
            if (frames->sw_format == AV_PIX_FMT_NV12) {
                // VideoToolbox consumes the decoder's CVPixelBuffer directly.
                decoded->pts = outputPTS;
                encode(videoEncoder, videoOut, decoded);
                if (statistics) statistics->directHardwareFrames++;
                return;
            }
        }
        AVFrame *source = decoded;
        if (decoded->format == AV_PIX_FMT_VIDEOTOOLBOX) {
            av_frame_unref(software);
            check(av_hwframe_transfer_data(software, decoded, 0), "Read hardware frame");
            source = software;
        }
        check(av_frame_make_writable(video), "Prepare video frame");
        scaler = sws_getCachedContext(scaler, source->width, source->height,
            static_cast<AVPixelFormat>(source->format), videoEncoder->width, videoEncoder->height,
            static_cast<AVPixelFormat>(video->format), SWS_BICUBIC, nullptr, nullptr, nullptr);
        if (!scaler) throw Failure{AVERROR(ENOMEM), "Create video scaler"};
        check(sws_scale(scaler, source->data, source->linesize, 0, source->height,
                        video->data, video->linesize), "Convert video pixels");
        video->pts = outputPTS;
        if (hardwareEncoder) {
            av_frame_unref(upload);
            check(av_hwframe_get_buffer(encoderFrames, upload, 0), "Get hardware encoding buffer");
            check(av_hwframe_transfer_data(upload, video, 0), "Upload video frame");
            check(av_frame_copy_props(upload, video), "Copy video frame properties");
            encode(videoEncoder, videoOut, upload);
        } else encode(videoEncoder, videoOut, video);
        if (statistics) statistics->convertedFrames++;
    }
    void writeAudio(bool final) {
        const int frameSize = audioEncoder->frame_size > 0 ? audioEncoder->frame_size : 1024;
        while (av_audio_fifo_size(fifo) >= frameSize || (final && av_audio_fifo_size(fifo) > 0)) {
            stopIfCancelled();
            int available = std::min(frameSize, av_audio_fifo_size(fifo));
            AVFrame *frame = av_frame_alloc();
            if (!frame) throw Failure{AVERROR(ENOMEM), "Allocate audio frame"};
            try {
                frame->nb_samples = (audioEncoder->codec->capabilities & AV_CODEC_CAP_SMALL_LAST_FRAME) ? available : frameSize;
                frame->format = audioEncoder->sample_fmt;
                frame->sample_rate = audioEncoder->sample_rate;
                check(av_channel_layout_copy(&frame->ch_layout, &audioEncoder->ch_layout), "Copy audio layout");
                check(av_frame_get_buffer(frame, 0), "Allocate audio samples");
                check(av_samples_set_silence(frame->extended_data, 0, frame->nb_samples,
                    frame->ch_layout.nb_channels, audioEncoder->sample_fmt), "Clear audio samples");
                if (av_audio_fifo_read(fifo, reinterpret_cast<void **>(frame->extended_data), available) != available)
                    throw Failure{AVERROR(EIO), "Read audio samples"};
                frame->pts = audioPTS; audioPTS += frame->nb_samples;
                encode(audioEncoder, audioOut, frame);
            } catch (...) { av_frame_free(&frame); throw; }
            av_frame_free(&frame);
        }
    }
    void audioFrame(AVFrame *source) {
        int capacity = static_cast<int>(av_rescale_rnd(swr_get_delay(resampler, audioDecoder->sample_rate) +
            (source ? source->nb_samples : 0), audioEncoder->sample_rate, audioDecoder->sample_rate, AV_ROUND_UP));
        if (capacity <= 0) return;
        AVFrame *samples = av_frame_alloc();
        if (!samples) throw Failure{AVERROR(ENOMEM), "Allocate resampled frame"};
        try {
            samples->nb_samples = capacity; samples->format = audioEncoder->sample_fmt;
            check(av_channel_layout_copy(&samples->ch_layout, &audioEncoder->ch_layout), "Copy resampler layout");
            check(av_frame_get_buffer(samples, 0), "Allocate resampled samples");
            int count = swr_convert(resampler, samples->extended_data, capacity,
                source ? const_cast<const uint8_t **>(source->extended_data) : nullptr,
                source ? source->nb_samples : 0);
            check(count, "Resample audio");
            check(av_audio_fifo_realloc(fifo, av_audio_fifo_size(fifo) + count), "Grow audio queue");
            if (av_audio_fifo_write(fifo, reinterpret_cast<void **>(samples->extended_data), count) != count)
                throw Failure{AVERROR(EIO), "Queue audio samples"};
            writeAudio(false);
        } catch (...) { av_frame_free(&samples); throw; }
        av_frame_free(&samples);
    }
    void drainDecoder(AVCodecContext *context, bool isVideo) {
        for (;;) {
            stopIfCancelled();
            int result = avcodec_receive_frame(context, decoded);
            if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return;
            check(result, "Decode frame");
            if (isVideo) videoFrame(); else audioFrame(decoded);
            av_frame_unref(decoded);
        }
    }
    void decode(AVCodecContext *context, AVPacket *source, bool isVideo) {
        int result = avcodec_send_packet(context, source);
        if (result == AVERROR(EAGAIN)) {
            drainDecoder(context, isVideo);
            result = avcodec_send_packet(context, source);
        }
        check(result, "Send compressed packet");
        drainDecoder(context, isVideo);
    }
};
}

int convert(const std::string &inputPath, const std::string &outputPath, const Options &options,
            const std::function<bool()> &cancelled, const std::function<void(double)> &progress,
            std::string &message, Statistics *statistics) {
    if (statistics) *statistics = Statistics{};
    if (inputPath == outputPath) { message = "Input and output must differ"; return AVERROR(EINVAL); }
    int result = 0;
    try {
        Session s; s.cancelled = cancelled; s.statistics = statistics; s.stopIfCancelled();
        if (!s.packet || !s.encoded || !s.decoded || !s.software || !s.video || !s.upload) throw Failure{AVERROR(ENOMEM), "Allocate conversion"};
        s.input = avformat_alloc_context();
        if (!s.input) throw Failure{AVERROR(ENOMEM), "Allocate input"};
        s.input->interrupt_callback = {Session::interrupt, &s};
        check(avformat_open_input(&s.input, inputPath.c_str(), nullptr, nullptr), "Open conversion input");
        check(avformat_find_stream_info(s.input, nullptr), "Read conversion input");
        const bool video = !options.videoPreset.empty();
        const bool mp3 = options.audioFormat == "mp3";
        if (video && options.videoPreset != "hardware" && options.videoPreset != "ultrafast" && options.videoPreset != "veryfast" && options.videoPreset != "medium")
            throw Failure{AVERROR(EINVAL), "Unknown encoding preset"};
        check(avformat_alloc_output_context2(&s.output, nullptr, mp3 ? "mp3" : "mp4", outputPath.c_str()), "Create conversion output");
        av_dict_copy(&s.output->metadata, s.input->metadata, 0);
        for (const auto &entry : options.metadata) av_dict_set(&s.output->metadata, entry.first.c_str(), entry.second.c_str(), 0);
        if (video) {
            s.videoIndex = av_find_best_stream(s.input, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
            check(s.videoIndex, "Find video"); s.videoDecoder = s.decoder(s.videoIndex);
            if (options.videoPreset == "hardware") {
                if (statistics) statistics->hardwareAttempted = true;
                try { s.openVideoEncoder(true, ""); }
                catch (const Failure &failure) {
                    if (failure.code == AVERROR(ENOMEM) || failure.code == AVERROR_EXIT) throw;
                    if (statistics) statistics->hardwareInitError = failure.code;
                    avcodec_free_context(&s.videoEncoder); av_buffer_unref(&s.encoderFrames);
                    s.stopIfCancelled(); s.openVideoEncoder(false, "veryfast");
                }
            } else s.openVideoEncoder(false, options.videoPreset);
            auto *e = s.videoEncoder;
            s.videoOut = avformat_new_stream(s.output, nullptr);
            if (!s.videoOut) throw Failure{AVERROR(ENOMEM), "Create video stream"};
            check(avcodec_parameters_from_context(s.videoOut->codecpar, e), "Set H.264 parameters");
            s.videoOut->time_base = e->time_base;
            s.videoOut->avg_frame_rate = e->framerate;
            s.video->format = s.hardwareEncoder ? AV_PIX_FMT_NV12 : e->pix_fmt;
            s.video->width = e->width; s.video->height = e->height;
            s.video->color_range = e->color_range; s.video->colorspace = e->colorspace;
            check(av_frame_get_buffer(s.video, 32), "Allocate video frame");
        }
        s.audioIndex = av_find_best_stream(s.input, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
        check(s.audioIndex, "Find audio");
        s.audioOut = avformat_new_stream(s.output, nullptr);
        if (!s.audioOut) throw Failure{AVERROR(ENOMEM), "Create audio stream"};
        const bool copyAudio = video && s.input->streams[s.audioIndex]->codecpar->codec_id == AV_CODEC_ID_AAC;
        if (copyAudio) {
            check(avcodec_parameters_copy(s.audioOut->codecpar, s.input->streams[s.audioIndex]->codecpar), "Copy audio parameters");
            s.audioOut->codecpar->codec_tag = 0;
            s.audioOut->time_base = s.input->streams[s.audioIndex]->time_base;
        } else {
            s.audioDecoder = s.decoder(s.audioIndex);
            const AVCodec *codec = avcodec_find_encoder_by_name(mp3 ? "libmp3lame" : "aac");
            if (!codec) throw Failure{AVERROR_ENCODER_NOT_FOUND, "Find audio encoder"};
            s.audioEncoder = avcodec_alloc_context3(codec);
            if (!s.audioEncoder) throw Failure{AVERROR(ENOMEM), "Allocate audio encoder"};
            auto *e = s.audioEncoder;
            e->sample_fmt = AV_SAMPLE_FMT_FLTP;
            e->sample_rate = s.audioDecoder->sample_rate >= 46000 ? 48000 : 44100;
            av_channel_layout_default(&e->ch_layout, std::min(2, std::max(1, s.audioDecoder->ch_layout.nb_channels)));
            e->bit_rate = std::clamp(options.audioBitrate, 32000, mp3 ? 320000 : 256000);
            e->time_base = {1, e->sample_rate};
            if (s.output->oformat->flags & AVFMT_GLOBALHEADER) e->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
            check(avcodec_open2(e, codec, nullptr), "Open audio encoder");
            check(avcodec_parameters_from_context(s.audioOut->codecpar, e), "Set audio parameters");
            s.audioOut->time_base = e->time_base;
            check(swr_alloc_set_opts2(&s.resampler, &e->ch_layout, e->sample_fmt, e->sample_rate,
                &s.audioDecoder->ch_layout, s.audioDecoder->sample_fmt, s.audioDecoder->sample_rate, 0, nullptr), "Create resampler");
            check(swr_init(s.resampler), "Open resampler");
            s.fifo = av_audio_fifo_alloc(e->sample_fmt, e->ch_layout.nb_channels, 1);
            if (!s.fifo) throw Failure{AVERROR(ENOMEM), "Allocate audio queue"};
        }
        s.output->interrupt_callback = {Session::interrupt, &s};
        check(avio_open(&s.output->pb, outputPath.c_str(), AVIO_FLAG_WRITE), "Open output file");
        AVDictionary *muxOptions = nullptr;
        if (!mp3) av_dict_set(&muxOptions, "movflags", "+faststart", 0);
        int header = avformat_write_header(s.output, &muxOptions); av_dict_free(&muxOptions);
        check(header, "Write conversion header");
        double lastProgress = -1;
        while ((result = av_read_frame(s.input, s.packet)) >= 0) {
            s.stopIfCancelled();
            int index = s.packet->stream_index;
            if (progress && s.input->duration > 0 && s.packet->pts != AV_NOPTS_VALUE) {
                const AVStream *stream = s.input->streams[index];
                int64_t origin = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
                double fraction = std::clamp((s.packet->pts - origin) * av_q2d(stream->time_base) / (s.input->duration / double(AV_TIME_BASE)), 0.0, 0.99);
                if (fraction >= lastProgress + 0.005) { progress(fraction); lastProgress = fraction; }
            }
            if (video && index == s.videoIndex) s.decode(s.videoDecoder, s.packet, true);
            else if (index == s.audioIndex) {
                if (copyAudio) {
                    av_packet_rescale_ts(s.packet, s.input->streams[index]->time_base, s.audioOut->time_base);
                    s.packet->stream_index = s.audioOut->index;
                    check(av_interleaved_write_frame(s.output, s.packet), "Copy audio packet");
                } else s.decode(s.audioDecoder, s.packet, false);
            }
            av_packet_unref(s.packet);
        }
        if (result != AVERROR_EOF) check(result, "Read conversion packet");
        if (video) { s.decode(s.videoDecoder, nullptr, true); s.encode(s.videoEncoder, s.videoOut, nullptr); }
        if (!copyAudio) {
            s.decode(s.audioDecoder, nullptr, false); s.audioFrame(nullptr); s.writeAudio(true);
            s.encode(s.audioEncoder, s.audioOut, nullptr);
        }
        s.stopIfCancelled(); check(av_write_trailer(s.output), "Finish conversion");
        if (progress) progress(1);
        result = 0;
    } catch (const Failure &failure) {
        char error[AV_ERROR_MAX_STRING_SIZE] = {};
        av_strerror(failure.code, error, sizeof(error));
        result = failure.code; message = failure.stage + ": " + error;
    } catch (const std::exception &error) {
        result = AVERROR(ENOMEM); message = error.what();
    }
    if (result < 0) std::remove(outputPath.c_str());
    return result;
}

int embedMP3Artwork(const std::string &inputPath, const std::string &outputPath,
                    const std::vector<unsigned char> &jpeg, std::string &message) {
    if (inputPath == outputPath || jpeg.empty()) return AVERROR(EINVAL);
    int result = 0;
    try {
        Session s;
        check(avformat_open_input(&s.input, inputPath.c_str(), nullptr, nullptr), "Open MP3");
        check(avformat_find_stream_info(s.input, nullptr), "Read MP3");
        int audio = av_find_best_stream(s.input, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
        check(audio, "Find MP3 audio");
        check(avformat_alloc_output_context2(&s.output, nullptr, "mp3", outputPath.c_str()), "Create MP3 artwork output");
        AVStream *track = avformat_new_stream(s.output, nullptr);
        AVStream *cover = avformat_new_stream(s.output, nullptr);
        if (!track || !cover) throw Failure{AVERROR(ENOMEM), "Allocate MP3 streams"};
        check(avcodec_parameters_copy(track->codecpar, s.input->streams[audio]->codecpar), "Copy MP3 parameters");
        track->time_base = s.input->streams[audio]->time_base;
        track->codecpar->codec_tag = 0;
        cover->codecpar->codec_type = AVMEDIA_TYPE_VIDEO;
        cover->codecpar->codec_id = AV_CODEC_ID_MJPEG;
        cover->disposition = AV_DISPOSITION_ATTACHED_PIC;
        const AVCodec *jpegDecoder = avcodec_find_decoder(AV_CODEC_ID_MJPEG);
        if (!jpegDecoder) throw Failure{AVERROR_DECODER_NOT_FOUND, "Find artwork decoder"};
        s.videoDecoder = avcodec_alloc_context3(jpegDecoder);
        if (!s.videoDecoder) throw Failure{AVERROR(ENOMEM), "Allocate artwork decoder"};
        check(avcodec_open2(s.videoDecoder, jpegDecoder, nullptr), "Open artwork decoder");
        check(av_new_packet(s.packet, static_cast<int>(jpeg.size())), "Allocate artwork packet");
        std::copy(jpeg.begin(), jpeg.end(), s.packet->data);
        check(avcodec_send_packet(s.videoDecoder, s.packet), "Read artwork image");
        check(avcodec_receive_frame(s.videoDecoder, s.decoded), "Decode artwork image");
        cover->codecpar->width = s.decoded->width;
        cover->codecpar->height = s.decoded->height;
        av_dict_set(&cover->metadata, "title", "Album cover", 0);
        av_dict_set(&cover->metadata, "comment", "Cover (front)", 0);
        av_dict_copy(&s.output->metadata, s.input->metadata, 0);
        check(avio_open(&s.output->pb, outputPath.c_str(), AVIO_FLAG_WRITE), "Open MP3 output");
        check(avformat_write_header(s.output, nullptr), "Write MP3 header");
        s.packet->stream_index = cover->index; s.packet->flags |= AV_PKT_FLAG_KEY;
        check(av_interleaved_write_frame(s.output, s.packet), "Write MP3 artwork");
        av_packet_unref(s.packet);
        while ((result = av_read_frame(s.input, s.packet)) >= 0) {
            if (s.packet->stream_index == audio) {
                av_packet_rescale_ts(s.packet, s.input->streams[audio]->time_base, track->time_base);
                s.packet->stream_index = track->index;
                check(av_interleaved_write_frame(s.output, s.packet), "Write MP3 audio");
            }
            av_packet_unref(s.packet);
        }
        if (result != AVERROR_EOF) check(result, "Read MP3 packet");
        check(av_write_trailer(s.output), "Finish MP3 artwork"); result = 0;
    } catch (const Failure &failure) {
        char error[AV_ERROR_MAX_STRING_SIZE] = {};
        av_strerror(failure.code, error, sizeof(error));
        result = failure.code; message = failure.stage + ": " + error;
    } catch (const std::exception &error) { result = AVERROR(ENOMEM); message = error.what(); }
    if (result < 0) std::remove(outputPath.c_str());
    return result;
}
}
