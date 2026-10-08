#!/usr/bin/env python3
"""Compile and exercise the actual P5M FEC helpers without opening a stream."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "lib/src/takion.c").read_text()
start = source.index("// Unidades AV entregues no quadro atual.")
end = source.index("static void p5m_reorder_log", start)
helpers = source[start:end]

prefix = r"""
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
typedef uint16_t ChiakiSeqNum16;
typedef struct {
    bool is_video;
    ChiakiSeqNum16 frame_index;
    uint16_t unit_index, units_in_frame_total, units_in_frame_fec;
} ChiakiTakionAVPacket;
typedef struct {
    bool p5m_fec_frame_valid;
    ChiakiSeqNum16 p5m_fec_frame_index;
    uint16_t p5m_fec_last_unit, p5m_fec_units_total, p5m_fec_units_fec;
    uint32_t p5m_fec_received;
} ChiakiTakion;
typedef struct { ChiakiTakionAVPacket packet; } TakionAVPacketEntry;
typedef struct { TakionAVPacketEntry *items[8]; } ChiakiReorderQueue;
static bool chiaki_reorder_queue_peek(ChiakiReorderQueue *q, uint64_t i,
        uint64_t *seq, void **user)
{
    if(i >= 8 || !q->items[i]) return false;
    *seq = i;
    *user = q->items[i];
    return true;
}
"""

tests = r"""
static void packet(TakionAVPacketEntry *e, unsigned frame, unsigned unit,
        unsigned total, unsigned fec)
{
    e->packet = (ChiakiTakionAVPacket){true, (uint16_t)frame,
        (uint16_t)unit, (uint16_t)total, (uint16_t)fec};
}
static void deliver(ChiakiTakion *t, TakionAVPacketEntry *e)
{
    p5m_note_delivered(t, &e->packet);
}

int main(void)
{
    ChiakiTakion t = {0}, other = {0};
    ChiakiReorderQueue q = {0};
    TakionAVPacketEntry u0, u1, u2, u3, u4, u6, next;

    // FEC 1: the first skipped source unit fits; another loss in-frame does not.
    packet(&u0, 7, 0, 11, 1);
    packet(&u2, 7, 2, 11, 1);
    packet(&u4, 7, 4, 11, 1);
    deliver(&t, &u0);
    q.items[1] = &u2;
    assert(p5m_fec_covers_gap(&t, &q, 1));
    deliver(&t, &u2); // packet after the early skip accounts for that erasure
    q.items[1] = &u4;
    assert(!p5m_fec_covers_gap(&t, &q, 1));

    // Accounting belongs to the Takion instance, not process-global state.
    deliver(&other, &u0);
    q.items[1] = &u2;
    assert(p5m_fec_covers_gap(&other, &q, 1));

    // A timeout-skipped prefix is counted when the first packet arrives.
    memset(&q, 0, sizeof(q));
    t = (ChiakiTakion){0};
    packet(&u1, 8, 1, 11, 1);
    packet(&u3, 8, 3, 11, 1);
    deliver(&t, &u1);
    q.items[1] = &u3;
    assert(!p5m_fec_covers_gap(&t, &q, 1));

    // Source losses and a parity loss both spend the same frame budget.
    memset(&q, 0, sizeof(q));
    t = (ChiakiTakion){0};
    packet(&u0, 9, 0, 7, 2);
    packet(&u3, 9, 3, 7, 2);
    packet(&u4, 9, 4, 7, 2);
    packet(&u6, 9, 6, 7, 2);
    deliver(&t, &u0);
    deliver(&t, &u3); // timeout skipped source units 1 and 2
    deliver(&t, &u4);
    q.items[1] = &u6; // parity unit 5 is also missing; total loss is three > FEC 2
    assert(!p5m_fec_covers_gap(&t, &q, 1));

    // Cross-frame skip: map tail+prefix exactly and require source completion.
    memset(&q, 0, sizeof(q));
    t = (ChiakiTakion){0};
    packet(&u0, 20, 0, 5, 1);
    packet(&u1, 20, 1, 5, 1);
    packet(&u2, 20, 2, 5, 1);
    packet(&u3, 20, 3, 5, 1);
    packet(&next, 21, 1, 5, 1);
    deliver(&t, &u0);
    deliver(&t, &u1);
    deliver(&t, &u2);
    deliver(&t, &u3);
    q.items[2] = &next; // prior parity tail (unit 4) and next prefix (unit 0)
    assert(p5m_fec_covers_gap(&t, &q, 2));

    memset(&q, 0, sizeof(q));
    t = (ChiakiTakion){0};
    packet(&u0, 30, 0, 5, 1);
    packet(&u2, 30, 2, 5, 1);
    packet(&u3, 30, 3, 5, 1);
    packet(&next, 31, 1, 5, 1);
    deliver(&t, &u0);
    deliver(&t, &u2);
    deliver(&t, &u3);
    q.items[2] = &next;
    assert(!p5m_fec_covers_gap(&t, &q, 2)); // source units in prior frame are incomplete

    puts("P5M Takion FEC regressions passed");
    return 0;
}
"""

clang = shutil.which("clang")
if not clang:
    raise SystemExit("clang is required for the offline FEC regression")
with tempfile.TemporaryDirectory(prefix="p5m-fec-") as temp:
    temp = Path(temp)
    harness = temp / "fec.c"
    binary = temp / "fec"
    harness.write_text(prefix + helpers + tests)
    subprocess.run([
        clang, "-std=c11", "-Wall", "-Wextra", "-Werror",
        "-fsanitize=address,undefined", str(harness), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
