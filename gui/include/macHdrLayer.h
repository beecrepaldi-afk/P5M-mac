#pragma once
#import <QuartzCore/CAMetalLayer.h>
#import <CoreGraphics/CoreGraphics.h>

// Menu e vídeo SDR sempre voltam ao mesmo formato/espaço SDR da abertura.
inline bool p5mWantsHdrLayer(bool requested, bool capable, bool pqVideo) {
    return requested && capable && pqVideo;
}

// Qt/AppKit podem reconfigurar a camada ao trocar o modo da janela.
// Confira a camada real, não só um booleano guardado no renderer.
inline bool p5mConfigureHdrLayer(CAMetalLayer *layer, bool hdr) {
    const auto format = hdr ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
    const CFStringRef expectedName = hdr ? kCGColorSpaceExtendedLinearSRGB : kCGColorSpaceSRGB;
    CFStringRef currentName = layer.colorspace ? CGColorSpaceGetName(layer.colorspace) : nullptr;
    if (layer.pixelFormat == format && layer.wantsExtendedDynamicRangeContent == hdr &&
        currentName && CFEqual(currentName, expectedName) && layer.EDRMetadata == nil)
        return false;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(expectedName);
    layer.EDRMetadata = nil;
    layer.pixelFormat = format;
    layer.colorspace = space;
    layer.wantsExtendedDynamicRangeContent = hdr;
    CGColorSpaceRelease(space);
    return true;
}
