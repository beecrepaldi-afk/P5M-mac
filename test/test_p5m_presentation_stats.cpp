#include "macPresentationStats.h"

#include <cassert>
#include <cmath>
#include <limits>

using p5m::display::PresentationStats;

static bool near(double a, double b) { return std::abs(a - b) < 1e-9; }

int main()
{
    constexpr double period = 1.0 / 60.0;
    {
        // 60 Hz uniforme; zerar a janela preserva a base entre relatórios.
        PresentationStats stats;
        for(unsigned i = 0; i < 61; ++i)
            stats.record(i, 1.0 + i * period, period, true);
        auto snapshot = stats.takeSnapshot();
        assert(snapshot.uniqueFrames == 61 && snapshot.intervalCount == 60);
        assert(snapshot.intervalBuckets[1] == 60);
        assert(near(snapshot.meanIntervalSeconds, period));
        assert(near(snapshot.maxIntervalSeconds, period));
        stats.record(61, 1.0 + 61 * period, period, true);
        snapshot = stats.takeSnapshot();
        assert(snapshot.uniqueFrames == 1 && snapshot.intervalCount == 1);
        assert(snapshot.intervalBuckets[1] == 1);
        assert(near(snapshot.meanIntervalSeconds, period));
        snapshot = stats.takeSnapshot();
        assert(snapshot.uniqueFrames == 0 && snapshot.intervalCount == 0);
        assert(snapshot.meanIntervalSeconds == 0.0 && snapshot.maxIntervalSeconds == 0.0);
    }
    {
        // Quadros a 16,7/33,3/50 ms ficam nos baldes de um/dois/três períodos.
        PresentationStats stats;
        stats.record(1, 1.0, period, true);
        stats.record(2, 1.0 + period, period, true);
        stats.record(3, 1.0 + 3 * period, period, true);
        stats.record(4, 1.0 + 6 * period, period, true);
        const auto snapshot = stats.takeSnapshot();
        assert(snapshot.intervalCount == 3);
        assert(snapshot.intervalBuckets[1] == 1 && snapshot.intervalBuckets[2] == 1);
        assert(snapshot.intervalBuckets[3] == 1);
        assert(near(snapshot.meanIntervalSeconds, 2 * period));
        assert(near(snapshot.maxIntervalSeconds, 3 * period));
    }
    {
        // Repintar a interface não mascara o atraso entre quadros de vídeo.
        PresentationStats stats;
        stats.record(10, 1.0, period, true);
        stats.record(10, 1.0 + period, period, true);
        stats.record(10, 1.0 + 2 * period, period, true);
        stats.record(11, 1.0 + 3 * period, period, true);
        const auto initial = stats.takeSnapshot();
        assert(initial.uniqueFrames == 2 && initial.repeatedCallbacks == 2);
        assert(initial.intervalCount == 1 && initial.intervalBuckets[3] == 1);
        stats.record(11, 1.0 + 4 * period, period, true);
        stats.record(12, 1.0 + 6 * period, period, true);
        const auto snapshot = stats.takeSnapshot();
        assert(snapshot.uniqueFrames == 1 && snapshot.repeatedCallbacks == 1);
        assert(snapshot.intervalCount == 1 && snapshot.intervalBuckets[3] == 1);
        assert(near(snapshot.meanIntervalSeconds, 3 * period));
    }
    {
        // Callbacks atrasados, por ID ou tempo, não substituem a base válida.
        PresentationStats stats;
        stats.record(10, 1.0, period, true);
        stats.record(9, 1.0 + period, period, true);
        stats.record(12, 1.0 - period, period, true);
        stats.record(11, 1.0 + 2 * period, period, true);
        const auto snapshot = stats.takeSnapshot();
        assert(snapshot.uniqueFrames == 2 && snapshot.outOfOrderCallbacks == 2);
        assert(snapshot.intervalCount == 1 && snapshot.intervalBuckets[2] == 1);
        assert(near(snapshot.meanIntervalSeconds, 2 * period));
    }
    {
        // Retomar após segundos em background não vira travada no relatório.
        PresentationStats stats;
        stats.record(0, 1.0, period, true);
        stats.interrupt();
        stats.record(0, 20.0, period, true);
        stats.record(1, 20.0 + period, period, true);
        stats.record(2, 20.0 + 2 * period, period, true);
        stats.record(3, 0.0, period, true);
        stats.record(3, 40.0, period, true);
        stats.record(4, 40.0 + period, period, true);
        const auto snapshot = stats.takeSnapshot();
        assert(snapshot.uniqueFrames == 5 && snapshot.repeatedCallbacks == 1);
        assert(snapshot.intervalCount == 2 && snapshot.intervalBuckets[1] == 2);
        assert(near(snapshot.maxIntervalSeconds, period));
    }
    {
        // VRR mantém média/máximo sem impor baldes de um painel fixo.
        PresentationStats stats;
        stats.record(1, 1.0, period, false);
        stats.record(2, 1.010, period, false);
        stats.record(3, 1.035, period, false);
        const auto snapshot = stats.takeSnapshot();
        assert(snapshot.uniqueFrames == 3 && snapshot.intervalCount == 2);
        assert(near(snapshot.meanIntervalSeconds, 0.0175));
        assert(near(snapshot.maxIntervalSeconds, 0.025));
        for(auto count : snapshot.intervalBuckets) assert(count == 0);
    }
    {
        // Extremos dos baldes e entradas inválidas não contaminam as medidas.
        PresentationStats stats;
        stats.record(1, 1.0, 1.0, true);
        stats.record(2, 1.5, 1.0, true);
        stats.record(3, 2.25, 1.0, true);
        stats.record(4, 3.75, 1.0, true);
        stats.record(5, 6.25, 1.0, true);
        stats.record(6, 9.75, 1.0, true);
        auto snapshot = stats.takeSnapshot();
        for(auto count : snapshot.intervalBuckets) assert(count == 1);
        const double nan = std::numeric_limits<double>::quiet_NaN();
        stats.record(7, nan, period, true);
        stats.record(7, 50.0, period, true);
        stats.record(8, 50.0 + period, nan, true);
        snapshot = stats.takeSnapshot();
        assert(snapshot.uniqueFrames == 2 && snapshot.intervalCount == 1);
        assert(near(snapshot.meanIntervalSeconds, period));
        for(auto count : snapshot.intervalBuckets) assert(count == 0);
    }
}
