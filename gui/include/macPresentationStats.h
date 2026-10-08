#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace p5m::display {

struct PresentationSnapshot {
    std::uint64_t uniqueFrames = 0;
    std::uint64_t repeatedCallbacks = 0;
    std::uint64_t outOfOrderCallbacks = 0;
    std::uint64_t intervalCount = 0;
    double meanIntervalSeconds = 0.0;
    double maxIntervalSeconds = 0.0;
    // <0,75T; [0,75T,1,5T); [1,5T,2,5T); [2,5T,3,5T); >=3,5T.
    std::array<std::uint64_t, 5> intervalBuckets{};
};

// Mede somente apresentações confirmadas. O chamador serializa o acesso;
// callbacks da interface repetindo o quadro não representam vídeo novo.
class PresentationStats {
public:
    void record(std::uint64_t frameId, double timestampSeconds,
                double refreshPeriodSeconds, bool fixedRefresh)
    {
        if(!std::isfinite(timestampSeconds) || timestampSeconds <= 0.0)
        {
            interrupt();
            return;
        }
        if(hasFrame_ && frameId < lastFrameId_)
        {
            ++window_.outOfOrderCallbacks;
            return;
        }
        if(hasFrame_ && frameId == lastFrameId_)
        {
            ++window_.repeatedCallbacks;
            return;
        }
        if(hasTimestamp_ && timestampSeconds <= lastTimestampSeconds_)
        {
            ++window_.outOfOrderCallbacks;
            return;
        }

        ++window_.uniqueFrames;
        if(hasTimestamp_)
        {
            const double interval = timestampSeconds - lastTimestampSeconds_;
            ++window_.intervalCount;
            intervalSumSeconds_ += interval;
            window_.maxIntervalSeconds = std::max(window_.maxIntervalSeconds, interval);
            if(fixedRefresh && std::isfinite(refreshPeriodSeconds) && refreshPeriodSeconds > 0.0)
            {
                const double periods = interval / refreshPeriodSeconds;
                const unsigned bucket = periods < 0.75 ? 0 : periods < 1.5 ? 1 :
                    periods < 2.5 ? 2 : periods < 3.5 ? 3 : 4;
                ++window_.intervalBuckets[bucket];
            }
        }
        lastFrameId_ = frameId;
        lastTimestampSeconds_ = timestampSeconds;
        hasFrame_ = true;
        hasTimestamp_ = true;
    }

    // Sem vídeo ou após pausa, a primeira apresentação cria uma nova base.
    // O último ID permanece para uma repintura não virar quadro novo.
    void interrupt() { hasTimestamp_ = false; }

    PresentationSnapshot takeSnapshot()
    {
        auto result = window_;
        if(result.intervalCount)
            result.meanIntervalSeconds = intervalSumSeconds_ / result.intervalCount;
        window_ = {};
        intervalSumSeconds_ = 0.0;
        return result;
    }

private:
    PresentationSnapshot window_;
    double intervalSumSeconds_ = 0.0;
    double lastTimestampSeconds_ = 0.0;
    std::uint64_t lastFrameId_ = 0;
    bool hasFrame_ = false;
    bool hasTimestamp_ = false;
};

} // namespace p5m::display
