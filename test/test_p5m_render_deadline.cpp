#include "macRenderDeadline.h"
#include <cassert>
#include <cmath>
#include <limits>
using namespace p5m::display;
int main() {
    RenderBudget budget;
    assert(std::abs(budget.seconds() - .0135) < 1e-9);
    for(int i=0; i<64; ++i) budget.record(.008);
    budget.record(.1); // Um outlier não deve paralisar a espera indefinidamente.
    assert(std::abs(budget.seconds() - .008) < 1e-9);
    for(int i=0; i<4; ++i) budget.record(.025);
    assert(budget.seconds() == .025);
    assert(lateLatchWait(1,1+.016,1./60,budget.seconds()) == 0);
    budget.reset();
    assert(std::abs(budget.seconds() - .0135) < 1e-9);
    assert(std::abs(lateLatchWait(1,1+.016,1./60,.008) - .0065) < 1e-9);
    assert(lateLatchWait(1,1+.03,1./60,.001) <= 1./120);
    assert(lateLatchWait(1,.99,1./60,.008) == 0);
    assert(lateLatchWait(1,2,1./60,.008) == 0);
    assert(lateLatchWait(1,1.016,0,.008) == 0);
    assert(lateLatchWait(1,1.016,1./60,std::numeric_limits<double>::quiet_NaN()) == 0);
    // Perfil validado: fila no painel fixo, link sem espera adicional no VRR.
    assert(!useLinkForFrame(false,true,-1,false,true));
    assert(!useLinkForFrame(false,false,-1,false,true));
    assert(useLinkForFrame(true,true,-1,false,true));
    assert(useLinkForFrame(false,true,-1,true,true));
    assert(!useLinkForFrame(false,true,-1,true,false)); // Menu não cria link.
    assert(!useLinkForFrame(false,false,-1,true,true));
    assert(!useLinkForFrame(false,true,0,true,true));
    assert(useLinkForFrame(false,false,1,true,true));
    assert(useLinkForFrame(true,true,-1,false,true));
}
