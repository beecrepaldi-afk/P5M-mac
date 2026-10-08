#include "macAudioOutput.h"
#include <cassert>
#include <string>

// Nenhum destes caminhos consulta hardware: validam os argumentos antes da enumeração.
int main() {
    MacAudioOutput output;
    std::string error;
    assert(!output.isReady()); assert(!output.needsReopen()); assert(output.queuedBytes()==0);
    assert(!output.open(48000,6,"",true,false,20,error));
    assert(error.find("verified channel order")!=std::string::npos);
    assert(!output.open(48000,8,"",true,true,20,error));
    assert(error.find("verified channel order")!=std::string::npos);
    assert(!output.open(48000,6,"",true,false,20,error,MacAudioLayout::Wave71));
    assert(error.find("verified channel order")!=std::string::npos);
    assert(!output.open(48000,8,"",true,false,20,error,MacAudioLayout::Wave51));
    assert(error.find("verified channel order")!=std::string::npos);
    assert(!output.open(1,2,"",true,false,20,error));
    assert(error.find("sample rate")!=std::string::npos);
    assert(!output.open(48000,3,"",true,false,20,error));
    assert(error.find("channel count")!=std::string::npos);
    assert(!output.open(48000,0,"",false,false,20,error));
    assert(!output.open(999999,2,"",false,false,20,error));
    output.clear(); output.setTargetMs(20); output.close();
    assert(!output.isReady()); assert(output.underruns()==0); assert(output.latencyMs()==0);
    int16_t sample=0; assert(!output.queue(&sample,1));
}
