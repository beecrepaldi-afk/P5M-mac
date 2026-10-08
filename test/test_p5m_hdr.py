#!/usr/bin/env python3
"""Compila os shaders reais no Metal e confere UI e curva HDR na GPU."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'gui/src/metalrenderer.mm').read_text()
shader = source.split('R"METAL(', 1)[1].split(')METAL"', 1)[0]
probe = r'''
kernel void hdr_probe(device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    float peak = 1.0 + float(i / 1024);
    float value = float(i % 1024) * (1000.0 / 203.0) / 1023.0;
    float3 color = compress(float3(value, value * 0.5, value * 0.25), 1000.0 / 203.0, peak);
    out[i] = float4(color, 1.0);
}
'''
harness = r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
static void check(bool ok, const char *message) {
    if (!ok) { fprintf(stderr, "%s\n", message); exit(1); }
}
int main() { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    check(device != nil, "No Metal GPU available");
    NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfFile:@SHADER_PATH encoding:NSUTF8StringEncoding error:&error];
    id<MTLLibrary> lib = [device newLibraryWithSource:source options:nil error:&error];
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLComputePipelineState> probe = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"hdr_probe"] error:&error];
    check(probe != nil, "Cannot create HDR probe");
    id<MTLBuffer> values = [device newBufferWithLength:4096 * 4 * sizeof(float) options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    id<MTLComputeCommandEncoder> compute = [cmd computeCommandEncoder];
    [compute setComputePipelineState:probe];
    [compute setBuffer:values offset:0 atIndex:0];
    [compute dispatchThreads:MTLSizeMake(4096, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [compute endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
    check(cmd.status == MTLCommandBufferStatusCompleted, "GPU HDR probe failed");
    float *v = (float *)values.contents;
    for (unsigned peak = 1; peak <= 4; ++peak) {
        float prev = -1;
        for (unsigned j = 0; j < 1024; ++j) {
            float *rgb = v + ((peak - 1) * 1024 + j) * 4;
            check(std::isfinite(rgb[0]) && rgb[0] >= prev - 1e-5 && rgb[0] <= peak + 1e-4, "HDR curve exceeds headroom or is not monotonic");
            check(fabs(rgb[1] - rgb[0] * 0.5) < 1e-4 && fabs(rgb[2] - rgb[0] * 0.25) < 1e-4, "HDR curve changes hue");
            if (j == 1023) check(fabs(rgb[0] - peak) < 1e-4, "Source peak does not reach display peak");
            prev = rgb[0];
        }
    }
    // Renderiza o fragmento real da interface, incluindo alfa pré-multiplicado.
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [lib newFunctionWithName:@"quad_vs"];
    desc.fragmentFunction = [lib newFunctionWithName:@"overlay_hdr_fs"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    check(pipeline != nil, "Cannot create UI pipeline");
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> input = [device newTextureWithDescriptor:td];
    id<MTLTexture> target = [device newTextureWithDescriptor:td];
    const float samples[][4] = {{1,1,1,1}, {0.5,0.25,0.75,1}, {0.25,0.125,0.375,0.5}, {0,0,0,0}};
    float quad[] = {-1,1,1,-1,0,0,1,1};
    for (auto &s : samples) {
        [input replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:s bytesPerRow:sizeof(s)];
        cmd = [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> render = [cmd renderCommandEncoderWithDescriptor:pass];
        [render setRenderPipelineState:pipeline];
        [render setVertexBytes:quad length:sizeof(quad) atIndex:0];
        [render setFragmentTexture:input atIndex:0];
        [render drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [render endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
        check(cmd.status == MTLCommandBufferStatusCompleted, "GPU UI rendering failed");
        float result[4];
        [target getBytes:result bytesPerRow:sizeof(result) fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
        check(fabs(result[3] - s[3]) < 1e-5, "UI alpha changed");
        for (unsigned c = 0; c < 3; ++c) {
            double encoded = s[3] > 0 ? s[c] / s[3] : 0;
            double expected = (encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)) * s[3];
            check(std::isfinite(result[c]) && fabs(result[c] - expected) < 1e-4, "UI color or white changed");
        }
    }
    puts("P5M Metal HDR: shader compilation, UI white/colors/alpha, headroom 1..4, monotonicity and hue passed");
} }
'''
with tempfile.TemporaryDirectory(prefix='p5m-hdr-') as temporary:
    folder = Path(temporary)
    metal = folder / 'shader.metal'
    metal.write_text(shader + probe)
    mm = folder / 'hdr.mm'
    mm.write_text(harness.replace('SHADER_PATH', '"' + str(metal) + '"'))
    binary = folder / 'hdr'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', str(mm), '-framework', 'Foundation', '-framework', 'Metal', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
