#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "macHdrLayer.h"
#include <cstdio>
#include <cstdlib>
static void check(bool ok, const char *why) { if(!ok) { fprintf(stderr,"%s\n",why); exit(1); } }
static void checkLayer(CAMetalLayer *layer, bool hdr) {
    check(layer.pixelFormat == (hdr ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm), "Wrong drawable format");
    check(layer.wantsExtendedDynamicRangeContent == hdr, "Wrong EDR state");
    check(layer.colorspace && CFEqual(CGColorSpaceGetName(layer.colorspace), hdr ? kCGColorSpaceExtendedLinearSRGB : kCGColorSpaceSRGB), "Wrong color space");
    check(layer.EDRMetadata == nil, "Unexpected display tone-map metadata");
}
int main() { @autoreleasepool {
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    check(layer.device != nil, "No Metal device");
    for(int cycle=0; cycle<3; ++cycle) {
        check(p5mWantsHdrLayer(true,true,true), "PQ HDR rejected");
        p5mConfigureHdrLayer(layer,p5mWantsHdrLayer(true,true,true)); checkLayer(layer,true);
        check(!p5mConfigureHdrLayer(layer,true), "Stable HDR mode reconfigured");
        // Simula a camada reconfigurada pelo sistema durante fullscreen.
        CGColorSpaceRef srgb=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        layer.colorspace=srgb; CGColorSpaceRelease(srgb);
        layer.pixelFormat=MTLPixelFormatBGRA8Unorm; layer.wantsExtendedDynamicRangeContent=NO;
        check(p5mConfigureHdrLayer(layer,true), "Layer drift ignored"); checkLayer(layer,true);
        p5mConfigureHdrLayer(layer,p5mWantsHdrLayer(true,true,false)); checkLayer(layer,false);
        check(!p5mConfigureHdrLayer(layer,false), "Stable menu mode reconfigured");
        check(!p5mWantsHdrLayer(false,true,true), "Disabled HDR enabled");
        check(!p5mWantsHdrLayer(true,false,true), "Unsupported HDR enabled");
    }
    puts("HDR layer: PQ/fullscreen drift/menu/reset cycles passed without window or drawable");
} }
