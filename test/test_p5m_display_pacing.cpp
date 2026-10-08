#include "macDisplayPacing.h"
#include <cassert>
#include <cmath>
#include <limits>

using p5m::display::decidePacing;

static bool near(double a, double b) { return std::abs(a - b) < 0.000001; }

int main()
{
    // A janela passa do Air fixo a um monitor VRR e volta a um monitor fixo.
    const auto air = decidePacing(1.0/60.0, 1.0/60.0, 60.0);
    assert(!air.variableRefresh && !air.useDisplayLink);
    assert(near(air.minimumFramesPerSecond, 60.0));
    assert(near(air.maximumFramesPerSecond, 60.0));
    assert(near(air.preferredFramesPerSecond, 60.0));
    const auto vrr = decidePacing(1.0/120.0, 1.0/40.0, 120.0);
    assert(vrr.variableRefresh && vrr.useDisplayLink);
    assert(near(vrr.minimumFramesPerSecond, 40.0));
    assert(near(vrr.maximumFramesPerSecond, 120.0));
    assert(near(vrr.preferredFramesPerSecond, 60.0));
    const auto fixed144 = decidePacing(1.0/144.0, 1.0/144.0, 144.0);
    assert(!fixed144.variableRefresh && !fixed144.useDisplayLink);
    assert(near(fixed144.preferredFramesPerSecond, 144.0));

    // 120 Hz sem intervalos não é prova de atualização variável.
    const auto missing = decidePacing(0.0, 0.0, 120.0);
    assert(!missing.variableRefresh && !missing.useDisplayLink);
    assert(near(missing.maximumFramesPerSecond, 120.0));
    const auto roundedFixed = decidePacing(1.0/60.000001, 1.0/60.0, 60.000001);
    assert(!roundedFixed.variableRefresh && !roundedFixed.useDisplayLink);

    // A preferência acompanha a fonte sem ultrapassar os limites da tela.
    assert(near(decidePacing(1.0/120.0, 1.0/40.0, 120.0, 30.0).preferredFramesPerSecond, 40.0));
    assert(near(decidePacing(1.0/120.0, 1.0/40.0, 120.0, 240.0).preferredFramesPerSecond, 120.0));
    const auto capped = decidePacing(1.0/120.0, 1.0/40.0, 90.0, 120.0);
    assert(near(capped.maximumFramesPerSecond, 90.0));
    assert(near(capped.preferredFramesPerSecond, 90.0));

    assert(!decidePacing(1.0/120.0, 1.0/40.0, 120.0, 60.0, false).useDisplayLink);
    assert(!decidePacing(1.0/120.0, 1.0/40.0, 120.0, 60.0, true, 0).useDisplayLink);
    assert(decidePacing(1.0/60.0, 1.0/60.0, 60.0, 60.0, false, 1).useDisplayLink);

    // Dados inválidos são tratados sem NaN, ranges invertidos ou divisão por zero.
    const double nan = std::numeric_limits<double>::quiet_NaN();
    const double inf = std::numeric_limits<double>::infinity();
    for(double invalid : {nan, inf, -1.0, 0.0})
    {
        const auto invalidSpec = decidePacing(invalid, invalid, invalid);
        assert(!invalidSpec.variableRefresh && !invalidSpec.useDisplayLink);
        assert(near(invalidSpec.preferredFramesPerSecond, 60.0));
        assert(decidePacing(invalid, invalid, invalid, invalid, false, 1).useDisplayLink);
        const auto invalidSource = decidePacing(1.0/120.0, 1.0/40.0, 120.0, invalid);
        assert(near(invalidSource.preferredFramesPerSecond, 60.0));
    }
    const auto inverted = decidePacing(1.0/40.0, 1.0/120.0, 120.0);
    assert(!inverted.variableRefresh && !inverted.useDisplayLink);
    const auto impossibleCap = decidePacing(1.0/120.0, 1.0/40.0, 30.0);
    assert(!impossibleCap.variableRefresh && !impossibleCap.useDisplayLink);
    assert(near(impossibleCap.minimumFramesPerSecond, 30.0));
    const auto noMaximum = decidePacing(1.0/120.0, 1.0/40.0, 0.0);
    assert(noMaximum.variableRefresh && noMaximum.useDisplayLink);
    assert(near(noMaximum.maximumFramesPerSecond, 120.0));
}
