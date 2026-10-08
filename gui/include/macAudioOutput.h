#pragma once
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

// Ordem explícita do PCM; não inferir um layout Sony pelo número de canais.
enum class MacAudioLayout { Unknown, Wave51, Wave71 };
class MacAudioOutput {
public:
    MacAudioOutput();
    ~MacAudioOutput();
    MacAudioOutput(const MacAudioOutput&) = delete;
    MacAudioOutput& operator=(const MacAudioOutput&) = delete;
    bool open(uint32_t rate, uint8_t channels, const std::string &deviceName,
              bool spatialEnabled, bool headTracking, uint32_t targetMs,
              std::string &error, MacAudioLayout layout = MacAudioLayout::Unknown);
    // open/close requerem produtor parado. queue/clear/métricas suportam consumidor simultâneo.
    bool queue(const int16_t *pcm, size_t frames);
    size_t queuedBytes() const;
    void setTargetMs(double ms);
    void clear();
    void close();
    bool isReady() const;
    bool needsReopen() const;
    std::string description() const;
    double latencyMs() const;
    uint64_t underruns() const;
    uint64_t trimmedFrames() const;
    uint64_t rebufferEvents() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
