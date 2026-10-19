#pragma once

#include <algorithm>
#include <cmath>
#include <initializer_list>

// Media-time policy shared by the AVPlayer preview and the portable tests.
// A seek must finish before its destination can drive the next transition.
class YTKACESponsorPreview {
public:
    enum class Phase { Idle, SeekingLeadIn, BeforeSegment, SeekingCut, AfterSegment, Muting };
    enum class Action { None, SeekToEnd, Mute, Unmute, Finish };

    bool begin(double start, double end, double duration, bool mute) {
        cancel();
        if (!std::isfinite(start) || !std::isfinite(end) ||
            !std::isfinite(duration) || start < 0.0 || end <= start) return false;
        if (duration > 0.0) {
            start = std::min(start, duration);
            end = std::min(end, duration);
        }
        if (end <= start) return false;
        start_ = start;
        end_ = end;
        leadIn_ = std::max(0.0, start - 3.0);
        targetEnd_ = duration > 0.0 ? std::min(duration, end + 2.5) : end + 2.5;
        mute_ = mute;
        phase_ = Phase::SeekingLeadIn;
        return true;
    }

    Action seekCompleted(bool finished) {
        if (!finished) {
            cancel();
            return Action::None;
        }
        if (phase_ == Phase::SeekingLeadIn) phase_ = Phase::BeforeSegment;
        else if (phase_ == Phase::SeekingCut) {
            phase_ = Phase::AfterSegment;
            // There is no lead-out when the segment ends at the end of the video.
            if (targetEnd_ <= end_) return finish();
        }
        return Action::None;
    }

    Action advance(double time) {
        if (!std::isfinite(time) || time < 0.0) return Action::None;
        if (phase_ == Phase::BeforeSegment && time >= start_) {
            if (mute_) {
                phase_ = Phase::Muting;
                return Action::Mute;
            }
            phase_ = Phase::SeekingCut;
            return Action::SeekToEnd;
        }
        if (phase_ == Phase::Muting && time >= end_) {
            phase_ = Phase::AfterSegment;
            return Action::Unmute;
        }
        if (phase_ == Phase::AfterSegment && time >= targetEnd_) return finish();
        return Action::None;
    }

    void cancel() { phase_ = Phase::Idle; }
    bool active() const { return phase_ != Phase::Idle; }
    Phase phase() const { return phase_; }
    double leadIn() const { return leadIn_; }
    double start() const { return start_; }
    double end() const { return end_; }
    double targetEnd() const { return targetEnd_; }

private:
    Action finish() { cancel(); return Action::Finish; }
    Phase phase_ = Phase::Idle;
    double start_ = 0.0, end_ = 0.0, leadIn_ = 0.0, targetEnd_ = 0.0;
    bool mute_ = false;
};
