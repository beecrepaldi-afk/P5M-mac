// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
#pragma once
#include <string>

struct MacSystemConsoleIdentity
{
    enum class Kind { Discovered, Manual, PSN };
    Kind kind = Kind::Discovered;
    std::string mac, address, duid;
    bool registered = false, ps5 = false;
};

// O ordinal da lista visível muda quando descobertas ocultam manuais/PSN.
// Resolva pelo transporte e identidade, nunca pelo nome ou índice visível.
inline bool MacSystemConsoleMatches(const MacSystemConsoleIdentity &selected,
                                   const MacSystemConsoleIdentity &candidate)
{
    if(!selected.registered || !candidate.registered || selected.kind != candidate.kind || selected.ps5 != candidate.ps5)
        return false;
    if(selected.kind == MacSystemConsoleIdentity::Kind::PSN)
        return !selected.duid.empty() && selected.duid == candidate.duid;
    return !selected.mac.empty() && !selected.address.empty()
        && selected.mac == candidate.mac && selected.address == candidate.address;
}
