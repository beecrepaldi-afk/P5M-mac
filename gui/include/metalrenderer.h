#ifndef CHIAKI_METALRENDERER_H
#define CHIAKI_METALRENDERER_H

#include <QSize>
#include <QRectF>

#include <functional>
#include <memory>

extern "C" {
#include <libavutil/frame.h>
}

class QWindow;
class QQuickRenderTarget;
class QQuickGraphicsDevice;

// Native macOS presenter: CAMetalLayer on the window's NSView.
//
// VideoToolbox frames are wrapped as Metal textures through
// CVMetalTextureCache (no GPU -> CPU -> GPU round trip), converted from YCbCr
// in a shader and composited under the Qt Quick UI, which Qt renders with its
// Metal RHI into a texture that we own. Everything else in the frame path
// (libplacebo, its queue and swapchain) is bypassed on this backend.
//
// All methods except create() must be called on the render thread.
class MetalRenderer
{
public:
	enum class Fit { Normal, Stretch, Zoom };

	static std::unique_ptr<MetalRenderer> create(QWindow *window);
	~MetalRenderer();

	QQuickGraphicsDevice graphicsDevice() const;

	// (Re)creates the drawable and the UI texture when the pixel size changes.
	// Returns true when the UI render target changed.
	bool resize(const QSize &pixel_size);
	bool hasOverlay() const;
	QQuickRenderTarget overlayRenderTarget() const;
	QSize pixelSize() const;

	void setVSync(bool enabled);
	void setSourceFrameRate(double fps);
	// Chamado na thread principal quando a tela muda de capacidade ou folga.
	void setRefreshCallback(std::function<void()> callback);
	// Experimental: extended linear sRGB output with the screen's EDR
	// headroom. UI white stays at 1; only HDR video receives a tone curve.
	void setHdr(bool enabled);
	// Pixels at the top the display hides (notch strip): the video is laid
	// out below them.
	void setHiddenTop(int pixels);
	// How many pictures in a row may be held back a refresh to keep one per
	// refresh before one is dropped to win the latency back.
	void setHoldLimit(int pictures);

	// Takes ownership of the frame. Accepts AV_PIX_FMT_VIDEOTOOLBOX and the
	// software formats the decoder or the startup warmup can produce
	// (yuv420p, yuv420p10, nv12, p010). Returns false if it was dropped.
	bool setVideoFrame(AVFrame *frame);
	void clearVideo();
	bool hasVideoFrame() const;

	// Mailbox-style pacing: at most one present waits for the display. While
	// one does, callers keep the newest picture (setVideoFrame) and render when
	// the callback fires, instead of blocking in nextDrawable behind the queue.
	bool presentSlotFree(bool count_deferred = true);
	// Called on an arbitrary thread when a present reaches the screen.
	void setPresentedCallback(std::function<void()> callback);

	// Draws video (if any) and the UI on top, and presents.
	bool render(bool draw_video, bool draw_overlay, Fit fit, float zoom_factor);

	// Waits for submitted GPU work; used before tearing the UI target down.
	void waitIdle();

private:
	MetalRenderer();
	struct Impl;
	std::shared_ptr<Impl> d;
};

#endif // CHIAKI_METALRENDERER_H
