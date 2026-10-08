#include "macAudioRing.h"
#include <cassert>
#include <cmath>
#include <thread>
#include <array>

int main() {
    MacAudioRing ring;
    ring.reset(8,2);
    const int16_t samples[]={32767,-32768,16384,-16384,8192,-8192,0,0};
    assert(ring.push(samples,4)); assert(ring.queued()==4);
    float left[8]{},right[8]{}; float *planes[]={left,right};
    assert(ring.pop(planes,2)==2);
    assert(left[0]==32767/32768.f&&right[0]==-1.f);
    assert(left[1]==0.5f&&right[1]==-0.5f);
    assert(ring.pop(planes,4)==2); assert(left[0]==0.25f&&right[0]==-0.25f);
    assert(left[2]==0&&right[3]==0);
    // Wrap-around, clear e overflow não alteram as amostras publicadas.
    assert(ring.push(samples,4)); ring.clear(); assert(ring.queued()==0);
    assert(ring.pop(planes,2)==0); assert(ring.push(samples,4));
    assert(!ring.push(samples,9)); assert(ring.queued()==4);
    assert(ring.pop(planes,4)==4); assert(left[0]==32767/32768.f);
    ring.reset(8,2); ring.setTarget(2); assert(ring.push(samples,4));
    assert(ring.pop(planes,2)==2); assert(left[0]==32767/32768.f); // pacote normal acima do alvo não é cortado
    ring.reset(1024,1); ring.setTarget(1024);
    std::thread producer([&] {
        for(int i=0;i<100000;i++) { int16_t n=i%30000; while(!ring.push(&n,1)) std::this_thread::yield(); }
    });
    float output; float *mono[]={&output};
    for(int i=0;i<100000;i++) {
        while(!ring.pop(mono,1)) std::this_thread::yield();
        assert(output==float(i%30000)/32768.f);
    }
    producer.join(); assert(ring.queued()==0);
    // Alvo adaptativo gera reserva real; silêncio de priming não é underrun.
    ring.enablePriming(true); ring.reset(8,1); ring.setTarget(4);
    int16_t refill[4]={8192,8192,8192,8192};
    assert(ring.push(refill,2)); assert(ring.pop(mono,1)==0); assert(output==0); assert(ring.underruns()==0);
    assert(ring.push(refill,2)); assert(ring.pop(mono,1)==1); assert(output==0.25f);
    for(int i=0;i<3;i++) assert(ring.pop(mono,1)==1);
    assert(ring.pop(mono,1)==0); assert(ring.underruns()==1);
    assert(ring.pop(mono,1)==0); assert(ring.underruns()==1);
    ring.setTarget(6); assert(ring.push(refill,4)); assert(ring.pop(mono,1)==0);
    assert(ring.push(refill,2)); assert(ring.pop(mono,1)==1);
    ring.clear(); assert(ring.pop(mono,1)==0); assert(ring.underruns()==1);
    ring.enablePriming(false);
    // Folga tolera pacotes normais e mudanças de alvo, preservando sequência.
    ring.reset(32,1); ring.setTarget(4); ring.setTrimSlack(4);
    int16_t ramp[16]; for(int i=0;i<16;i++) ramp[i]=int16_t(1000+i*100);
    assert(ring.push(ramp,5)); assert(ring.pop(mono,1)==1);
    assert(output==1000/32768.f&&ring.trimmedFrames()==0);
    assert(ring.pop(mono,1)==1); assert(output==1100/32768.f);
    ring.setTarget(2); assert(ring.pop(mono,1)==1);
    assert(output==1200/32768.f&&ring.trimmedFrames()==0);
    ring.clear(); ring.pop(mono,1);
    // Corte excepcional mistura as duas posições com coeficientes idênticos.
    ring.reset(32,2); ring.setTarget(4); ring.setTrimSlack(4); ring.setFadeFrames(4);
    int16_t stereo[32]; for(int i=0;i<16;i++) { stereo[2*i]=int16_t(1000+i*100); stereo[2*i+1]=-stereo[2*i]; }
    assert(ring.push(stereo,4)); assert(ring.pop(planes,4)==4); // fade inicial
    assert(left[0]==1000/32768.f*0.25f&&left[3]==1300/32768.f);
    assert(ring.push(stereo,16)); assert(ring.pop(planes,4)==4);
    assert(ring.trimmedFrames()==12);
    for(int i=0;i<4;i++) {
        float t=float(i+1)/4;
        float expected=(float(stereo[2*i])+(float(stereo[2*(i+12)])-stereo[2*i])*t)/32768.f;
        assert(std::fabs(left[i]-expected)<1e-7f&&right[i]==-left[i]);
    }
    // Crossfade atravessa callbacks menores que 1 ms sem ler slots liberados.
    ring.reset(32,2); ring.setTarget(4); ring.setTrimSlack(4); ring.setFadeFrames(4);
    assert(ring.push(stereo,4)); assert(ring.pop(planes,4)==4);
    assert(ring.push(stereo,16)); assert(ring.pop(planes,2)==2);
    assert(ring.pop(planes,2)==2);
    for(int i=0;i<2;i++) {
        int f=i+2; float t=float(f+1)/4;
        float expected=(float(stereo[2*f])+(float(stereo[2*(f+12)])-stereo[2*f])*t)/32768.f;
        assert(std::fabs(left[i]-expected)<1e-7f&&right[i]==-left[i]);
    }
    // Dry parcial termina em zero; refill começa suave e só conta um evento.
    ring.enablePriming(true); ring.reset(32,2); ring.setTarget(4); ring.setTrimSlack(4); ring.setFadeFrames(4);
    assert(ring.push(stereo,4)); assert(ring.pop(planes,3)==3);
    assert(ring.pop(planes,3)==1); assert(left[0]==0&&right[0]==0);
    assert(ring.underruns()==1&&ring.rebufferEvents()==1);
    assert(ring.pop(planes,3)==0&&ring.underruns()==1);
    assert(ring.push(stereo,4)); assert(ring.pop(planes,4)==4);
    assert(left[0]==1000/32768.f*0.25f&&right[0]==-left[0]);
    // Dry exatamente na fronteira liga o último valor ao silêncio.
    assert(ring.pop(planes,4)==0);
    assert(left[0]==1300/32768.f*0.75f&&left[3]==0&&right[0]==-left[0]);
    ring.enablePriming(false); ring.setFadeFrames(0);
    // Ordem de canais preservada sem supor o layout da fonte.
    ring.reset(8,8); int16_t eight[8]={1,2,3,4,5,6,7,8};
    float values[8]{}; float *eightPlanes[8]; for(int i=0;i<8;i++) eightPlanes[i]=&values[i];
    assert(ring.push(eight,1)); assert(ring.pop(eightPlanes,1)==1);
    for(int i=0;i<8;i++) assert(values[i]==float(i+1)/32768.f);
}
