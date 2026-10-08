#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <cassert>

// Sem janela nem sessão: prova a regra do macOS que causou a queda no startup.
static bool acceptsDirectDrawable(CAMetalLayer *layer)
{
    @autoreleasepool {
        @try { (void)[layer nextDrawable]; return true; }
        @catch(NSException *exception) {
            assert([exception.name isEqualToString:@"CAMetalLayerInvalidOperation"]);
            return false;
        }
    }
}
int main()
{
    @autoreleasepool {
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = MTLCreateSystemDefaultDevice();
        assert(layer.device);
        layer.drawableSize = CGSizeMake(16, 16);
        layer.allowsNextDrawableTimeout = YES;
        assert(acceptsDirectDrawable(layer));
        if (@available(macOS 14.0, *)) {
            for (int cycle = 0; cycle < 3; ++cycle) {
                CAMetalDisplayLink *link = [[CAMetalDisplayLink alloc] initWithMetalLayer:layer];
                link.paused = YES;
                assert(!acceptsDirectDrawable(layer));
                [link invalidate];
                assert(acceptsDirectDrawable(layer));
                link = nil;
            }
        }
    }
}
