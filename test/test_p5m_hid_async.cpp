// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
#include <macHidAsyncReports.h>
#include <cstdio>

#define CHECK(condition) do { if(!(condition)) { std::fprintf(stderr, "HID async assertion failed on line %d\n", __LINE__); return 1; } } while(0)
int main()
{
    using Pool = MacHidAsyncReports<4, 142>;
    auto pool = std::make_unique<Pool>();
    auto *a = pool->acquire(10), *b = pool->acquire(20), *c = pool->acquire(30), *d = pool->acquire(40);
    CHECK(a && b && c && d);
    a->report.fill(11); b->report.fill(22); c->report.fill(33); d->report.fill(44);
    CHECK(pool->acquire(50) == nullptr);
    // O segundo envio termina antes do primeiro: só o seu slot pode ser usado.
    pool->complete(*b, 60, true);
    auto *next = pool->acquire(70);
    CHECK(next == b);
    next->report.fill(55);
    CHECK(a->report[100] == 11 && c->report[100] == 33 && d->report[100] == 44);
    CHECK(pool->inFlight() == 4);
    // Recusa imediata libera somente o slot correspondente.
    pool->submissionFailed(*next);
    CHECK(pool->inFlight() == 3 && pool->failed == 1);
    CHECK(pool->acquire(80) == b);
    pool->complete(*a, 90, true);
    pool->complete(*d, 100, false);
    pool->complete(*c, 110, true);
    pool->complete(*b, 120, true);
    CHECK(pool->inFlight() == 0 && pool->failed == 2 && pool->done == 5);
    // Callback repetido não provoca underflow nem altera as estatísticas.
    pool->complete(*b, 130, true);
    CHECK(pool->inFlight() == 0 && pool->done == 5);
    CHECK(!Pool::retainIfPending(pool) && pool);
    // Simula prazo esgotado no teardown, sem liberar callback/report pendente.
    auto *pending = pool->acquire(140);
    pending->report.fill(66);
    auto *retained = pool.get();
    CHECK(Pool::retainIfPending(pool) && !pool);
    CHECK(pending->report[100] == 66);
    pending->owner->complete(*pending, 150, true);
    CHECK(retained->inFlight() == 0);
    // O teste recupera a retenção; produção conserva-a até a saída do processo.
    delete retained;
    std::puts("HID async: out-of-order callbacks, immediate errors and pending teardown passed");
}
