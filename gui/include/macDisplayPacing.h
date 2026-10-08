#pragma once

#include <algorithm>
#include <cmath>

namespace p5m::display {

struct PacingPolicy {
    bool variableRefresh = false;
    bool useDisplayLink = false;
    double minimumFramesPerSecond = 60.0;
    double maximumFramesPerSecond = 60.0;
    double preferredFramesPerSecond = 60.0;
};

// A taxa máxima sozinha não distingue ProMotion/VRR de um painel fixo.
// Os intervalos vêm da tela atual, sem depender de seu nome ou modelo.
inline PacingPolicy decidePacing(double minimumRefreshInterval,
                                double maximumRefreshInterval,
                                double maximumFramesPerSecond,
                                double sourceFramesPerSecond = 60.0,
                                bool vsyncEnabled = true,
                                int displayLinkOverride = -1)
{
    const auto validRate = [](double rate) {
        return std::isfinite(rate) && rate >= 1.0 && rate <= 1000.0;
    };
    const bool validMaximum = validRate(maximumFramesPerSecond);
    const double fallbackRate = validMaximum ? maximumFramesPerSecond : 60.0;
    PacingPolicy result;
    result.minimumFramesPerSecond = fallbackRate;
    result.maximumFramesPerSecond = fallbackRate;
    result.preferredFramesPerSecond = fallbackRate;

    const bool validIntervals = std::isfinite(minimumRefreshInterval) &&
        std::isfinite(maximumRefreshInterval) && minimumRefreshInterval > 0.0 &&
        maximumRefreshInterval >= minimumRefreshInterval &&
        validRate(1.0 / minimumRefreshInterval) &&
        validRate(1.0 / maximumRefreshInterval);
    if(validIntervals)
    {
        const double minimumRate = 1.0 / maximumRefreshInterval;
        const double maximumRate = validMaximum ?
            std::min(1.0 / minimumRefreshInterval, maximumFramesPerSecond) :
            1.0 / minimumRefreshInterval;
        if(minimumRate <= maximumRate)
        {
            result.minimumFramesPerSecond = minimumRate;
            result.maximumFramesPerSecond = maximumRate;
            // Arredondamento dos intervalos não transforma uma tela fixa em VRR.
            result.variableRefresh = maximumRate - minimumRate > maximumRate * 0.0001;
            if(result.variableRefresh)
            {
                const double sourceRate = validRate(sourceFramesPerSecond) ?
                    sourceFramesPerSecond : 60.0;
                result.preferredFramesPerSecond = std::clamp(sourceRate, minimumRate, maximumRate);
            }
            else
            {
                result.minimumFramesPerSecond = maximumRate;
                result.preferredFramesPerSecond = maximumRate;
            }
        }
    }

    // O override manual é preservado; automático respeita a escolha de VSync.
    result.useDisplayLink = displayLinkOverride == 1 ||
        (displayLinkOverride != 0 && vsyncEnabled && result.variableRefresh);
    return result;
}

} // namespace p5m::display
