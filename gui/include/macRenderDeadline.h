#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>

namespace p5m::display {
// Tempo encode→GPU pronta, incluindo a fila. Sem alocação; chamador sincroniza.
class RenderBudget {
    std::array<double, 64> samples{};
    std::size_t count = 0, cursor = 0;
public:
    void reset() { count = cursor = 0; }
    void record(double seconds) {
        if(!std::isfinite(seconds) || seconds <= 0.0 || seconds > 1.0) return;
        samples[cursor] = seconds;
        cursor = (cursor + 1) % samples.size();
        count = std::min(count + 1, samples.size());
    }
    double seconds() const {
        // Conservador no aquecimento; não extrapola o período da tela.
        if(count < 8) return 0.0135;
        auto ordered = samples;
        std::sort(ordered.begin(), ordered.begin() + count);
        const auto index = static_cast<std::size_t>(std::ceil(count * 0.95)) - 1;
        return std::max(0.001, ordered[index]);
    }
};
// Espera só a folga disponível: preserva p95 de encode/fila/GPU + margem de 1,5 ms,
// limitada a meia atualização. Atraso ou GPU acima do orçamento = não esperar.
inline double lateLatchWait(double now, double renderTarget, double period, double gpuBudget) {
    if(!std::isfinite(now) || !std::isfinite(renderTarget) || !std::isfinite(period) ||
       !std::isfinite(gpuBudget) || period <= 0.0 || period > 1.0 || gpuBudget <= 0.0)
        return 0.0;
    const double remaining = renderTarget - now;
    if(remaining <= 0.0 || remaining > period * 2.0) return 0.0;
    return std::clamp(remaining - gpuBudget - 0.0015, 0.0, period * 0.5);
}
inline bool useLinkForFrame(bool variable, bool vsync, int overrideMode,
                            bool deadlineEnabled, bool hasVideo) {
    return overrideMode == 1 || (overrideMode != 0 && vsync &&
        (variable || (deadlineEnabled && hasVideo)));
}
} // namespace p5m::display
