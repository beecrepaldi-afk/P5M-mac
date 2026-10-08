// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
#pragma once
#include <array>
#include <algorithm>
#include <cstdint>
#include <memory>

// O envio e os callbacks pertencem à mesma run loop. A ordem de conclusão
// não precisa acompanhar a ordem de envio; cada slot tem sua própria marca.
template<std::size_t Count, std::size_t Bytes>
class MacHidAsyncReports
{
public:
    struct Slot {
        MacHidAsyncReports *owner = nullptr;
        std::array<uint8_t, Bytes> report{};
        uint64_t sent_ns = 0;
        bool busy = false;
    };
    std::array<Slot, Count> slots{};
    unsigned failed = 0, done = 0;
    unsigned failed_in_row = 0; // P5M: para notar o controle que reconectou
    uint64_t sum_ns = 0, peak_ns = 0;

    MacHidAsyncReports() { for(auto &slot : slots) slot.owner = this; }
    MacHidAsyncReports(const MacHidAsyncReports &) = delete;
    MacHidAsyncReports &operator=(const MacHidAsyncReports &) = delete;

    Slot *acquire(uint64_t now)
    {
        for(auto &slot : slots)
            if(!slot.busy) {
                slot.busy = true;
                slot.sent_ns = now;
                return &slot;
            }
        return nullptr;
    }
    std::size_t inFlight() const
    {
        return std::count_if(slots.begin(), slots.end(), [](const Slot &slot) { return slot.busy; });
    }
    void complete(Slot &slot, uint64_t now, bool success)
    {
        if(slot.owner != this || !slot.busy)
            return;
        slot.busy = false;
        const auto took = now >= slot.sent_ns ? now - slot.sent_ns : 0;
        sum_ns += took;
        peak_ns = std::max(peak_ns, took);
        ++done;
        if(!success) { ++failed; ++failed_in_row; }
        else failed_in_row = 0;
    }
    void submissionFailed(Slot &slot)
    {
        if(slot.owner != this || !slot.busy)
            return;
        slot.busy = false;
        ++failed;
        ++failed_in_row;
    }

    // Close/Unschedule não garantem cancelamento. Se faltou callback, o
    // pequeno bloco de memória deve sobreviver ao dono e à run loop.
    // Caminho excepcional: prefere retenção até a saída a liberar buffers
    // que o kernel ainda possa usar. Não guarda logger nem sessão.
    static bool retainIfPending(std::unique_ptr<MacHidAsyncReports> &owner)
    {
        if(owner && owner->inFlight()) {
            (void)owner.release();
            return true;
        }
        return false;
    }
};
