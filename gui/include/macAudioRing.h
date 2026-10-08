#pragma once
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <vector>

// SPSC: só consumidor avança read; clear publica um limite de descarte.
class MacAudioRing {
    std::vector<int16_t> data;
    size_t channels = 0, capacity = 0;
    std::atomic<uint64_t> read{0}, write{0}, discard{0};
    std::atomic<size_t> target{0},trimSlack{0};
    std::atomic<uint64_t> trimmed{0},rebuffered{0};
    std::vector<float> last,crossfade;
    size_t crossfadeRemaining=0;
    size_t fadeFrames=0,fadeInRemaining=0;
    bool silent=true;
    std::atomic<uint64_t> clearVersion{0}, starvation{0};
    uint64_t seenClear=0;
    bool primingEnabled=false,waiting=false;
public:
    void reset(size_t frames, size_t count) {
        channels=count; capacity=frames; data.assign(frames*count,0); last.assign(count,0.f);
        trimmed=0; rebuffered=0; fadeInRemaining=fadeFrames; crossfadeRemaining=0; crossfade.assign(fadeFrames*count,0.f); silent=true;
        read=0; write=0; discard=0; target=frames; clearVersion=0; starvation=0; seenClear=0; waiting=primingEnabled;
    }
    // Configurar com consumidor parado; espera inicial/rebuffer sem bloquear áudio.
    void enablePriming(bool enabled) { primingEnabled=enabled; waiting=enabled; }
    // Configurar fade com consumidor parado. Slack pode acompanhar alvo sem bloquear.
    void setFadeFrames(size_t frames) { fadeFrames=frames; fadeInRemaining=frames; crossfadeRemaining=0; crossfade.assign(frames*channels,0.f); }
    void setTrimSlack(size_t frames) { trimSlack.store(frames,std::memory_order_relaxed); }
    uint64_t trimmedFrames() const { return trimmed.load(std::memory_order_relaxed); }
    uint64_t rebufferEvents() const { return rebuffered.load(std::memory_order_relaxed); }
    bool renderedSilence() const { return silent; }
    uint64_t underruns() const { return starvation.load(std::memory_order_relaxed); }
    void setTarget(size_t frames) { target.store(std::min(frames,capacity),std::memory_order_relaxed); }
    size_t queued() const {
        auto w=write.load(std::memory_order_acquire),r=read.load(std::memory_order_acquire);
        r=std::max(r,discard.load(std::memory_order_acquire));
        return w>r?size_t(w-r):0;
    }
    void clear() { discard.store(write.load(std::memory_order_acquire),std::memory_order_release); clearVersion.fetch_add(1,std::memory_order_release); }
    bool push(const int16_t *pcm,size_t frames) {
        auto w=write.load(std::memory_order_relaxed),r=read.load(std::memory_order_acquire);
        if(frames>capacity || frames>capacity-(w-r)) return false;
        for(size_t f=0;f<frames;++f) for(size_t c=0;c<channels;++c)
            data[((w+f)%capacity)*channels+c]=pcm[f*channels+c];
        write.store(w+frames,std::memory_order_release); return true;
    }
    size_t pop(float **planes,size_t count) {
        silent=true;
        auto version=clearVersion.load(std::memory_order_acquire);
        if(version!=seenClear) { seenClear=version; waiting=primingEnabled; fadeInRemaining=fadeFrames; crossfadeRemaining=0; }
        auto r=read.load(std::memory_order_relaxed),w=write.load(std::memory_order_acquire);
        r=std::max(r,discard.load(std::memory_order_acquire));
        // O produtor pode publicar clear depois do snapshot de write.
        w=std::max(w,r);
        const auto limit=std::max(count,target.load(std::memory_order_relaxed));
        const auto slack=std::max(count*2,trimSlack.load(std::memory_order_relaxed));
        const auto oldRead=r;
        size_t cut=0;
        // Um pacote chegando entre callbacks é normal: cortar só após ultrapassar
        // a folga. Histerese volta ao alvo em vez de descartar em toda leitura.
        if(w-r>limit && w-r-limit>slack) {
            cut=size_t(w-r-limit); r+=cut;
            trimmed.fetch_add(cut,std::memory_order_relaxed);
            crossfadeRemaining=fadeFrames;
            // Guardar a continuação antiga antes de publicar read e liberar esses
            // slots ao produtor; crossfade pode atravessar callbacks pequenos.
            for(size_t f=0;f<crossfadeRemaining;++f) for(size_t c=0;c<channels;++c)
                crossfade[f*channels+c]=f<w-oldRead?float(data[((oldRead+f)%capacity)*channels+c])/32768.f:last[c];

        }
        bool prefill=primingEnabled&&waiting&&w-r<limit;
        if(waiting&&!prefill) fadeInRemaining=fadeFrames;
        size_t n=prefill?0:std::min(count,size_t(w-r));
        if(!prefill) waiting=false;
        const bool dry=!prefill&&n<count;
        size_t fadeOut=std::min(fadeFrames,n);
        for(size_t c=0;c<channels;++c) {
            for(size_t f=0;f<n;++f) {
                float value=float(data[((r+f)%capacity)*channels+c])/32768.f;
                if(crossfadeRemaining>f&&fadeFrames) {
                    const auto index=fadeFrames-crossfadeRemaining+f;
                    float before=crossfade[index*channels+c];
                    float t=float(index+1)/float(fadeFrames);
                    value=before+(value-before)*t;
                }
                if(fadeInRemaining>f&&fadeFrames)
                    value*=float(fadeFrames-fadeInRemaining+f+1)/float(fadeFrames);
                if(dry&&fadeOut&&f>=n-fadeOut)
                    value*=float(n-1-f)/float(fadeOut);
                planes[c][f]=value;
            }
            std::fill(planes[c]+n,planes[c]+count,0.f);
            // Se a fila secou exatamente na fronteira, ligar a última amostra
            // ao silêncio na próxima leitura evita um salto DC abrupto.
            if(!n&&fadeFrames&&last[c]!=0.f) {
                const auto tail=std::min(count,fadeFrames);
                for(size_t f=0;f<tail;++f) planes[c][f]=last[c]*float(tail-1-f)/float(tail);
                silent=false;
            }
            last[c]=count?planes[c][count-1]:last[c];
        }
        if(n) silent=false;
        fadeInRemaining=fadeInRemaining>n?fadeInRemaining-n:0;
        crossfadeRemaining=crossfadeRemaining>n?crossfadeRemaining-n:0;
        if(primingEnabled&&dry) {
            waiting=true; fadeInRemaining=fadeFrames; crossfadeRemaining=0;
            starvation.fetch_add(1,std::memory_order_relaxed);
            rebuffered.fetch_add(1,std::memory_order_relaxed);
        }
        read.store(r+n,std::memory_order_release); return n;
    }
};
