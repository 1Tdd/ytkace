#import "FFmpegMuxer.h"
#import <copyfile.h>
#include <vector>
#include <algorithm>

#define AVMediaType YTKACEFFmpegMediaType
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/packet.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <libavutil/hwcontext.h>
}
#undef AVMediaType

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import "DownloadLog.h"

static NSString *YTKACEFFmpegMessage(int code) {
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, buffer, sizeof(buffer));
    return [NSString stringWithUTF8String:buffer] ?: @"FFmpeg failed";
}

static NSError *YTKACEFFmpegError(int code, NSString *stage) {
    NSString *message = [NSString stringWithFormat:@"%@: %@", stage,
        YTKACEFFmpegMessage(code)];
    return [NSError errorWithDomain:@"YTKACEFFmpeg" code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static int YTKACEOpenInput(NSURL *URL, enum YTKACEFFmpegMediaType type,
                           AVFormatContext **context, int *streamIndex) {
    int result = avformat_open_input(context, URL.fileSystemRepresentation,
        NULL, NULL);
    if (result < 0) return result;
    result = avformat_find_stream_info(*context, NULL);
    if (result < 0) return result;
    result = av_find_best_stream(*context, type, -1, -1, NULL, 0);
    if (result < 0) return result;
    *streamIndex = result;
    return 0;
}

static int YTKACEReadPacket(AVFormatContext *context, int streamIndex,
                            AVPacket *packet) {
    int result = 0;
    while ((result = av_read_frame(context, packet)) >= 0) {
        if (packet->stream_index == streamIndex) return 0;
        av_packet_unref(packet);
    }
    return result;
}

static int64_t YTKACEPacketTime(AVPacket *packet, AVStream *stream) {
    int64_t value = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
    return value == AV_NOPTS_VALUE ? INT64_MAX :
        av_rescale_q(value, stream->time_base, AV_TIME_BASE_Q);
}

static int YTKACEWritePacket(AVFormatContext *output, AVPacket *packet,
                             AVStream *inputStream, AVStream *outputStream) {
    av_packet_rescale_ts(packet, inputStream->time_base, outputStream->time_base);
    packet->stream_index = outputStream->index;
    packet->pos = -1;
    int result = av_interleaved_write_frame(output, packet);
    av_packet_unref(packet);
    return result;
}

struct YTKACECutInterval {
    int64_t startUs;
    int64_t endUs;
};

static std::vector<YTKACECutInterval> YTKACEParseCutIntervals(NSArray<NSDictionary *> *removedSegments) {
    std::vector<YTKACECutInterval> intervals;
    if (removedSegments.count == 0) return intervals;
    for (NSDictionary *dict in removedSegments) {
        if (![dict isKindOfClass:NSDictionary.class]) continue;
        double s = 0.0;
        double e = 0.0;
        if (dict[@"start"] && dict[@"end"]) {
            s = [dict[@"start"] doubleValue];
            e = [dict[@"end"] doubleValue];
        } else if ([dict[@"segment"] isKindOfClass:NSArray.class] && [dict[@"segment"] count] >= 2) {
            s = [dict[@"segment"][0] doubleValue];
            e = [dict[@"segment"][1] doubleValue];
        }
        if (e > s && isfinite(s) && isfinite(e)) {
            intervals.push_back({
                (int64_t)(s * AV_TIME_BASE),
                (int64_t)(e * AV_TIME_BASE)
            });
        }
    }
    if (intervals.empty()) return intervals;
    std::sort(intervals.begin(), intervals.end(),
        [](const YTKACECutInterval &a, const YTKACECutInterval &b) {
            return a.startUs < b.startUs;
        });
    std::vector<YTKACECutInterval> merged;
    for (const auto &iv : intervals) {
        if (merged.empty()) {
            merged.push_back(iv);
        } else {
            if (iv.startUs <= merged.back().endUs) {
                merged.back().endUs = std::max(merged.back().endUs, iv.endUs);
            } else {
                merged.push_back(iv);
            }
        }
    }
    return merged;
}

static int YTKACEGetStreamIndexEntriesCount(const AVStream *st) {
#if LIBAVFORMAT_VERSION_MAJOR >= 59
    return avformat_index_get_entries_count(st);
#else
    return st ? st->nb_index_entries : 0;
#endif
}

static int64_t YTKACEGetStreamIndexEntryTimestamp(const AVStream *st, int idx) {
#if LIBAVFORMAT_VERSION_MAJOR >= 59
    const AVIndexEntry *e = avformat_index_get_entry(const_cast<AVStream *>(st), idx);
    return e ? e->timestamp : -1;
#else
    if (st && idx >= 0 && idx < st->nb_index_entries) {
        return st->index_entries[idx].timestamp;
    }
    return -1;
#endif
}

static void YTKACESnapCutIntervalsToKeyframes(std::vector<YTKACECutInterval> &cuts, AVStream *vStream) {
    if (cuts.empty() || vStream == NULL) return;
    int count = YTKACEGetStreamIndexEntriesCount(vStream);
    if (count <= 0) return;
    for (size_t i = 0; i < cuts.size(); i++) {
        int64_t endUs = cuts[i].endUs;
        int64_t targetTs = av_rescale_q(endUs, AV_TIME_BASE_Q, vStream->time_base);

        int idxPrev = av_index_search_timestamp(vStream, targetTs, AVSEEK_FLAG_BACKWARD);
        int idxNext = av_index_search_timestamp(vStream, targetTs, 0);

        int64_t prevUs = -1;
        int64_t nextUs = -1;

        if (idxPrev >= 0 && idxPrev < count) {
            int64_t ts = YTKACEGetStreamIndexEntryTimestamp(vStream, idxPrev);
            if (ts >= 0) {
                prevUs = av_rescale_q(ts, vStream->time_base, AV_TIME_BASE_Q);
            }
        }
        if (idxNext >= 0 && idxNext < count) {
            int64_t ts = YTKACEGetStreamIndexEntryTimestamp(vStream, idxNext);
            if (ts >= 0) {
                nextUs = av_rescale_q(ts, vStream->time_base, AV_TIME_BASE_Q);
            }
        }

        int64_t chosenEndUs = endUs;
        if (nextUs >= 0 && (nextUs - endUs) <= 250000) {
            chosenEndUs = nextUs;
        } else if (prevUs >= 0 && prevUs > cuts[i].startUs) {
            chosenEndUs = prevUs;
        } else if (nextUs >= 0 && nextUs > cuts[i].startUs) {
            chosenEndUs = nextUs;
        }

        if (chosenEndUs > cuts[i].startUs) {
            cuts[i].endUs = chosenEndUs;
        }
    }

    for (size_t i = 0; i + 1 < cuts.size(); i++) {
        if (cuts[i].endUs > cuts[i + 1].startUs) {
            cuts[i].endUs = cuts[i + 1].startUs;
        }
    }
}

static bool YTKACEIsInsideCut(int64_t timeUs, const std::vector<YTKACECutInterval> &cuts, int64_t &droppedBeforeUs) {
    droppedBeforeUs = 0;
    for (const auto &cut : cuts) {
        if (timeUs < cut.startUs) {
            return false;
        }
        if (timeUs < cut.endUs) {
            return true;
        }
        droppedBeforeUs += (cut.endUs - cut.startUs);
    }
    return false;
}

static NSError *YTKACERemux(NSURL *videoURL, NSURL *audioURL,
                            NSURL *outputURL,
                            NSArray<NSDictionary *> *removedSegments) {
    AVFormatContext *video = NULL;
    AVFormatContext *audio = NULL;
    AVFormatContext *output = NULL;
    AVPacket *videoPacket = NULL;
    AVPacket *audioPacket = NULL;
    AVStream *videoInput = NULL;
    AVStream *audioInput = NULL;
    AVStream *videoOutput = NULL;
    AVStream *audioOutput = NULL;
    AVDictionary *options = NULL;
    int videoIndex = -1;
    int audioIndex = -1;
    BOOL hasVideo = NO;
    BOOL hasAudio = NO;
    NSString *stage = @"Open video";
    int result = YTKACEOpenInput(videoURL, AVMEDIA_TYPE_VIDEO, &video, &videoIndex);
    if (result < 0) goto cleanup;
    result = YTKACEOpenInput(audioURL, AVMEDIA_TYPE_AUDIO, &audio, &audioIndex);
    stage = @"Open audio";
    if (result < 0) goto cleanup;
    result = avformat_alloc_output_context2(&output, NULL, "mp4",
        outputURL.fileSystemRepresentation);
    stage = @"Create output";
    if (result < 0 || output == NULL) {
        if (result >= 0) result = AVERROR_UNKNOWN;
        goto cleanup;
    }
    videoInput = video->streams[videoIndex];
    audioInput = audio->streams[audioIndex];
    videoOutput = avformat_new_stream(output, NULL);
    audioOutput = avformat_new_stream(output, NULL);
    stage = @"Create tracks";
    if (videoOutput == NULL || audioOutput == NULL) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    result = avcodec_parameters_copy(videoOutput->codecpar, videoInput->codecpar);
    if (result < 0) goto cleanup;
    result = avcodec_parameters_copy(audioOutput->codecpar, audioInput->codecpar);
    if (result < 0) goto cleanup;
    videoOutput->codecpar->codec_tag = 0;
    audioOutput->codecpar->codec_tag = 0;
    videoOutput->time_base = videoInput->time_base;
    audioOutput->time_base = audioInput->time_base;
    if ((output->oformat->flags & AVFMT_NOFILE) == 0) {
        result = avio_open(&output->pb, outputURL.fileSystemRepresentation,
            AVIO_FLAG_WRITE);
        stage = @"Open output";
        if (result < 0) goto cleanup;
    }
    av_dict_set(&options, "movflags", "+faststart", 0);
    av_dict_set(&options, "use_editlist", "0", 0);
    result = avformat_write_header(output, &options);
    stage = @"Write header";
    if (result < 0) goto cleanup;

    videoPacket = av_packet_alloc();
    audioPacket = av_packet_alloc();
    if (videoPacket == NULL || audioPacket == NULL) {
        result = AVERROR(ENOMEM);
        stage = @"Create packets";
        goto cleanup;
    }

    {
        std::vector<YTKACECutInterval> cuts = YTKACEParseCutIntervals(removedSegments);
        YTKACESnapCutIntervalsToKeyframes(cuts, videoInput);

        int64_t lastVideoDts = AV_NOPTS_VALUE;
        int64_t lastAudioDts = AV_NOPTS_VALUE;
        bool videoNeedsKeyframe = false;

        hasVideo = YTKACEReadPacket(video, videoIndex, videoPacket) >= 0;
        hasAudio = YTKACEReadPacket(audio, audioIndex, audioPacket) >= 0;
        while (hasVideo || hasAudio) {
            BOOL writeVideo = hasVideo;
            if (hasVideo && hasAudio) {
                writeVideo = YTKACEPacketTime(videoPacket, videoInput) <=
                    YTKACEPacketTime(audioPacket, audioInput);
            }
            if (writeVideo) {
                int64_t vTime = YTKACEPacketTime(videoPacket, videoInput);
                int64_t droppedBeforeUs = 0;
                if (YTKACEIsInsideCut(vTime, cuts, droppedBeforeUs)) {
                    videoNeedsKeyframe = true;
                    av_packet_unref(videoPacket);
                    hasVideo = YTKACEReadPacket(video, videoIndex, videoPacket) >= 0;
                    continue;
                }

                if (videoNeedsKeyframe) {
                    if (!(videoPacket->flags & AV_PKT_FLAG_KEY)) {
                        av_packet_unref(videoPacket);
                        hasVideo = YTKACEReadPacket(video, videoIndex, videoPacket) >= 0;
                        continue;
                    }
                    videoNeedsKeyframe = false;
                }

                if (droppedBeforeUs > 0) {
                    int64_t offset = av_rescale_q(droppedBeforeUs, AV_TIME_BASE_Q, videoInput->time_base);
                    if (videoPacket->pts != AV_NOPTS_VALUE) videoPacket->pts = MAX(0LL, videoPacket->pts - offset);
                    if (videoPacket->dts != AV_NOPTS_VALUE) videoPacket->dts = MAX(0LL, videoPacket->dts - offset);
                }
                if (lastVideoDts != AV_NOPTS_VALUE && videoPacket->dts != AV_NOPTS_VALUE && videoPacket->dts <= lastVideoDts) {
                    videoPacket->dts = lastVideoDts + 1;
                }
                if (videoPacket->pts != AV_NOPTS_VALUE && videoPacket->dts != AV_NOPTS_VALUE && videoPacket->pts < videoPacket->dts) {
                    videoPacket->pts = videoPacket->dts;
                }
                if (videoPacket->dts != AV_NOPTS_VALUE) lastVideoDts = videoPacket->dts;

                result = YTKACEWritePacket(output, videoPacket, videoInput, videoOutput);
                stage = @"Write video";
                if (result < 0) goto cleanup;
                hasVideo = YTKACEReadPacket(video, videoIndex, videoPacket) >= 0;
            } else {
                int64_t aTime = YTKACEPacketTime(audioPacket, audioInput);
                int64_t droppedBeforeUs = 0;
                if (YTKACEIsInsideCut(aTime, cuts, droppedBeforeUs)) {
                    av_packet_unref(audioPacket);
                    hasAudio = YTKACEReadPacket(audio, audioIndex, audioPacket) >= 0;
                    continue;
                }

                if (droppedBeforeUs > 0) {
                    int64_t offset = av_rescale_q(droppedBeforeUs, AV_TIME_BASE_Q, audioInput->time_base);
                    if (audioPacket->pts != AV_NOPTS_VALUE) audioPacket->pts = MAX(0LL, audioPacket->pts - offset);
                    if (audioPacket->dts != AV_NOPTS_VALUE) audioPacket->dts = MAX(0LL, audioPacket->dts - offset);
                }
                if (lastAudioDts != AV_NOPTS_VALUE && audioPacket->dts != AV_NOPTS_VALUE && audioPacket->dts <= lastAudioDts) {
                    audioPacket->dts = lastAudioDts + 1;
                }
                if (audioPacket->pts != AV_NOPTS_VALUE && audioPacket->dts != AV_NOPTS_VALUE && audioPacket->pts < audioPacket->dts) {
                    audioPacket->pts = audioPacket->dts;
                }
                if (audioPacket->dts != AV_NOPTS_VALUE) lastAudioDts = audioPacket->dts;

                result = YTKACEWritePacket(output, audioPacket, audioInput, audioOutput);
                stage = @"Write audio";
                if (result < 0) goto cleanup;
                hasAudio = YTKACEReadPacket(audio, audioIndex, audioPacket) >= 0;
            }
        }
    }
    result = av_write_trailer(output);
    stage = @"Write trailer";

cleanup:
    av_dict_free(&options);
    av_packet_free(&videoPacket);
    av_packet_free(&audioPacket);
    avformat_close_input(&video);
    avformat_close_input(&audio);
    if (output != NULL) {
        if (output->pb != NULL) avio_closep(&output->pb);
        avformat_free_context(output);
    }
    return result < 0 ? YTKACEFFmpegError(result, stage) : nil;
}

static NSError *YTKACERemuxAudio(NSURL *audioURL, NSURL *outputURL,
                                 NSArray<NSDictionary *> *removedSegments) {
    AVFormatContext *audio = NULL;
    AVFormatContext *output = NULL;
    AVPacket *packet = NULL;
    AVStream *audioInput = NULL;
    AVStream *audioOutput = NULL;
    AVDictionary *options = NULL;
    int audioIndex = -1;
    NSString *stage = @"Open audio";
    int result = YTKACEOpenInput(audioURL, AVMEDIA_TYPE_AUDIO, &audio, &audioIndex);
    if (result < 0) goto cleanup;
    result = avformat_alloc_output_context2(&output, NULL, "mp4",
        outputURL.fileSystemRepresentation);
    stage = @"Create output";
    if (result < 0 || output == NULL) {
        if (result >= 0) result = AVERROR_UNKNOWN;
        goto cleanup;
    }
    audioInput = audio->streams[audioIndex];
    audioOutput = avformat_new_stream(output, NULL);
    stage = @"Create track";
    if (audioOutput == NULL) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    result = avcodec_parameters_copy(audioOutput->codecpar, audioInput->codecpar);
    if (result < 0) goto cleanup;
    audioOutput->codecpar->codec_tag = 0;
    audioOutput->time_base = audioInput->time_base;
    if ((output->oformat->flags & AVFMT_NOFILE) == 0) {
        result = avio_open(&output->pb, outputURL.fileSystemRepresentation,
            AVIO_FLAG_WRITE);
        stage = @"Open output";
        if (result < 0) goto cleanup;
    }
    av_dict_set(&options, "movflags", "+faststart", 0);
    av_dict_set(&options, "use_editlist", "0", 0);
    result = avformat_write_header(output, &options);
    stage = @"Write header";
    if (result < 0) goto cleanup;
    packet = av_packet_alloc();
    if (packet == NULL) {
        result = AVERROR(ENOMEM);
        stage = @"Create packet";
        goto cleanup;
    }

    {
        std::vector<YTKACECutInterval> cuts = YTKACEParseCutIntervals(removedSegments);
        int64_t lastAudioDts = AV_NOPTS_VALUE;

        while ((result = YTKACEReadPacket(audio, audioIndex, packet)) >= 0) {
            int64_t aTime = YTKACEPacketTime(packet, audioInput);
            int64_t droppedBeforeUs = 0;
            if (YTKACEIsInsideCut(aTime, cuts, droppedBeforeUs)) {
                av_packet_unref(packet);
                continue;
            }

            if (droppedBeforeUs > 0) {
                int64_t offset = av_rescale_q(droppedBeforeUs, AV_TIME_BASE_Q, audioInput->time_base);
                if (packet->pts != AV_NOPTS_VALUE) packet->pts = MAX(0LL, packet->pts - offset);
                if (packet->dts != AV_NOPTS_VALUE) packet->dts = MAX(0LL, packet->dts - offset);
            }
            if (lastAudioDts != AV_NOPTS_VALUE && packet->dts != AV_NOPTS_VALUE && packet->dts <= lastAudioDts) {
                packet->dts = lastAudioDts + 1;
            }
            if (packet->pts != AV_NOPTS_VALUE && packet->dts != AV_NOPTS_VALUE && packet->pts < packet->dts) {
                packet->pts = packet->dts;
            }
            if (packet->dts != AV_NOPTS_VALUE) lastAudioDts = packet->dts;

            result = YTKACEWritePacket(output, packet, audioInput, audioOutput);
            stage = @"Write audio";
            if (result < 0) goto cleanup;
        }
    }
    if (result == AVERROR_EOF) result = 0;
    if (result < 0) goto cleanup;
    result = av_write_trailer(output);
    stage = @"Write trailer";

cleanup:
    av_dict_free(&options);
    av_packet_free(&packet);
    avformat_close_input(&audio);
    if (output != NULL) {
        if (output->pb != NULL) avio_closep(&output->pb);
        avformat_free_context(output);
    }
    return result < 0 ? YTKACEFFmpegError(result, stage) : nil;
}


static NSMutableSet<NSString *> *YTKACECancelledConversions(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

void YTKACEFFmpegCancelConversion(NSString *identifier) {
    if (identifier.length == 0) return;
    @synchronized (YTKACECancelledConversions()) {
        [YTKACECancelledConversions() addObject:identifier];
    }
    YTKACEDownloadLog(@"convert", @"cancel requested %@", identifier);
}

static NSError *YTKACEAudioToVideo(NSURL *audioURL, NSData *artwork,
                                   NSURL *outputURL,
                                   YTKACEFFmpegProgress progress) {
    NSString *artworkPath = nil;
    if (artwork.length != 0) {
        artworkPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"ytkace-art.jpg"];
        [artwork writeToFile:artworkPath atomically:YES];
    }
    AVFormatContext *audioInput = NULL;
    AVFormatContext *imageInput = NULL;
    AVFormatContext *output = NULL;
    AVCodecContext *imageDecoder = NULL;
    AVCodecContext *encoder = NULL;
    struct SwsContext *scaler = NULL;
    AVFrame *imageFrame = av_frame_alloc();
    AVFrame *videoFrame = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    NSError *error = nil;
    int audioIndex = -1;

    if (avformat_open_input(&audioInput, audioURL.path.UTF8String, NULL, NULL) < 0 ||
        avformat_find_stream_info(audioInput, NULL) < 0) {
        error = YTKACEFFmpegError(-1, @"Could not read the audio");
        goto finish;
    }
    for (unsigned int index = 0; index < audioInput->nb_streams; index++) {
        if (audioInput->streams[index]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            audioIndex = (int)index;
            break;
        }
    }
    if (audioIndex < 0) {
        error = YTKACEFFmpegError(-1, @"No audio track");
        goto finish;
    }

    {
        const int width = 720;
        const int height = 720;
        avformat_alloc_output_context2(&output, NULL, "mp4",
                                       outputURL.path.UTF8String);
        if (output == NULL) {
            error = YTKACEFFmpegError(-1, @"Could not create the file");
            goto finish;
        }
        const AVCodec *encoderCodec =
            avcodec_find_encoder_by_name("h264_videotoolbox");
        if (encoderCodec == NULL) {
            error = YTKACEFFmpegError(-1, @"Conversion is unavailable");
            goto finish;
        }
        encoder = avcodec_alloc_context3(encoderCodec);
        encoder->width = width;
        encoder->height = height;
        encoder->pix_fmt = AV_PIX_FMT_NV12;
        encoder->time_base = (AVRational){1, 1};
        encoder->framerate = (AVRational){1, 1};
        encoder->bit_rate = 400000;
        if (output->oformat->flags & AVFMT_GLOBALHEADER) {
            encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        }
        if (avcodec_open2(encoder, encoderCodec, NULL) < 0) {
            error = YTKACEFFmpegError(-1, @"Conversion is unavailable");
            goto finish;
        }
        AVStream *videoStream = avformat_new_stream(output, NULL);
        avcodec_parameters_from_context(videoStream->codecpar, encoder);
        videoStream->codecpar->codec_tag = MKTAG('a', 'v', 'c', '1');
        videoStream->time_base = encoder->time_base;
        AVStream *audioStream = avformat_new_stream(output, NULL);
        avcodec_parameters_copy(audioStream->codecpar,
                                audioInput->streams[audioIndex]->codecpar);
        audioStream->codecpar->codec_tag = 0;

        if (!(output->oformat->flags & AVFMT_NOFILE)) {
            if (avio_open(&output->pb, outputURL.path.UTF8String,
                          AVIO_FLAG_WRITE) < 0) {
                error = YTKACEFFmpegError(-1, @"Could not create the file");
                goto finish;
            }
        }
        if (avformat_write_header(output, NULL) < 0) {
            error = YTKACEFFmpegError(-1, @"Could not create the file");
            goto finish;
        }

        videoFrame->format = AV_PIX_FMT_NV12;
        videoFrame->width = width;
        videoFrame->height = height;
        av_frame_get_buffer(videoFrame, 0);
        memset(videoFrame->data[0], 16, (size_t)videoFrame->linesize[0] * height);
        memset(videoFrame->data[1], 128,
               (size_t)videoFrame->linesize[1] * height / 2);

        YTKACEDownloadLog(@"convert", @"artwork bytes=%lu path=%@",
            (unsigned long)artwork.length, artworkPath ?: @"none");
        if (artworkPath != nil &&
            avformat_open_input(&imageInput, artworkPath.UTF8String, NULL, NULL) >= 0 &&
            avformat_find_stream_info(imageInput, NULL) >= 0) {
            const AVCodec *imageCodec =
                avcodec_find_decoder(imageInput->streams[0]->codecpar->codec_id);
            if (imageCodec != NULL) {
                imageDecoder = avcodec_alloc_context3(imageCodec);
                avcodec_parameters_to_context(imageDecoder,
                                              imageInput->streams[0]->codecpar);
                if (avcodec_open2(imageDecoder, imageCodec, NULL) >= 0 &&
                    av_read_frame(imageInput, packet) >= 0 &&
                    avcodec_send_packet(imageDecoder, packet) >= 0 &&
                    avcodec_receive_frame(imageDecoder, imageFrame) >= 0) {
                    scaler = sws_getContext(imageFrame->width, imageFrame->height,
                        (enum AVPixelFormat)imageFrame->format, width, height,
                        AV_PIX_FMT_NV12, SWS_BILINEAR, NULL, NULL, NULL);
                    if (scaler != NULL) {
                        sws_scale(scaler, imageFrame->data, imageFrame->linesize,
                                  0, imageFrame->height, videoFrame->data,
                                  videoFrame->linesize);
                    }
                    YTKACEDownloadLog(@"convert", @"artwork frame %dx%d scaler=%d",
                        imageFrame->width, imageFrame->height, scaler != NULL);
                }
                av_packet_unref(packet);
            }
        }

        int64_t duration = 0;
        if (audioInput->duration > 0 && audioInput->duration != AV_NOPTS_VALUE) {
            duration = audioInput->duration / AV_TIME_BASE;
        } else if (audioIndex >= 0 && audioInput->streams[audioIndex]->duration > 0 &&
                   audioInput->streams[audioIndex]->duration != AV_NOPTS_VALUE) {
            duration = av_rescale_q(audioInput->streams[audioIndex]->duration,
                                    audioInput->streams[audioIndex]->time_base,
                                    (AVRational){1, 1});
        }
        const int64_t frames = MAX((int64_t)1, duration);
        for (int64_t index = 0; index < frames; index++) {
            videoFrame->pts = index;
            if (avcodec_send_frame(encoder, videoFrame) >= 0) {
                AVPacket *encoded = av_packet_alloc();
                while (avcodec_receive_packet(encoder, encoded) >= 0) {
                    encoded->stream_index = videoStream->index;
                    av_packet_rescale_ts(encoded, encoder->time_base,
                                         videoStream->time_base);
                    av_interleaved_write_frame(output, encoded);
                    av_packet_unref(encoded);
                }
                av_packet_free(&encoded);
            }
            if (progress != nil && frames > 0) {
                progress(MIN(1.0, (double)(index + 1) / (double)frames));
            }
        }
        avcodec_send_frame(encoder, NULL);
        AVPacket *flush = av_packet_alloc();
        while (avcodec_receive_packet(encoder, flush) >= 0) {
            flush->stream_index = videoStream->index;
            av_packet_rescale_ts(flush, encoder->time_base,
                                 videoStream->time_base);
            av_interleaved_write_frame(output, flush);
            av_packet_unref(flush);
        }
        av_packet_free(&flush);

        while (av_read_frame(audioInput, packet) >= 0) {
            if (packet->stream_index == audioIndex) {
                packet->stream_index = audioStream->index;
                av_packet_rescale_ts(packet,
                    audioInput->streams[audioIndex]->time_base,
                    audioStream->time_base);
                av_interleaved_write_frame(output, packet);
            }
            av_packet_unref(packet);
        }
        av_write_trailer(output);
    }

finish:
    if (scaler != NULL) sws_freeContext(scaler);
    if (imageDecoder != NULL) avcodec_free_context(&imageDecoder);
    if (encoder != NULL) avcodec_free_context(&encoder);
    if (output != NULL) {
        if (output->pb != NULL && !(output->oformat->flags & AVFMT_NOFILE)) {
            avio_closep(&output->pb);
        }
        avformat_free_context(output);
    }
    if (imageInput != NULL) avformat_close_input(&imageInput);
    if (audioInput != NULL) avformat_close_input(&audioInput);
    av_frame_free(&imageFrame);
    av_frame_free(&videoFrame);
    av_packet_free(&packet);
    if (artworkPath != nil) {
        [NSFileManager.defaultManager removeItemAtPath:artworkPath error:NULL];
    }
    return error;
}

static NSArray<NSDictionary *> *YTKACENormalizedCues(NSArray<NSDictionary *> *cues) {
    NSCharacterSet *invisible = [NSCharacterSet characterSetWithCharactersInString:@"\u200b\u200c\u200d\ufeff"];
    NSMutableArray<NSMutableDictionary *> *clean = [NSMutableArray array];
    for (NSDictionary *cue in cues) {
        NSString *text = cue[@"text"];
        if (![text isKindOfClass:NSString.class]) continue;
        text = [[text componentsSeparatedByCharactersInSet:invisible] componentsJoinedByString:@""];
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceCharacterSet];
            if (trimmed.length != 0) [lines addObject:trimmed];
        }
        text = [lines componentsJoinedByString:@"\n"];
        double start = [cue[@"start"] doubleValue];
        double end = [cue[@"end"] doubleValue];
        if (text.length == 0 || !isfinite(start) || !isfinite(end) || end - start < 0.05) continue;
        [clean addObject:[@{@"text": text, @"start": @(start), @"end": @(end)} mutableCopy]];
    }
    [clean sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"start"] compare:right[@"start"]];
    }];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSMutableDictionary *cue in clean) {
        NSMutableDictionary *previous = (NSMutableDictionary *)result.lastObject;
        double start = [cue[@"start"] doubleValue];
        if (previous != nil) {
            double previousStart = [previous[@"start"] doubleValue];
            if (start - previousStart < 0.05) {
                if ([cue[@"text"] length] >= [previous[@"text"] length]) {
                    previous[@"text"] = cue[@"text"];
                }
                previous[@"end"] = @(MAX([previous[@"end"] doubleValue], [cue[@"end"] doubleValue]));
                continue;
            }
            if ([previous[@"end"] doubleValue] > start) previous[@"end"] = @(start);
            if ([previous[@"text"] isEqualToString:cue[@"text"]]) {
                previous[@"end"] = cue[@"end"];
                continue;
            }
        }
        [result addObject:cue];
    }
    return result;
}

static NSString *YTKACEMP4LanguageCode(NSString *language) {
    NSString *base = [[language.lowercaseString componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"-_"]] firstObject];
    if (base.length == 3) return base;
    static NSDictionary<NSString *, NSString *> *codes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        codes = @{@"af": @"afr", @"am": @"amh", @"ar": @"ara", @"az": @"aze", @"be": @"bel", @"bg": @"bul", @"bn": @"ben", @"bs": @"bos", @"ca": @"cat", @"cs": @"ces", @"cy": @"cym", @"da": @"dan", @"de": @"deu", @"el": @"ell", @"en": @"eng", @"es": @"spa", @"et": @"est", @"eu": @"eus", @"fa": @"fas", @"fi": @"fin", @"fil": @"fil", @"fr": @"fra", @"ga": @"gle", @"gl": @"glg", @"gu": @"guj", @"he": @"heb", @"iw": @"heb", @"hi": @"hin", @"hr": @"hrv", @"hu": @"hun", @"hy": @"hye", @"id": @"ind", @"is": @"isl", @"it": @"ita", @"ja": @"jpn", @"jv": @"jav", @"ka": @"kat", @"kk": @"kaz", @"km": @"khm", @"kn": @"kan", @"ko": @"kor", @"ku": @"kur", @"ky": @"kir", @"lo": @"lao", @"lt": @"lit", @"lv": @"lav", @"mk": @"mkd", @"ml": @"mal", @"mn": @"mon", @"mr": @"mar", @"ms": @"msa", @"my": @"mya", @"ne": @"nep", @"nl": @"nld", @"no": @"nor", @"nb": @"nob", @"pa": @"pan", @"pl": @"pol", @"ps": @"pus", @"pt": @"por", @"ro": @"ron", @"ru": @"rus", @"si": @"sin", @"sk": @"slk", @"sl": @"slv", @"so": @"som", @"sq": @"sqi", @"sr": @"srp", @"sv": @"swe", @"sw": @"swa", @"ta": @"tam", @"te": @"tel", @"th": @"tha", @"tl": @"tgl", @"tr": @"tur", @"uk": @"ukr", @"ur": @"urd", @"uz": @"uzb", @"vi": @"vie", @"zh": @"zho", @"zu": @"zul"};
    });
    return base.length != 0 ? codes[base] : nil;
}

@implementation YTKACEFFmpegMuxer

+ (void)remuxAudioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(YTKACEFFmpegCompletion)completion {
    [self remuxAudioURL:audioURL outputURL:outputURL removedSegments:nil completion:completion];
}

+ (void)remuxAudioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
      removedSegments:(nullable NSArray<NSDictionary *> *)removedSegments
           completion:(YTKACEFFmpegCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
        av_log_set_level(AV_LOG_ERROR);
        NSError *error = YTKACERemuxAudio(audioURL, outputURL, removedSegments);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

+ (void)remuxVideoURL:(NSURL *)videoURL
             audioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(YTKACEFFmpegCompletion)completion {
    [self remuxVideoURL:videoURL audioURL:audioURL outputURL:outputURL removedSegments:nil completion:completion];
}

+ (void)remuxVideoURL:(NSURL *)videoURL
             audioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
      removedSegments:(nullable NSArray<NSDictionary *> *)removedSegments
           completion:(YTKACEFFmpegCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
        av_log_set_level(AV_LOG_ERROR);
        NSError *error = YTKACERemux(videoURL, audioURL, outputURL, removedSegments);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

+ (void)normalizeMediaURL:(NSURL *)mediaURL
                outputURL:(NSURL *)outputURL
               completion:(YTKACEFFmpegCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
        av_log_set_level(AV_LOG_ERROR);
        NSError *error = YTKACERemux(mediaURL, mediaURL, outputURL, nil);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

static BOOL YTKACEPatchTextSampleDescription(NSURL *URL,
                                             int width,
                                             int height) {
    NSMutableData *data = [NSMutableData dataWithContentsOfURL:URL];
    if (data.length < 64) return NO;
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    const NSUInteger length = data.length;
    NSUInteger patched = 0;
    for (NSUInteger index = 4; index + 46 <= length; index++) {
        if (memcmp(bytes + index, "tx3g", 4) != 0) continue;
        const NSUInteger entry = index - 4;
        const uint32_t size = ((uint32_t)bytes[entry] << 24) |
            ((uint32_t)bytes[entry + 1] << 16) |
            ((uint32_t)bytes[entry + 2] << 8) | bytes[entry + 3];
        if (size < 46 || entry + size > length) continue;
        NSUInteger cursor = entry + 16;
        if (cursor + 30 > length) continue;
        memset(bytes + cursor, 0, 4);
        cursor += 4;
        bytes[cursor++] = 0x01;
        bytes[cursor++] = 0xFF;
        memset(bytes + cursor, 0, 4);
        cursor += 4;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = (uint8_t)((height >> 8) & 0xFF);
        bytes[cursor++] = (uint8_t)(height & 0xFF);
        bytes[cursor++] = (uint8_t)((width >> 8) & 0xFF);
        bytes[cursor++] = (uint8_t)(width & 0xFF);
        memset(bytes + cursor, 0, 4);
        cursor += 4;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = 0x01;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = (uint8_t)MAX(16, MIN(72, height / 20));
        bytes[cursor++] = 0xFF;
        bytes[cursor++] = 0xFF;
        bytes[cursor++] = 0xFF;
        bytes[cursor++] = 0xFF;
        patched++;
    }
    if (patched == 0) return NO;
    if (![data writeToURL:URL atomically:YES]) return NO;
    YTKACEDownloadLog(@"subs", @"patched %lu tx3g entries %dx%d",
                      (unsigned long)patched, width, height);
    return YES;
}

+ (void)muxSubtitlesIntoURL:(NSURL *)mediaURL
                       cues:(NSArray<NSDictionary *> *)cues
                   language:(NSString *)language
                  outputURL:(NSURL *)outputURL
                 completion:(YTKACEFFmpegCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        AVFormatContext *input = NULL;
        AVFormatContext *output = NULL;
        int *streamMap = NULL;
        AVPacket *packet = NULL;
        AVStream *text = NULL;
        NSError *failure = nil;
        int textIndex = -1;
        int status = 0;
        int videoWidth = 1280;
        int videoHeight = 720;
        long written = 0;

        do {
            status = avformat_open_input(
                &input, mediaURL.fileSystemRepresentation, NULL, NULL);
            if (status < 0) {
                failure = YTKACEFFmpegError(status, @"subtitle open");
                break;
            }
            status = avformat_find_stream_info(input, NULL);
            if (status < 0) {
                failure = YTKACEFFmpegError(status, @"subtitle probe");
                break;
            }
            status = avformat_alloc_output_context2(
                &output, NULL, "mp4", outputURL.fileSystemRepresentation);
            if (status < 0 || output == NULL) {
                failure = YTKACEFFmpegError(status, @"subtitle output");
                break;
            }
            streamMap = (int *)av_calloc(input->nb_streams, sizeof(int));
            if (streamMap == NULL) {
                failure = YTKACEFFmpegError(AVERROR(ENOMEM), @"subtitle map");
                break;
            }
            for (unsigned int index = 0; index < input->nb_streams; index++) {
                AVStream *source = input->streams[index];
                const enum YTKACEFFmpegMediaType type =
                    source->codecpar->codec_type;
                if (type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_AUDIO) {
                    streamMap[index] = -1;
                    continue;
                }
                AVStream *copy = avformat_new_stream(output, NULL);
                if (copy == NULL) {
                    failure = YTKACEFFmpegError(AVERROR(ENOMEM),
                                                @"subtitle stream");
                    break;
                }
                status = avcodec_parameters_copy(copy->codecpar,
                                                 source->codecpar);
                if (status < 0) {
                    failure = YTKACEFFmpegError(status, @"subtitle params");
                    break;
                }
                if (type == AVMEDIA_TYPE_VIDEO) {
                    if (source->codecpar->width > 0) {
                        videoWidth = source->codecpar->width;
                    }
                    if (source->codecpar->height > 0) {
                        videoHeight = source->codecpar->height;
                    }
                }
                copy->codecpar->codec_tag = 0;
                copy->time_base = source->time_base;
                streamMap[index] = (int)(output->nb_streams - 1);
            }
            if (failure != nil) break;

            text = avformat_new_stream(output, NULL);
            if (text == NULL) {
                failure = YTKACEFFmpegError(AVERROR(ENOMEM), @"subtitle track");
                break;
            }
            text->codecpar->codec_type = AVMEDIA_TYPE_SUBTITLE;
            text->codecpar->codec_id = AV_CODEC_ID_MOV_TEXT;
            text->time_base = (AVRational){1, 1000};
            text->disposition = AV_DISPOSITION_DEFAULT;
            uint8_t description[48];
            size_t cursor = 0;
            memset(description, 0, sizeof(description));
            cursor += 4;
            description[cursor++] = 0x01;
            description[cursor++] = 0xFF;
            cursor += 4;
            description[cursor++] = 0x00;
            description[cursor++] = 0x00;
            description[cursor++] = 0x00;
            description[cursor++] = 0x00;
            description[cursor++] = (uint8_t)((videoHeight >> 8) & 0xFF);
            description[cursor++] = (uint8_t)(videoHeight & 0xFF);
            description[cursor++] = (uint8_t)((videoWidth >> 8) & 0xFF);
            description[cursor++] = (uint8_t)(videoWidth & 0xFF);
            cursor += 4;
            description[cursor++] = 0x00;
            description[cursor++] = 0x01;
            description[cursor++] = 0x00;
            description[cursor++] = (uint8_t)MAX(16, MIN(72, videoHeight / 20));
            description[cursor++] = 0xFF;
            description[cursor++] = 0xFF;
            description[cursor++] = 0xFF;
            description[cursor++] = 0xFF;
            static const uint8_t fontTable[] = {
                0x00, 0x00, 0x00, 0x12, 0x66, 0x74, 0x61, 0x62,
                0x00, 0x01, 0x00, 0x01, 0x05, 0x53, 0x65, 0x72,
                0x69, 0x66
            };
            memcpy(description + cursor, fontTable, sizeof(fontTable));
            cursor += sizeof(fontTable);

            text->codecpar->extradata = (uint8_t *)av_mallocz(
                cursor + AV_INPUT_BUFFER_PADDING_SIZE);
            if (text->codecpar->extradata == NULL) {
                failure = YTKACEFFmpegError(AVERROR(ENOMEM),
                                            @"subtitle extradata");
                break;
            }
            memcpy(text->codecpar->extradata, description, cursor);
            text->codecpar->extradata_size = (int)cursor;
            text->codecpar->width = videoWidth;
            text->codecpar->height = videoHeight;
            YTKACEDownloadLog(@"subs", @"tx3g desc %zu bytes box=%dx%d",
                              cursor, videoWidth, videoHeight);
            NSString *mp4Language = YTKACEMP4LanguageCode(language);
            if (mp4Language.length != 0) {
                av_dict_set(&text->metadata, "language", mp4Language.UTF8String, 0);
            }
            textIndex = (int)(output->nb_streams - 1);

            if (!(output->oformat->flags & AVFMT_NOFILE)) {
                status = avio_open(&output->pb,
                                   outputURL.fileSystemRepresentation,
                                   AVIO_FLAG_WRITE);
                if (status < 0) {
                    failure = YTKACEFFmpegError(status, @"subtitle avio");
                    break;
                }
            }
            AVDictionary *options = NULL;
            av_dict_set(&options, "movflags", "+faststart", 0);
            av_dict_set(&options, "use_editlist", "0", 0);
            status = avformat_write_header(output, &options);
            av_dict_free(&options);
            if (status < 0) {
                failure = YTKACEFFmpegError(status, @"subtitle header");
                break;
            }

            double maxMediaDurationSec = 0.0;
            if (input->duration > 0 && input->duration != AV_NOPTS_VALUE) {
                maxMediaDurationSec = (double)input->duration / (double)AV_TIME_BASE;
            }
            for (unsigned int i = 0; i < input->nb_streams; i++) {
                AVStream *st = input->streams[i];
                if (st->duration > 0 && st->duration != AV_NOPTS_VALUE) {
                    double dur = (double)st->duration * av_q2d(st->time_base);
                    if (dur > maxMediaDurationSec) maxMediaDurationSec = dur;
                }
            }

            packet = av_packet_alloc();
            if (packet == NULL) {
                failure = YTKACEFFmpegError(AVERROR(ENOMEM), @"subtitle packet");
                break;
            }
            while (av_read_frame(input, packet) >= 0) {
                const int mapped = streamMap[packet->stream_index];
                if (mapped < 0) {
                    av_packet_unref(packet);
                    continue;
                }
                AVStream *source = input->streams[packet->stream_index];
                AVStream *destination = output->streams[mapped];
                av_packet_rescale_ts(packet, source->time_base,
                                     destination->time_base);
                packet->stream_index = mapped;
                packet->pos = -1;
                if (av_interleaved_write_frame(output, packet) < 0) {
                    av_packet_unref(packet);
                    break;
                }
                av_packet_unref(packet);
            }

            for (NSDictionary *cue in YTKACENormalizedCues(cues)) {
                NSString *value = cue[@"text"];
                if (![value isKindOfClass:NSString.class] || value.length == 0) {
                    continue;
                }
                NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
                if (utf8.length == 0 || utf8.length > 0xFFFF) continue;
                double start = [cue[@"start"] doubleValue];
                double end = [cue[@"end"] doubleValue];
                if (maxMediaDurationSec > 0.0) {
                    if (start >= maxMediaDurationSec) continue;
                    if (end > maxMediaDurationSec) end = maxMediaDurationSec;
                }
                if (end <= start) continue;
                if (av_new_packet(packet, (int)utf8.length + 2) < 0) continue;
                packet->data[0] = (uint8_t)((utf8.length >> 8) & 0xFF);
                packet->data[1] = (uint8_t)(utf8.length & 0xFF);
                memcpy(packet->data + 2, utf8.bytes, utf8.length);
                packet->stream_index = textIndex;
                packet->pts = (int64_t)(start * 1000.0);
                packet->dts = packet->pts;
                packet->duration = (int64_t)((end - start) * 1000.0);
                packet->pos = -1;
                const int rc = av_interleaved_write_frame(output, packet);
                if (rc < 0) {
                    YTKACEDownloadLog(@"subs", @"cue write failed: %@",
                                      YTKACEFFmpegMessage(rc));
                    av_packet_unref(packet);
                    break;
                }
                written++;
                av_packet_unref(packet);
            }

            status = av_write_trailer(output);
            if (status < 0) {
                failure = YTKACEFFmpegError(status, @"subtitle trailer");
            }
        } while (0);

        if (packet != NULL) av_packet_free(&packet);
        if (streamMap != NULL) av_free(streamMap);
        if (input != NULL) avformat_close_input(&input);
        if (output != NULL) {
            if (output->pb != NULL && !(output->oformat->flags & AVFMT_NOFILE)) {
                avio_closep(&output->pb);
            }
            avformat_free_context(output);
        }
        if (failure != nil) {
            [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
            YTKACEDownloadLog(@"subs", @"mux failed: %@",
                              failure.localizedDescription);
        } else {
            YTKACEDownloadLog(@"subs", @"muxed %ld/%lu cues written",
                              (long)written, (unsigned long)cues.count);
            if (!YTKACEPatchTextSampleDescription(outputURL, videoWidth,
                                                  videoHeight)) {
                YTKACEDownloadLog(@"subs", @"tx3g patch skipped");
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(failure); });
    });
}

+ (void)embedArtworkData:(NSData *)artworkData
                 mediaURL:(NSURL *)mediaURL
               completion:(YTKACEFFmpegCompletion)completion {
    if (artworkData.length == 0 || mediaURL == nil) {
        completion(YTKACEFFmpegError(AVERROR(EINVAL), @"Read artwork"));
        return;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mediaURL options:nil];
    AVAssetExportSession *exporter = [[AVAssetExportSession alloc]
        initWithAsset:asset presetName:AVAssetExportPresetPassthrough];
    if (exporter == nil) {
        completion(YTKACEFFmpegError(AVERROR_UNKNOWN, @"Create artwork export"));
        return;
    }
    NSString *extension = mediaURL.pathExtension.lowercaseString;
    AVFileType outputType = [extension isEqualToString:@"m4a"]
        ? AVFileTypeAppleM4A : AVFileTypeMPEG4;
    if (![exporter.supportedFileTypes containsObject:outputType]) {
        completion(YTKACEFFmpegError(AVERROR(ENOTSUP), @"Embed artwork"));
        return;
    }
    NSURL *temporary = [mediaURL.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:[NSString stringWithFormat:@".%@-artwork.%@",
            NSUUID.UUID.UUIDString, extension.length == 0 ? @"mp4" : extension]];
    [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    AVMutableMetadataItem *artwork = [AVMutableMetadataItem metadataItem];
    artwork.identifier = AVMetadataCommonIdentifierArtwork;
    artwork.value = artworkData;
    artwork.dataType = @"com.apple.metadata.datatype.JPEG";
    NSMutableArray<AVMetadataItem *> *metadata = [asset.commonMetadata mutableCopy] ?:
        [NSMutableArray array];
    [metadata addObject:artwork];
    exporter.metadata = metadata;
    exporter.outputURL = temporary;
    exporter.outputFileType = outputType;
    exporter.shouldOptimizeForNetworkUse = YES;
    [exporter exportAsynchronouslyWithCompletionHandler:^{
        NSError *error = exporter.error;
        if (exporter.status == AVAssetExportSessionStatusCompleted) {
            NSFileManager *manager = NSFileManager.defaultManager;
            copyfile(mediaURL.fileSystemRepresentation, temporary.fileSystemRepresentation,
                     NULL, COPYFILE_XATTR);
            NSURL *backup = [mediaURL.URLByDeletingLastPathComponent
                URLByAppendingPathComponent:[@"." stringByAppendingString:
                    NSUUID.UUID.UUIDString]];
            if (![manager moveItemAtURL:mediaURL toURL:backup error:&error] ||
                ![manager moveItemAtURL:temporary toURL:mediaURL error:&error]) {
                if (![manager fileExistsAtPath:mediaURL.path]) {
                    [manager moveItemAtURL:backup toURL:mediaURL error:nil];
                }
            } else {
                [manager removeItemAtURL:backup error:nil];
            }
        }
        [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    }];
}


+ (void)videoFromAudioURL:(NSURL *)audioURL
             artworkData:(NSData *)artworkData
                outputURL:(NSURL *)outputURL
                 progress:(YTKACEFFmpegProgress)progress
               completion:(YTKACEFFmpegCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        NSError *error = YTKACEAudioToVideo(audioURL, artworkData, outputURL,
                                            progress);
        YTKACEDownloadLog(@"convert", @"audio video elapsed=%.1fs error=%@",
            CFAbsoluteTimeGetCurrent() - started,
            error.localizedDescription ?: @"none");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}


@end
