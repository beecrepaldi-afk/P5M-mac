// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
#include <macSystemConsoleIdentity.h>
#include <vector>
#include <cstdio>

#define CHECK(condition) do { if(!(condition)) { std::fprintf(stderr, "Console identity assertion failed on line %d\n", __LINE__); return 1; } } while(0)
using Identity = MacSystemConsoleIdentity;
using Kind = Identity::Kind;
static int resolve(const Identity &selected, const std::vector<Identity> &servers)
{
    for(std::size_t i = 0; i < servers.size(); ++i)
        if(MacSystemConsoleMatches(selected, servers[i])) return int(i);
    return -1;
}
int main()
{
    // Dados sintéticos; não instancia backend/Settings, nem abre rede.
    const Identity discovered{Kind::Discovered, "synthetic-a", "example-a.invalid", "", true, true};
    const Identity duplicate_manual{Kind::Manual, "synthetic-a", "example-a.invalid", "", true, true};
    const Identity selected_manual{Kind::Manual, "synthetic-b", "example-b.invalid", "", true, true};
    const Identity hidden_psn{Kind::PSN, "", "", "synthetic-hidden", true, true};
    const Identity selected_psn{Kind::PSN, "", "", "synthetic-selected", true, true};
    std::vector<Identity> servers{discovered, duplicate_manual, selected_manual, hidden_psn, selected_psn};
    // Manual duplicado oculto ocupa índice bruto 1; o alvo continua em 2.
    CHECK(resolve(selected_manual, servers) == 2);
    // PSN omitido da lista visível também não desloca o alvo por identidade.
    CHECK(resolve(selected_psn, servers) == 4);
    CHECK(resolve(duplicate_manual, servers) == 1);
    CHECK(resolve(discovered, servers) == 0);
    std::swap(servers[0], servers[4]);
    CHECK(resolve(selected_psn, servers) == 0);
    auto invalid = selected_manual;
    invalid.registered = false;
    CHECK(resolve(invalid, servers) == -1);
    invalid = selected_manual; invalid.address = "different.invalid";
    CHECK(resolve(invalid, servers) == -1);
    invalid = selected_manual; invalid.ps5 = false;
    CHECK(resolve(invalid, servers) == -1);
    invalid = selected_psn; invalid.duid.clear();
    CHECK(resolve(invalid, servers) == -1);
    invalid = selected_manual; invalid.mac.clear();
    CHECK(resolve(invalid, servers) == -1);
    servers[2].registered = false;
    CHECK(resolve(selected_manual, servers) == -1);
    std::puts("Console identities: hidden duplicates, PSN filtering, reorder and mismatches passed");
}
