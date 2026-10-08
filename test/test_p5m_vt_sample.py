#!/usr/bin/env python3
"""Exercita a conversão Annex B real com NALs sintéticos e sanitizadores."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "lib/src/ffmpegdecoder.c").read_text()
helpers = source[source.index("static const uint8_t *vt_direct_next_start"):
                 source.index("static void vt_direct_release_pb")]
start = source.index("static bool vt_direct_decode")
body = source[source.index("\tsize_t used = 0;", start):source.index("\tif(vt->ps_dirty)", start)]
prefix = r'''
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#define CHIAKI_LOGE(log, ...) ((void)(log))
typedef struct { uint8_t *sample; size_t sample_cap; bool hevc;
    uint8_t ps[3][1024]; size_t ps_size[3]; bool ps_dirty; } VtDirect;
typedef struct { void *log; } ChiakiFfmpegDecoder;
'''
wrapper = '''static bool convert(VtDirect *vt, const uint8_t *buf, size_t size, size_t *output_size) {
    ChiakiFfmpegDecoder value = {0};
    ChiakiFfmpegDecoder *decoder = &value;
''' + body + '''    *output_size = used;
    return true;
}
'''
tests = r'''
static void run(unsigned count, bool mixed) {
    VtDirect vt = {0};
    // A mesma capacidade da entrada que transbordava antes da correção.
    vt.sample_cap = 519;
    vt.sample = malloc(vt.sample_cap);
    uint8_t *input = malloc((size_t)count * 8);
    assert(vt.sample && input);
    size_t size = 0;
    const uint8_t nal[] = {0x61, 0x11, 0x22, 0x33};
    for(unsigned i = 0; i < count; ++i) {
        if(mixed && i % 2) input[size++] = 0;
        input[size++] = 0; input[size++] = 0; input[size++] = 1;
        memcpy(input + size, nal, sizeof(nal)); size += sizeof(nal);
    }
    size_t output = 0;
    assert(convert(&vt, input, size, &output));
    assert(output == (size_t)count * 8);
    assert(vt.sample_cap >= output);
    for(unsigned i = 0; i < count; ++i) {
        const uint8_t *p = vt.sample + i * 8;
        assert(p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 4);
        assert(memcmp(p + 4, nal, sizeof(nal)) == 0);
    }
    free(input); free(vt.sample);
}
int main(void) {
    run(65, false); run(128, true); run(10000, false);
    puts("P5M Annex B buffer regressions passed");
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="p5m-vt-sample-") as temporary:
    folder = Path(temporary)
    harness = folder / "sample.c"
    binary = folder / "sample"
    harness.write_text(prefix + helpers + wrapper + tests)
    subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=address,undefined", str(harness), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
