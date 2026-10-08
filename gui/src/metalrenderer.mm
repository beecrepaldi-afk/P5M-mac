#include "metalrenderer.h"
#include "macHdrLayer.h"
#include "macDisplayPacing.h"
#include "macPresentationStats.h"
#include "macRenderDeadline.h"
#if __has_include(<StateReporting/StateReporting.h>)
#import <StateReporting/StateReporting.h>
#define P5M_STATE_REPORTING 1
#endif

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CAMetalDisplayLink.h>

#include <QLoggingCategory>
#include <QQuickGraphicsDevice>
#include <QQuickRenderTarget>
#include <QStringList>
#include <QWindow>
#include <QTimer>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <thread>
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <mutex>
#include <cmath>
#include <mach/mach_time.h>
#include <cstdlib>

extern "C" {
#include <libavutil/pixdesc.h>
}

#if !__has_feature(objc_arc)
#error "metalrenderer.mm must be compiled with -fobjc-arc"
#endif

Q_DECLARE_LOGGING_CATEGORY(chiakiGui);

namespace {

// Layout shared with the shaders below.
struct QuadParams
{
	float rect[4];   // NDC x0, y0, x1, y1
	float uvrect[4]; // u0, v0, u1, v1
};

struct VideoParams
{
	float m0[4], m1[4], m2[4]; // rows of the Y'CbCr -> R'G'B' matrix
	float scale[4];            // sample * scale - offset = normalized Y', Cb, Cr
	float offset[4];
	int32_t planes;            // 2 = biplanar (CbCr together), 3 = planar
	int32_t transfer;          // 0 = SDR, 1 = PQ
	float source_peak;         // PQ: source peak in panel-white units
	int32_t dither;            // 1 = dither for an 8-bit target here
	int32_t output;            // 0 = SDR drawable, 1 = extended linear sRGB
	float output_peak;         // EDR headroom; 1 = SDR white
};

// SDR panel white for the PQ mapping. Same choice as the P5M tone mapper:
// HDR reference white (203 nits) lands at ~93% of the panel instead of 76%.
constexpr float kPanelWhiteNits = 240.0f;
constexpr float kDefaultSourcePeakNits = 1000.0f;

enum Transfer : int32_t { TransferSDR = 0, TransferPQ = 1 };

const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct QuadParams { float4 rect; float4 uvrect; };
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut quad_vs(uint vid [[vertex_id]], constant QuadParams &q [[buffer(0)]])
{
	float2 c = float2(float(vid & 1), float(vid >> 1));
	VOut o;
	o.pos = float4(mix(q.rect.xy, q.rect.zw, c), 0.0, 1.0);
	o.uv = mix(q.uvrect.xy, q.uvrect.zw, c);
	return o;
}

struct VideoParams {
	float4 m0, m1, m2;
	float4 scale, offset;
	int planes, transfer;
	float source_peak;
	int dither;
	int output;
	float output_peak;
};

static float3 pq_to_nits(float3 e)
{
	const float m1 = 0.1593017578125, m2 = 78.84375;
	const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
	float3 p = pow(max(e, 0.0), 1.0 / m2);
	return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
}

static float3 srgb_encode(float3 l)
{
	l = saturate(l);
	return select(1.055 * pow(l, 1.0 / 2.4) - 0.055, 12.92 * l, l <= 0.0031308);
}

static float3 srgb_decode(float3 c)
{
	c = saturate(c);
	return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

// PQ -> SDR, ported from the P5M tone mapper (tone_mapper.cpp, dev.233).
// Order matters: the gamut matrix is only valid in linear light, and the tone
// curve comes after it.

// BT.2020 -> BT.709 in linear light.
static float3 bt2020_to_bt709(float3 c)
{
	const float3x3 m = float3x3(
		float3( 1.6605, -0.1246, -0.0182),
		float3(-0.5876,  1.1329, -0.1006),
		float3(-0.0728, -0.0083,  1.1187));
	return m * c;
}

// Pulls a color with a negative channel toward the gray of equal luminance,
// just enough for the smallest channel to reach zero: loses saturation the
// panel cannot show and keeps hue and luminance (clipping at zero changes both).
static float3 into_gamut(float3 c)
{
	float mn = min(min(c.r, c.g), c.b);
	if (mn >= 0.0)
		return c;
	float y = dot(c, float3(0.2126, 0.7152, 0.0722));
	if (y <= 0.0)
		return float3(0.0);
	return y + (c - y) * (y / (y - mn));
}

// Straight up to the knee, soft compression from there to the source peak, on
// the largest channel with the whole color scaled by the same ratio (per
// channel compression washes out highlights and shifts their hue). With
// excess e, panel headroom A and source headroom R:
// g(e) = e (1 + e A / R^2) / (1 + e / A) leaves the knee with slope 1, is
// increasing and reaches A exactly at R.
static float3 compress(float3 c, float source_peak, float output_peak)
{
	// Com folga EDR, preserva o branco SDR; sem folga, usa a curva SDR.
	const float knee = min(0.8 * output_peak, 1.0);
	float m = max(max(c.r, c.g), c.b);
	if (m <= knee)
		return c;
	float headroom = output_peak - knee;
	float range = max(source_peak - knee, headroom);
	float e = m - knee;
	float g = e * (1.0 + e * headroom / (range * range)) / (1.0 + e / headroom);
	return c * (min(knee + g, output_peak) / m);
}

// Triangular dither of one 8-bit step for the 8-bit target: two interleaved
// gradient noises (Jimenez), fixed in screen space so it does not shimmer.
static float ign(float2 p)
{
	return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
}

static float dither(float2 p)
{
	return (ign(p) + ign(p + float2(47.0, 17.0)) - 1.0) / 255.0;
}

static float3 tonemap_pq(float3 rgb2020, float source_peak)
{
	float3 lin = bt2020_to_bt709(pq_to_nits(rgb2020)) / float(240.0);
	float3 rec709 = saturate(compress(into_gamut(lin), source_peak, 1.0));
	return srgb_encode(rec709);
}

// Catmull-Rom (bicubic, slightly sharp) in 9 bilinear taps: a cheap enlarge
// for when MetalFX is off. At 1:1 it gives back the texel itself.
static float sample_catmull_rom(texture2d<float> t, sampler s, float2 uv)
{
	float2 size = float2(t.get_width(), t.get_height());
	float2 pos = uv * size;
	float2 p1 = floor(pos - 0.5) + 0.5;
	float2 f = pos - p1;
	float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	float2 w3 = f * f * (-0.5 + 0.5 * f);
	float2 w12 = w1 + w2;
	float2 t0 = (p1 - 1.0) / size;
	float2 t3 = (p1 + 2.0) / size;
	float2 t12 = (p1 + w2 / w12) / size;
	float r = 0.0;
	r += t.sample(s, float2(t0.x,  t0.y)).r  * w0.x  * w0.y;
	r += t.sample(s, float2(t12.x, t0.y)).r  * w12.x * w0.y;
	r += t.sample(s, float2(t3.x,  t0.y)).r  * w3.x  * w0.y;
	r += t.sample(s, float2(t0.x,  t12.y)).r * w0.x  * w12.y;
	r += t.sample(s, float2(t12.x, t12.y)).r * w12.x * w12.y;
	r += t.sample(s, float2(t3.x,  t12.y)).r * w3.x  * w12.y;
	r += t.sample(s, float2(t0.x,  t3.y)).r  * w0.x  * w3.y;
	r += t.sample(s, float2(t12.x, t3.y)).r  * w12.x * w3.y;
	r += t.sample(s, float2(t3.x,  t3.y)).r  * w3.x  * w3.y;
	return r;
}

fragment float4 video_fs(VOut in [[stage_in]],
                         constant VideoParams &p [[buffer(0)]],
                         texture2d<float> ty [[texture(0)]],
                         texture2d<float> tu [[texture(1)]],
                         texture2d<float> tv [[texture(2)]])
{
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	float y = sample_catmull_rom(ty, s, in.uv);
	float2 c = p.planes == 2 ? tu.sample(s, in.uv).rg
	                         : float2(tu.sample(s, in.uv).r, tv.sample(s, in.uv).r);
	float3 yuv = float3(y, c) * p.scale.xyz - p.offset.xyz;
	float3 rgb = float3(dot(p.m0.xyz, yuv), dot(p.m1.xyz, yuv), dot(p.m2.xyz, yuv));
	if (p.output == 1) {
		// Só o vídeo HDR recebe a curva; SDR permanece em 0..1 linear.
		if (p.transfer == 1) {
			float3 lin = into_gamut(bt2020_to_bt709(pq_to_nits(saturate(rgb)))) / 203.0;
			return float4(compress(lin, p.source_peak * (240.0 / 203.0), p.output_peak), 1.0);
		}
		return float4(srgb_decode(rgb), 1.0);
	}
	if (p.transfer == 1) {
		rgb = tonemap_pq(rgb, p.source_peak);
		if (p.dither)
			rgb += dither(in.pos.xy);
	}
	return float4(saturate(rgb), 1.0);
}

// Upscaled picture (fp16, sRGB-encoded) onto the 8-bit drawable; the dither
// happens here, after MetalFX, so the scaler never sees the noise.
fragment float4 present_fs(VOut in [[stage_in]], texture2d<float> t [[texture(0)]])
{
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	float3 rgb = t.sample(s, in.uv).rgb;
	return float4(saturate(rgb + dither(in.pos.xy)), 1.0);
}

fragment float4 overlay_fs(VOut in [[stage_in]], texture2d<float> t [[texture(0)]])
{
	constexpr sampler s(filter::nearest, address::clamp_to_edge);
	return t.sample(s, in.uv);
}

// Qt entrega sRGB com alfa pré-multiplicado: desfaz antes de linearizar,
// depois recompõe o alfa para misturar em luz linear. Branco = 1, sem curva.
fragment float4 overlay_hdr_fs(VOut in [[stage_in]], texture2d<float> t [[texture(0)]])
{
	constexpr sampler s(filter::nearest, address::clamp_to_edge);
	float4 c = t.sample(s, in.uv);
	if (c.a <= 0.0)
		return float4(0.0);
	return float4(srgb_decode(c.rgb / c.a) * c.a, c.a);
}
)METAL";

// One decoded picture and the Metal views of its planes. Kept alive by the
// command buffers that sample it.
struct VideoFrame
{
	uint64_t presentation_id = 0;
	AVFrame *frame = nullptr;
	CVMetalTextureRef cv_tex[2] = {};
	id<MTLTexture> tex[3] = {};
	int width = 0;
	int height = 0;
	double sar = 1.0;
	VideoParams params = {};
	CFTimeInterval arrival = 0;          // CACurrentMediaTime() when handed over
	std::atomic<bool> latency_counted { false };

	~VideoFrame()
	{
		for (auto &t : cv_tex)
			if (t)
				CFRelease(t);
		av_frame_free(&frame);
	}
};

void fillColorParams(VideoParams &p, const AVFrame *frame, int bits, double norm, int planes)
{
	double kr = 0.2126, kb = 0.0722;
	switch (frame->colorspace) {
	case AVCOL_SPC_BT2020_NCL:
	case AVCOL_SPC_BT2020_CL:
		kr = 0.2627; kb = 0.0593;
		break;
	case AVCOL_SPC_SMPTE170M:
	case AVCOL_SPC_BT470BG:
		kr = 0.299; kb = 0.114;
		break;
	default:
		break;
	}
	const double kg = 1.0 - kr - kb;
	const float rows[3][3] = {
		{ 1.0f, 0.0f, float(2.0 * (1.0 - kr)) },
		{ 1.0f, float(-2.0 * kb * (1.0 - kb) / kg), float(-2.0 * kr * (1.0 - kr) / kg) },
		{ 1.0f, float(2.0 * (1.0 - kb)), 0.0f },
	};
	for (int i = 0; i < 3; i++) {
		p.m0[i] = rows[0][i];
		p.m1[i] = rows[1][i];
		p.m2[i] = rows[2][i];
	}

	const double step = std::ldexp(1.0, bits - 8);
	double y_off, y_range, c_off, c_range;
	if (frame->color_range == AVCOL_RANGE_JPEG) {
		y_off = 0.0;
		y_range = std::ldexp(1.0, bits) - 1.0;
		c_off = std::ldexp(1.0, bits - 1);
		c_range = y_range;
	} else {
		y_off = 16.0 * step;
		y_range = 219.0 * step;
		c_off = 128.0 * step;
		c_range = 224.0 * step;
	}
	p.scale[0] = float(norm / y_range);
	p.scale[1] = p.scale[2] = float(norm / c_range);
	p.offset[0] = float(y_off / y_range);
	p.offset[1] = p.offset[2] = float(c_off / c_range);
	p.planes = planes;
	p.transfer = frame->color_trc == AVCOL_TRC_SMPTE2084 ? TransferPQ : TransferSDR;
	p.source_peak = kDefaultSourcePeakNits / kPanelWhiteNits;
	p.output_peak = 1.0f;
}

} // namespace

static QRectF videoRect(const QSize &target, double src_w, double src_h, MetalRenderer::Fit fit, float zoom_factor)
{
	const double tw = target.width(), th = target.height();
	switch (fit) {
	case MetalRenderer::Fit::Stretch:
		return QRectF(0, 0, tw, th);
	case MetalRenderer::Fit::Zoom: {
		// Zoom goes from fit (0) to filling the whole panel, notch band
		// included (1, or -1 as saved by older builds); above 1 it keeps going.
		const double fit_s = std::min(tw / src_w, th / src_h);
		const double fill_s = std::max(tw / src_w, th / src_h);
		const double z = zoom_factor == -1 ? 1.0 : std::max(0.0, double(zoom_factor));
		const double s = z <= 1 ? fit_s + (fill_s - fit_s) * z : fill_s * z;
		return QRectF((tw - src_w * s) / 2, (th - src_h * s) / 2, src_w * s, src_h * s);
	}
	case MetalRenderer::Fit::Normal:
	default: {
		const double s = std::min(tw / src_w, th / src_h);
		return QRectF((tw - src_w * s) / 2, (th - src_h * s) / 2, src_w * s, src_h * s);
	}
	}
}

@interface ChiakiDisplayLinkTarget : NSObject <CAMetalDisplayLinkDelegate>
@property (atomic, copy) void (^handler)(CAMetalDisplayLinkUpdate *update);
@end

@implementation ChiakiDisplayLinkTarget
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update
{
	(void)link;
	void (^handler)(CAMetalDisplayLinkUpdate *) = self.handler;
	if (handler)
		handler(update);
}
@end

struct MetalRenderer::Impl : std::enable_shared_from_this<MetalRenderer::Impl>
{
	struct PresentedLifetime {
		std::mutex mutex;
		Impl *owner = nullptr;
	};
	std::shared_ptr<PresentedLifetime> presented_lifetime = std::make_shared<PresentedLifetime>();
	QWindow *window = nullptr;
	id<MTLDevice> device;
	id<MTLCommandQueue> queue;
	CAMetalLayer *layer;
	CVMetalTextureCacheRef texture_cache = nullptr;
	id<MTLRenderPipelineState> video_pipeline;
	id<MTLRenderPipelineState> video_pipeline_f16;
	id<MTLRenderPipelineState> present_pipeline;
	id<MTLRenderPipelineState> overlay_pipeline;
	id<MTLRenderPipelineState> overlay_pipeline_hdr;
	// HDR output: wanted (setting) and possible (screen with EDR headroom),
	// set from other threads; the layer is switched on the render thread.
	std::atomic<bool> hdr_wanted { false };
	std::atomic<bool> hdr_capable { false };
	std::atomic<float> hdr_headroom { 1.0f };
	std::atomic<bool> hdr_active { false };

	// MetalFX spatial upscaling of the video (opt-in: CHIAKI_METALFX=1).
	std::atomic<bool> fx_enabled { false };
	std::atomic<bool> fx_scaler_active { false };
	id<MTLFXSpatialScaler> fx_scaler;
	id<MTLTexture> fx_in, fx_out;
	QSize fx_in_size, fx_out_size;

	// Display-link automático em telas variáveis (macOS 14+), com override manual:
	// CAMetalDisplayLink calls us on our own thread right when a refresh needs
	// its picture, and we draw the newest one into the drawable it hands over.
	// No queue to guess at, and the picture is as fresh as the panel allows.
	std::atomic<bool> use_display_link { false };
	std::atomic<bool> variable_refresh { false };
	std::atomic<bool> vsync_enabled { true };
	std::atomic<double> source_fps { 60.0 };
	int display_link_override = -1;
    // Sessão real: late latch caiu de59.5 para47.1fps sem ganho de atraso.
    // Tela fixa volta à fila medida; VRR mantém o link sem espera adicional.
    bool deadline_enabled = false;
    std::mutex deadline_mutex;
    std::condition_variable deadline_changed;
    p5m::display::RenderBudget render_budget;
    std::atomic<unsigned> deadline_waits { 0 }, deadline_late { 0 };
    std::atomic<uint64_t> deadline_wait_us { 0 };
    bool qt_layer = false;
    NSDictionary *last_window_state = nil; // somente thread principal
#if P5M_STATE_REPORTING
    SRStateReporter *state_reporter API_AVAILABLE(macos(27.0));
#endif
	std::function<void()> refresh_callback; // chamado na thread principal
	p5m::display::PacingPolicy pacing_policy; // protegido por state_mutex
	std::mutex encode_mutex; // serializa a troca de apresentador e os encoders
	std::mutex display_link_control_mutex;
	std::atomic<bool> display_link_control_pending { false };
	CAMetalDisplayLink *display_link API_AVAILABLE(macos(14.0));
	ChiakiDisplayLinkTarget *display_link_target;
	NSThread *display_link_thread;
	std::atomic<bool> display_link_stop { false };
	std::atomic<CFRunLoopRef> display_link_runloop { nullptr };
	dispatch_semaphore_t display_link_done;

	// What the next picture should show; written on the render thread, read by
	// whichever thread draws.
	std::mutex state_mutex;
	bool want_video = false, want_overlay = false;
	MetalRenderer::Fit want_fit = MetalRenderer::Fit::Normal;
	float want_zoom = 0;
	bool dirty = false;

	// Decoded picture -> on screen (presentedTime).
	std::atomic<uint64_t> stats_glass_sum_us { 0 };
	std::atomic<uint64_t> stats_glass_max_us { 0 };
	std::atomic<unsigned> stats_glass_count { 0 };
	std::atomic<unsigned> stats_presents_atomic { 0 };

	static void addSample(std::atomic<uint64_t> &sum, std::atomic<uint64_t> &max, std::atomic<unsigned> &count, uint64_t us)
	{
		sum += us;
		count++;
		uint64_t prev = max.load();
		while (us > prev && !max.compare_exchange_weak(prev, us)) {}
	}

	std::atomic<int> presents_waiting { 0 };
	// Presents allowed to wait for the display at once. The compositor needs
	// the next picture about a refresh ahead, so one starved it (~35 of 60
	// presents/s on a 60 Hz panel); CHIAKI_METAL_QUEUE overrides for tests.
	int max_presents_waiting = 2;
	// Submit -> on screen, from the drawable's presentedTime.
	std::atomic<uint64_t> stats_screen_sum_us { 0 };
	std::atomic<uint64_t> stats_screen_max_us { 0 };
	std::atomic<unsigned> stats_screen_count { 0 };
	std::atomic<uint64_t> last_submit_us { 0 };
	std::mutex presented_callback_mutex; // clearing it waits out a running call
	std::function<void()> presented_callback;
	unsigned stats_deferred = 0;

	// Steered tearing (VSync off). Without VSync the panel takes the new
	// picture about flip_latency after the commit (~7.5 ms in Direct, vs ~30
	// with VSync), cutting it wherever the scanout is. Since stream and panel
	// both run at 60 Hz that cut sits still and shows. Holding the commit
	// until the flip lands on the vertical blank puts the cut in the blanking
	// or the black bars, at about half the VSync delay. Vblank times come from
	// a CVDisplayLink; flip_latency (present -> flip, 1.5-5 ms) is learned from
	// presentedTime as a mean, so the flips spread around the vblank into the
	// black bars on both sides.
	// CHIAKI_TEAR_STEER=0 turns it off, CHIAKI_TEAR_OFFSET_US moves the aim.
	bool steer_enabled = false;
	double steer_offset = 0;
	static constexpr double steer_late_ok = 0.0006; // past the vblank: top black bar
	CVDisplayLinkRef cv_link = nullptr;
	std::mutex cv_link_mutex;
	std::mutex vblank_sample_mutex;
	std::atomic<bool> cv_link_available { false };
	std::atomic<double> vblank_ref { 0 };
	std::atomic<double> vblank_period { 1.0 / 60.0 };
	std::atomic<double> flip_latency { 0.004 };
	std::atomic<int> hidden_top { 0 };

	// Aim that hides the cut best (04/10/2026). A cut is invisible while the
	// flip lands in black rows: the strip under the camera and the bars above
	// the picture (just after the vblank), or the bars below it (just
	// before). The present->flip delay spreads unevenly (2-5 ms, long late
	// tail), so aiming its mean at the vblank threw part of the flips into
	// the picture. From the last delays and the black rows of the current
	// layout, pick when to present so the most flips land in black:
	// steer_latency (seconds before the vblank to present).
	std::mutex aim_mutex;
	double aim_samples[128] = {};
	unsigned aim_count = 0, aim_next = 0, aim_since = 0;
	std::atomic<double> steer_latency { 0 };   // 0 = not learned yet (use flip_latency)
	std::atomic<double> black_top_frac { 0 }, black_bottom_frac { 0 };
	std::atomic<unsigned> stats_hidden { 0 }, stats_hidden_count { 0 };

	void learnFlipDelay(double latency)
	{
		std::lock_guard<std::mutex> lock(aim_mutex);
		aim_samples[aim_next] = latency;
		aim_next = (aim_next + 1) % 128;
		aim_count = std::min(aim_count + 1, 128u);
		if (++aim_since < 30 || aim_count < 60)
			return;
		aim_since = 0;
		const double period = vblank_period.load();
		const double T = black_top_frac.load() * period;     // black time after the vblank
		const double B = black_bottom_frac.load() * period;  // black time before it
		double lo = 1, hi = 0;
		for (unsigned i = 0; i < aim_count; i++) {
			lo = std::min(lo, aim_samples[i]);
			hi = std::max(hi, aim_samples[i]);
		}
		// Present at vblank + c; flip phase = c + delay. Best c, 0.1 ms steps;
		// among ties the middle one (margin on both sides).
		unsigned best = 0;
		double best_lo = 0, best_hi = 0;
		for (double c = -B - hi; c <= T - lo + 1e-9; c += 0.0001) {
			unsigned in = 0;
			for (unsigned i = 0; i < aim_count; i++) {
				const double ph = c + aim_samples[i];
				in += ph >= -B && ph <= T;
			}
			if (in > best) {
				best = in;
				best_lo = best_hi = c;
			} else if (in == best) {
				best_hi = c;
			}
		}
		if (best > 0)
			steer_latency.store(-(best_lo + best_hi) / 2);
	}
	std::atomic<int> hold_limit { 30 };
	// Diagnostics for the "picture stops updating" bug: drawables the
	// display never showed, and GPU errors.
	std::atomic<unsigned> stats_not_shown { 0 };
	std::atomic<unsigned> stats_gpu_errors { 0 };
	// Steered presents run on their own real-time thread (the audio kind):
	// a normal thread can wake 1-3 ms late, which is a visible cut.
	std::thread present_thread;
	std::mutex present_mutex;
	std::condition_variable present_cv;
	std::deque<std::function<void()>> present_jobs;
	bool present_quit = false;
	std::atomic<uint64_t> stats_wake_late_sum_us { 0 }, stats_wake_late_max_us { 0 };
	std::atomic<unsigned> stats_wake_count { 0 };
	std::atomic<uint64_t> stats_flip_sum_us { 0 }, stats_flip_max_us { 0 };
	std::atomic<uint64_t> stats_flip_min_us { UINT64_MAX };
	std::atomic<unsigned> stats_flip_count { 0 };
	double last_slot = 0; // present thread only
	unsigned held_run = 0;
	std::atomic<unsigned> stats_slot_held { 0 }, stats_slot_skipped { 0 }, stats_slot_dropped { 0 };
	// Presentation clock for steered presents (present thread only).
	FILE *pace_trace = nullptr; // TEMP

	static void maxInto(std::atomic<uint64_t> &m, uint64_t v)
	{
		uint64_t prev = m.load();
		while (v > prev && !m.compare_exchange_weak(prev, v)) {}
	}

	void startPresentThread()
	{
		present_thread = std::thread([this] {
			pthread_setname_np("chiaki-present");
			const double period = 1.0 / 60.0;
			thread_time_constraint_policy_data_t policy;
			policy.period = uint32_t(secondsToMach(period));
			policy.computation = uint32_t(secondsToMach(0.001));
			policy.constraint = uint32_t(secondsToMach(0.002));
			policy.preemptible = 1;
			if (thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
			                      (thread_policy_t)&policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT) != KERN_SUCCESS)
				qCWarning(chiakiGui) << "Metal renderer: real-time present thread refused, using a normal one";
			for (;;) {
				std::function<void()> job;
				{
					std::unique_lock<std::mutex> lock(present_mutex);
					present_cv.wait(lock, [this] { return present_quit || !present_jobs.empty(); });
					if (present_jobs.empty())
						return;
					job = std::move(present_jobs.front());
					present_jobs.pop_front();
				}
				@autoreleasepool {
					job();
				}
			}
		});
	}

	void postPresent(std::function<void()> job)
	{
		{
			std::lock_guard<std::mutex> lock(present_mutex);
			if (present_quit)
				return;
			present_jobs.push_back(std::move(job));
		}
		present_cv.notify_one();
	}

	void stopPresentThread()
	{
		if (!present_thread.joinable())
			return;
		{
			std::lock_guard<std::mutex> lock(present_mutex);
			present_quit = true;
		}
		present_cv.notify_one();
		present_thread.join();
	}
	std::atomic<uint64_t> stats_steer_wait_sum_us { 0 }, stats_steer_wait_max_us { 0 };
	std::atomic<unsigned> stats_steered { 0 };
	// Where flips land against the vblank: signed sum, max distance, and how
	// many within 1 ms (off the picture when it has black bars).
	std::atomic<int64_t> stats_phase_sum_us { 0 };
	std::atomic<uint64_t> stats_phase_max_us { 0 };
	std::atomic<unsigned> stats_phase_count { 0 };
	std::atomic<unsigned> stats_phase_near { 0 };
	std::atomic<unsigned> stats_phase_hist[17] = {}; // 1 ms bins, -8..+8 ms

	static double machToSeconds(uint64_t t)
	{
		static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t i; mach_timebase_info(&i); return i; }();
		return double(t) * tb.numer / tb.denom / 1e9;
	}

	static uint64_t secondsToMach(double s)
	{
		static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t i; mach_timebase_info(&i); return i; }();
		return uint64_t(s * 1e9 * tb.denom / tb.numer);
	}

	double period_est = 0, last_vblank_host = 0; // display link thread only

	void startVblankClock()
	{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		std::lock_guard<std::mutex> lock(cv_link_mutex);
		if (CVDisplayLinkCreateWithActiveCGDisplays(&cv_link) != kCVReturnSuccess) {
			cv_link = nullptr;
			return;
		}
		CVDisplayLinkSetCurrentCGDisplay(cv_link, windowDisplay());
		std::weak_ptr<Impl> weak = shared_from_this();
		CVDisplayLinkSetOutputHandler(cv_link, ^CVReturn(CVDisplayLinkRef current_link, const CVTimeStamp *, const CVTimeStamp *out,
		                                                 CVOptionFlags, CVOptionFlags *) {
			auto impl = weak.lock();
			if (!impl)
				return kCVReturnSuccess;
			std::lock_guard<std::mutex> sample_lock(impl->vblank_sample_mutex);
			// The "actual" refresh period CoreVideo reports is noise (14 to
			// 19.7 ms on a 16.667 ms panel, a third of the readings off by
			// more than 0.2 ms): the phase computed from it was 3.6 ms off in
			// the median (measured 04/10/2026), so pictures were aimed at the
			// wrong refresh. Use the nominal period, refined slowly from the
			// spacing of the vblank timestamps themselves.
			double nominal = 0;
			if (out->videoTimeScale > 0 && out->videoRefreshPeriod > 0)
				nominal = double(out->videoRefreshPeriod) / out->videoTimeScale;
			else {
				const double actual = CVDisplayLinkGetActualOutputVideoRefreshPeriod(current_link);
				if (actual > 0.002 && actual < 0.05)
					nominal = actual;
			}
			if (nominal <= 0)
				return kCVReturnSuccess;
			if (impl->period_est <= 0 || std::fabs(impl->period_est - nominal) > 0.001)
				impl->period_est = nominal;
			if (out->flags & kCVTimeStampHostTimeValid) {
				const double host = machToSeconds(out->hostTime);
				if (impl->last_vblank_host > 0) {
					const double d = host - impl->last_vblank_host;
					const double n = std::round(d / impl->period_est);
					if (n >= 1 && n <= 4 && std::fabs(d / n - nominal) < 0.0005)
						impl->period_est += (d / n - impl->period_est) * 0.01;
				}
				impl->last_vblank_host = host;
				impl->vblank_ref.store(host);
			}
			impl->vblank_period.store(impl->period_est);
			return kCVReturnSuccess;
		});
		cv_link_available.store(CVDisplayLinkStart(cv_link) == kCVReturnSuccess);
#pragma clang diagnostic pop
	}

	void stopVblankClock()
	{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		std::lock_guard<std::mutex> lock(cv_link_mutex);
		if (!cv_link)
			return;
		cv_link_available.store(false);
		CVDisplayLinkStop(cv_link);
		CVDisplayLinkRelease(cv_link);
		cv_link = nullptr;
#pragma clang diagnostic pop
	}

	CGDirectDisplayID windowDisplay() const
	{
		if (window) {
			NSWindow *ns_window = ((__bridge NSView *)reinterpret_cast<void *>(window->winId())).window;
			NSNumber *number = ns_window.screen.deviceDescription[@"NSScreenNumber"];
			if (number)
				return number.unsignedIntValue;
		}
		return CGMainDisplayID();
	}

	void selectVblankDisplay()
	{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		std::lock_guard<std::mutex> lock(cv_link_mutex);
		if (!cv_link)
			return;
		cv_link_available.store(false);
		CVDisplayLinkStop(cv_link);
		const CVReturn selected = CVDisplayLinkSetCurrentCGDisplay(cv_link, windowDisplay());
		if (selected != kCVReturnSuccess)
			qCWarning(chiakiGui) << "Metal renderer: failed to follow the window to its new display:" << selected;
		{
			std::lock_guard<std::mutex> sample_lock(vblank_sample_mutex);
			period_est = 0;
			last_vblank_host = 0;
			vblank_ref.store(0);
		}
		cv_link_available.store(CVDisplayLinkStart(cv_link) == kCVReturnSuccess);
#pragma clang diagnostic pop
	}

	// Signed distance from t to the nearest (aimed) vblank, in seconds.
	double vblankPhase(double t)
	{
		const double ref = vblank_ref.load();
		const double period = vblank_period.load();
		double phase = std::fmod(t - ref - steer_offset, period);
		if (phase < 0)
			phase += period;
		return phase >= period / 2 ? phase - period : phase;
	}

	// Pacing diary, one line every 10 s: gaps between decoded pictures
	// (network + decoder), time blocked waiting for a drawable, GPU time.
	uint64_t stats_window_start_us = 0;
	uint64_t last_frame_us = 0;
	unsigned stats_frames = 0, stats_gaps_25 = 0, stats_gaps_50 = 0, stats_gaps_100 = 0;
	uint64_t stats_gap_max_us = 0, stats_drawable_wait_max_us = 0, stats_drawable_wait_sum_us = 0;
	unsigned stats_presents = 0, stats_no_drawable = 0;
	std::mutex stats_mutex;
	std::atomic<uint64_t> stats_gpu_max_us { 0 };
	std::atomic<uint64_t> stats_gpu_sum_us { 0 };
	std::atomic<unsigned> stats_gpu_count { 0 };

	static uint64_t nowUs()
	{
		static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
		return mach_absolute_time() * tb.numer / tb.denom / 1000;
	}

	void noteFrame()
	{
		const uint64_t now = nowUs();
		uint64_t window_start, gap_max, drawable_wait_max, drawable_wait_sum;
		unsigned frames, gaps_25, gaps_50, gaps_100, presents, no_drawable, deferred;
		{
			std::lock_guard<std::mutex> lock(stats_mutex);
			if (last_frame_us) {
				const uint64_t gap = now - last_frame_us;
				stats_gap_max_us = std::max(stats_gap_max_us, gap);
				stats_gaps_25 += gap > 25000;
				stats_gaps_50 += gap > 50000;
				stats_gaps_100 += gap > 100000;
			}
			last_frame_us = now;
			stats_frames++;
			if (!stats_window_start_us)
				stats_window_start_us = now;
			if (now - stats_window_start_us < 10000000)
				return;
			window_start = stats_window_start_us;
			frames = stats_frames;
			gaps_25 = stats_gaps_25;
			gaps_50 = stats_gaps_50;
			gaps_100 = stats_gaps_100;
			gap_max = stats_gap_max_us;
			drawable_wait_max = stats_drawable_wait_max_us;
			drawable_wait_sum = stats_drawable_wait_sum_us;
			presents = stats_presents + stats_presents_atomic.exchange(0);
			no_drawable = stats_no_drawable;
			deferred = stats_deferred;
			stats_window_start_us = now;
			stats_frames = stats_gaps_25 = stats_gaps_50 = stats_gaps_100 = 0;
			stats_gap_max_us = stats_drawable_wait_max_us = stats_drawable_wait_sum_us = 0;
			stats_presents = stats_no_drawable = stats_deferred = 0;
		}
		const unsigned gpu_n = stats_gpu_count.exchange(0);
		const uint64_t gpu_sum = stats_gpu_sum_us.exchange(0);
		const uint64_t gpu_max = stats_gpu_max_us.exchange(0);
		const unsigned screen_n = stats_screen_count.exchange(0);
		const uint64_t screen_sum = stats_screen_sum_us.exchange(0);
		const uint64_t screen_max = stats_screen_max_us.exchange(0);
		const unsigned glass_n = stats_glass_count.exchange(0);
		const uint64_t glass_sum = stats_glass_sum_us.exchange(0);
		const uint64_t glass_max = stats_glass_max_us.exchange(0);
		const QString pacing = use_display_link ? QStringLiteral("display link")
		                                        : QStringLiteral("queue %1, deferred %2").arg(max_presents_waiting).arg(deferred);
		QString pacing_mode = pacing + (layer.displaySyncEnabled ? QStringLiteral(", vsync") :
			steer_enabled ? QStringLiteral(", no vsync, steering enabled") : QStringLiteral(", no vsync, immediate"));
		p5m::display::PresentationSnapshot shown;
		{
			std::lock_guard<std::mutex> metrics(presentation_stats_mutex);
			shown = presentation_stats.takeSnapshot();
		}
		qCInfo(chiakiGui).noquote() << QString::asprintf(
			"[presentation] 10s: unique frames %llu (%.1f fps), same-frame callbacks %llu, out-of-order callbacks %llu; "
			"unique frame interval avg %.2f max %.2f ms (%llu intervals); fixed-refresh gap buckets <0.75T/1T/2T/3T/4T+ [%llu %llu %llu %llu %llu]",
			static_cast<unsigned long long>(shown.uniqueFrames), shown.uniqueFrames * 1e6 / double(now - window_start),
			static_cast<unsigned long long>(shown.repeatedCallbacks), static_cast<unsigned long long>(shown.outOfOrderCallbacks),
			shown.meanIntervalSeconds * 1000, shown.maxIntervalSeconds * 1000,
			static_cast<unsigned long long>(shown.intervalCount),
			static_cast<unsigned long long>(shown.intervalBuckets[0]), static_cast<unsigned long long>(shown.intervalBuckets[1]),
			static_cast<unsigned long long>(shown.intervalBuckets[2]), static_cast<unsigned long long>(shown.intervalBuckets[3]),
			static_cast<unsigned long long>(shown.intervalBuckets[4]));
		if (const unsigned steered = stats_steered.exchange(0))
			pacing_mode += QString::asprintf(", steered %u wait avg %.1f max %.1f ms, flip latency %.1f ms", steered,
			                                 stats_steer_wait_sum_us.exchange(0) / 1000.0 / steered,
			                                 stats_steer_wait_max_us.exchange(0) / 1000.0, flip_latency.load() * 1000);
		{
			QString hist;
			for (auto &bin : stats_phase_hist)
				hist += QString::number(bin.exchange(0)) + QLatin1Char(' ');
			pacing_mode += QStringLiteral(", phase hist -8..8 ms [") + hist.trimmed() + QLatin1Char(']');
		}
		if (steer_enabled && !layer.displaySyncEnabled)
			pacing_mode += QString::asprintf(", refresh slots held %u repeated %u dropped %u", stats_slot_held.exchange(0),
			                                 stats_slot_skipped.exchange(0), stats_slot_dropped.exchange(0));
		{
			const unsigned not_shown = stats_not_shown.exchange(0);
			NSWindow *win = ((__bridge NSView *)reinterpret_cast<void *>(window->winId())).window;
			pacing_mode += QString::asprintf(", not shown %u, gpu errors %u, window %s%s%s", not_shown, stats_gpu_errors.load(),
			                                 (win.occlusionState & NSWindowOcclusionStateVisible) ? "visible" : "OCCLUDED",
			                                 win.isKeyWindow ? " key" : "", NSApp.isActive ? " active" : " inactive");
		}
		if (const unsigned n = stats_wake_count.exchange(0))
			pacing_mode += QString::asprintf(", wake late avg %.2f max %.2f ms", stats_wake_late_sum_us.exchange(0) / 1000.0 / n,
			                                 stats_wake_late_max_us.exchange(0) / 1000.0);
		if (const unsigned n = stats_flip_count.exchange(0))
			pacing_mode += QString::asprintf(", present->flip min %.2f avg %.2f max %.2f ms", stats_flip_min_us.exchange(UINT64_MAX) / 1000.0,
			                                 stats_flip_sum_us.exchange(0) / 1000.0 / n, stats_flip_max_us.exchange(0) / 1000.0);
		if (const unsigned n = stats_phase_count.exchange(0)) {
			const int64_t sum = stats_phase_sum_us.exchange(0);
			const unsigned near = stats_phase_near.exchange(0);
			pacing_mode += QString::asprintf(", flip vs vblank avg %+.1f max %.1f ms, %u%% within 1 ms",
			                                 sum / 1000.0 / n, stats_phase_max_us.exchange(0) / 1000.0, near * 100 / n);
			if (const unsigned hn = stats_hidden_count.exchange(0)) {
				const double period = vblank_period.load();
				pacing_mode += QString::asprintf(", cut hidden in black %u%% (black %.2f ms after / %.2f before, aim %.2f ms)",
				                                 stats_hidden.exchange(0) * 100 / hn, black_top_frac.load() * period * 1000,
				                                 black_bottom_frac.load() * period * 1000, steer_latency.load() * 1000);
			}
		}
        const unsigned waits = deadline_waits.exchange(0);
        const unsigned late = deadline_late.exchange(0);
        const uint64_t waited = deadline_wait_us.exchange(0);
        if (use_display_link.load())
            qCInfo(chiakiGui) << "[deadline] 10s: waits" << waits
                << "mean wait ms" << (waits ? waited / 1000.0 / waits : 0.0)
                << "GPU completed after render target" << late;
		qCInfo(chiakiGui).noquote() << QString::asprintf(
			"[pacing] 10s: %u frames (%.1f fps), gaps >25ms %u >50ms %u >100ms %u, max gap %.1f ms; "
			"frame->screen avg %.1f max %.1f ms; presents %u (%s), submit->screen avg %.1f max %.1f ms; "
			"no drawable %u, drawable wait avg %.2f max %.1f ms; gpu avg %.2f max %.1f ms%s",
			frames, frames * 1e6 / double(now - window_start),
			gaps_25, gaps_50, gaps_100, gap_max / 1000.0,
			glass_n ? glass_sum / 1000.0 / glass_n : 0.0, glass_max / 1000.0,
			presents, qUtf8Printable(pacing_mode),
			screen_n ? screen_sum / 1000.0 / screen_n : 0.0, screen_max / 1000.0,
			no_drawable,
			presents ? drawable_wait_sum / 1000.0 / presents : 0.0, drawable_wait_max / 1000.0,
			gpu_n ? gpu_sum / 1000.0 / gpu_n : 0.0, gpu_max / 1000.0,
			fx_scaler_active.load() && fx_enabled ? ", MetalFX on" : "");
	}
	id<MTLTexture> overlay;
	QSize pixel_size;
	std::shared_ptr<VideoFrame> video;
	uint64_t next_video_id = 0; // protegido por state_mutex
	std::mutex presentation_stats_mutex;
	p5m::display::PresentationStats presentation_stats;
	bool logged_formats[AV_PIX_FMT_NB] = {};

	Impl()
	{
		presented_lifetime->owner = this;
	}

	~Impl()
	{
		{
			std::lock_guard<std::mutex> lock(presented_lifetime->mutex);
			presented_lifetime->owner = nullptr;
		}
#if P5M_STATE_REPORTING
        if (@available(macOS 27.0, *))
            [state_reporter reportTransitionToStateLabel:nil stableMetadata:nil volatileMetadata:nil];
#endif
		video.reset();

		if (texture_cache)
			CFRelease(texture_cache);
	}

	bool buildPipelines()
	{
		NSError *error = nil;
		id<MTLLibrary> library = [device newLibraryWithSource:@(kShaderSource) options:nil error:&error];
		if (!library) {
			qCCritical(chiakiGui) << "Metal shader compilation failed:" << error.localizedDescription.UTF8String;
			return false;
		}
		MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
		desc.vertexFunction = [library newFunctionWithName:@"quad_vs"];
		desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		desc.fragmentFunction = [library newFunctionWithName:@"video_fs"];
		video_pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];

		desc.fragmentFunction = [library newFunctionWithName:@"present_fs"];
		present_pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];

		desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
		desc.fragmentFunction = [library newFunctionWithName:@"video_fs"];
		video_pipeline_f16 = [device newRenderPipelineStateWithDescriptor:desc error:&error];
		desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		// Qt Quick renders premultiplied alpha.
		desc.fragmentFunction = [library newFunctionWithName:@"overlay_fs"];
		desc.colorAttachments[0].blendingEnabled = YES;
		desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
		desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
		desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		overlay_pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
		desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
		desc.fragmentFunction = [library newFunctionWithName:@"overlay_hdr_fs"];
		overlay_pipeline_hdr = [device newRenderPipelineStateWithDescriptor:desc error:&error];

		if (!video_pipeline || !video_pipeline_f16 || !present_pipeline || !overlay_pipeline || !overlay_pipeline_hdr) {
			qCCritical(chiakiGui) << "Metal pipeline creation failed:" << error.localizedDescription.UTF8String;
			return false;
		}
		return true;
	}

	// Puts the layer in extended linear sRGB (fp16, EDR) or back in SDR when the
	// setting or the screen changed. Render thread, before taking a drawable;
	// the pipelines follow each drawable's own format.
	void applyHdrMode(bool pq_video)
	{
		const bool want = p5mWantsHdrLayer(hdr_wanted.load(), hdr_capable.load(), pq_video);
		const bool changed = p5mConfigureHdrLayer(layer, want);
		if (!changed && want == hdr_active)
			return;
		hdr_active = want;
		qCInfo(chiakiGui) << "Metal renderer: HDR output (experimental)" << (want ? "on" : "off")
		                  << "wanted" << hdr_wanted.load() << "screen capable" << hdr_capable.load()
		                  << "PQ video" << pq_video << "layer restored" << changed
		                  << "linear EDR headroom" << hdr_headroom.load();
	}

	// Encodes the picture (MetalFX pass if it applies, then video + UI) and
	// presents it. With drawable == nil one is taken from the layer, as late
	// as possible; the display link hands its own.
	bool encodeAndPresent(id<CAMetalDrawable> drawable, std::shared_ptr<VideoFrame> video, bool draw_overlay,
	                      MetalRenderer::Fit fit, float zoom_factor, id<MTLTexture> ui, QSize size, double render_target = 0.0)
	{
        const double encode_started = CACurrentMediaTime();
		auto keep_alive = shared_from_this();
		if (size.isEmpty())
			return false;
		if (!video && fx_scaler) {
			// Stream over: give back the scaler and its ~60 MB of textures.
			fx_scaler = nil;
			fx_scaler_active.store(false);
			fx_in = nil;
			fx_out = nil;
			fx_in_size = fx_out_size = QSize();
		}
        // Revalida a opacidade também depois das transições de janela do Qt.
        if (!layer.opaque) layer.opaque = YES;
		applyHdrMode(video && video->params.transfer == 1);
		// Um drawable entregue pelo display link pode pertencer ao formato anterior.
		if (drawable && drawable.texture.pixelFormat != layer.pixelFormat)
			return false;
		id<MTLCommandBuffer> cmd = [queue commandBuffer];
		const double tw = size.width(), th = size.height();

		QRectF r;
		QRectF shown;              // the part of r on screen
		float uv[4] = { 0, 0, 1, 1 }; // the source region it shows
		bool upscaled = false;
		if (video) {
			// Lay the picture out in the part of the panel that shows (below
			// the notch strip in fullscreen).
			const int top = qBound(0, hidden_top.load(), size.height() / 4);
			r = videoRect(QSize(size.width(), size.height() - top), video->width * video->sar, video->height, fit, zoom_factor)
				.translated(0, top);
			// Zoom pushes the picture past the edges: MetalFX upscales only
			// the visible part of the source, so zoom stays as sharp.
			shown = r.intersected(QRectF(0, top, tw, th - top));
			if (shown.isEmpty())
				shown = r;
			black_top_frac.store(std::clamp(shown.top() / th, 0.0, 0.5));
			black_bottom_frac.store(std::clamp((th - shown.bottom()) / th, 0.0, 0.5));
			uv[0] = float((shown.left() - r.left()) / r.width());
			uv[1] = float((shown.top() - r.top()) / r.height());
			uv[2] = float((shown.right() - r.left()) / r.width());
			uv[3] = float((shown.bottom() - r.top()) / r.height());
			const QSize in(qMax(1, qRound(video->width * (uv[2] - uv[0]))), qMax(1, qRound(video->height * (uv[3] - uv[1]))));
			const QSize out(qRound(shown.width()), qRound(shown.height()));
			const bool grows = out.width() > in.width() * 1.05 || out.height() > in.height() * 1.05;
			if (fx_enabled && !hdr_active && (!drawable || drawable.texture.pixelFormat == MTLPixelFormatBGRA8Unorm) && grows && out.width() >= in.width() && out.height() >= in.height()
			    && ensureScaler(in, out)) {
				MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture = fx_in;
				pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
				QuadParams quad = { { -1, 1, 1, -1 }, { uv[0], uv[1], uv[2], uv[3] } };
				VideoParams params = video->params;
				params.dither = 0;
				[enc setRenderPipelineState:video_pipeline_f16];
				[enc setVertexBytes:&quad length:sizeof(quad) atIndex:0];
				[enc setFragmentBytes:&params length:sizeof(params) atIndex:0];
				for (int i = 0; i < 3; i++)
					[enc setFragmentTexture:video->tex[i] atIndex:i];
				[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
				[enc endEncoding];
				[fx_scaler encodeToCommandBuffer:cmd];
				upscaled = true;
			}
		}

		// Qt/AppKit pode reconfigurar a camada em fullscreen. Reafirma a escolha
		// do usuário também no quadro atual, não só ao alternar a preferência.
		const bool wanted_sync = vsync_enabled.load();
		if (bool(layer.displaySyncEnabled) != wanted_sync)
			layer.displaySyncEnabled = wanted_sync ? YES : NO;
		const bool queued = !use_display_link;
		const bool steer = queued && steer_enabled && !variable_refresh.load() && cv_link_available.load() && !layer.displaySyncEnabled && vblank_ref.load() > 0;
		const bool no_vsync = !layer.displaySyncEnabled;
		if (!drawable) {
			const uint64_t wait_start = nowUs();
			drawable = [layer nextDrawable];
			const uint64_t wait = nowUs() - wait_start;
			if (!drawable) {
				{
					std::lock_guard<std::mutex> lock(stats_mutex);
					stats_no_drawable++;
				}
				return false;
			}
			{
				std::lock_guard<std::mutex> lock(stats_mutex);
				stats_drawable_wait_sum_us += wait;
				stats_drawable_wait_max_us = std::max(stats_drawable_wait_max_us, wait);
			}
		}
		id<MTLTexture> target = drawable.texture;
		const bool hdr_target = target.pixelFormat == MTLPixelFormatRGBA16Float;
		stats_presents_atomic++;
		MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture = target;
		pass.colorAttachments[0].loadAction = MTLLoadActionClear;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;
		pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
		id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];

		if (video) {
			// Upscaled: fx_out is exactly the visible part. Otherwise draw the
			// whole picture and let the edges fall off screen.
			const QRectF q = upscaled ? shown : r;
			QuadParams quad = {
				{ float(q.left() / tw * 2 - 1), float(1 - q.top() / th * 2),
				  float(q.right() / tw * 2 - 1), float(1 - q.bottom() / th * 2) },
				{ 0, 0, 1, 1 },
			};
			[enc setVertexBytes:&quad length:sizeof(quad) atIndex:0];
			if (upscaled) {
				[enc setRenderPipelineState:present_pipeline];
				[enc setFragmentTexture:fx_out atIndex:0];
			} else {
				VideoParams params = video->params;
				params.dither = hdr_target ? 0 : 1;
				params.output = hdr_target ? 1 : 0;
				params.output_peak = hdr_headroom.load();
				[enc setRenderPipelineState:hdr_target ? video_pipeline_f16 : video_pipeline];
				[enc setFragmentBytes:&params length:sizeof(params) atIndex:0];
				for (int i = 0; i < 3; i++)
					[enc setFragmentTexture:video->tex[i] atIndex:i];
			}
			[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
		}

		if (draw_overlay && ui) {
			QuadParams quad = { { -1, 1, 1, -1 }, { 0, 0, 1, 1 } };
			[enc setRenderPipelineState:hdr_target ? overlay_pipeline_hdr : overlay_pipeline];
			[enc setVertexBytes:&quad length:sizeof(quad) atIndex:0];
			[enc setFragmentTexture:ui atIndex:0];
			[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
		}

		[enc endEncoding];
		if (queued) {
			presents_waiting++;
			last_submit_us.store(nowUs());
		}
		const CFTimeInterval submit_time = CACurrentMediaTime();
		// When the present call went out (steered: after the GPU and the wait).
		auto present_call = std::make_shared<std::atomic<double>>(0.0);
		auto lifetime = presented_lifetime;
		void (^on_shown)(id<MTLDrawable>) = ^(id<MTLDrawable> shown) {
			std::lock_guard<std::mutex> lock(lifetime->mutex);
			Impl *impl = lifetime->owner;
			if (!impl)
				return;
			const CFTimeInterval on_screen = shown.presentedTime;
			{
				std::lock_guard<std::mutex> metrics(impl->presentation_stats_mutex);
				if (on_screen > 0 && video)
					impl->presentation_stats.record(video->presentation_id, on_screen,
						impl->vblank_period.load(), !impl->variable_refresh.load());
				else
					impl->presentation_stats.interrupt();
			}
			if (on_screen <= 0)
				impl->stats_not_shown++;
			if (on_screen > 0) {
				addSample(impl->stats_screen_sum_us, impl->stats_screen_max_us, impl->stats_screen_count,
				          uint64_t(std::max(0.0, on_screen - submit_time) * 1e6));
				const double called = present_call->load();
				// Aprendizado de mira só no experimento guiado; imediato não precisa calibrar.
				if (no_vsync && steer && called > 0) {
					const double latency = on_screen - called;
					const uint64_t latency_us = uint64_t(std::max(0.0, latency) * 1e6);
					impl->stats_flip_sum_us += latency_us;
					impl->stats_flip_count++;
					maxInto(impl->stats_flip_max_us, latency_us);
					uint64_t prev_min = impl->stats_flip_min_us.load();
					while (latency_us < prev_min && !impl->stats_flip_min_us.compare_exchange_weak(prev_min, latency_us)) {}
					if (latency > 0.0005 && latency < 0.03) {
						const double est = impl->flip_latency.load();
						impl->flip_latency.store(est + (latency - est) * 0.05);
						impl->learnFlipDelay(latency);
					}
				}
				if (impl->vblank_ref.load() > 0) {
					const double phase = impl->vblankPhase(on_screen);
					impl->stats_phase_sum_us += int64_t(phase * 1e6);
					impl->stats_phase_count++;
					impl->stats_phase_near += std::fabs(phase) < 0.001;
					{
						const double period = impl->vblank_period.load();
						const double T = impl->black_top_frac.load() * period, B = impl->black_bottom_frac.load() * period;
						impl->stats_hidden += phase >= -B && phase <= T;
						impl->stats_hidden_count++;
					}
					const int bin = std::clamp(int(std::lround(phase * 1000)), -8, 8) + 8;
					impl->stats_phase_hist[bin]++;
					const uint64_t dist = uint64_t(std::fabs(phase) * 1e6);
					uint64_t prev = impl->stats_phase_max_us.load();
					while (dist > prev && !impl->stats_phase_max_us.compare_exchange_weak(prev, dist)) {}
				}
				if (video && !video->latency_counted.exchange(true))
					addSample(impl->stats_glass_sum_us, impl->stats_glass_max_us, impl->stats_glass_count,
					          uint64_t(std::max(0.0, on_screen - video->arrival) * 1e6));
			}
			if (!queued)
				return;
			int left = --impl->presents_waiting;
			if (left < 0) {
				impl->presents_waiting.store(0);
				left = 0;
			}
			if (left < impl->max_presents_waiting) {
				std::lock_guard<std::mutex> lock(impl->presented_callback_mutex);
				if (impl->presented_callback)
					impl->presented_callback();
			}
		};
		if (steer) {
			// The GPU time (MetalFX: 5 ms, up to 10) varies too much to aim
			// through it: present only once the picture is drawn.
			const double arrival = video ? video->arrival : 0;
			id<CAMetalDrawable> to_show = drawable;
			[cmd addCompletedHandler:^(id<MTLCommandBuffer>) {
				const double ready = CACurrentMediaTime();
				keep_alive->postPresent([keep_alive, to_show, on_shown, present_call, arrival, ready] {
					keep_alive->presentSteered(to_show, on_shown, present_call, arrival, ready);
				});
			}];
		} else {
			[drawable addPresentedHandler:on_shown];
			present_call->store(submit_time);
			[cmd presentDrawable:drawable];
		}
		[cmd addCompletedHandler:^(id<MTLCommandBuffer> done) {
			Impl *impl = keep_alive.get();
			// Also keeps the CVPixelBuffer alive until the GPU has read it.
			(void)video;
			if (done.error && impl->stats_gpu_errors++ < 5)
				qCWarning(chiakiGui) << "Metal renderer: command buffer failed:" << done.error.localizedDescription.UTF8String;
			const double gpu = done.GPUEndTime - done.GPUStartTime;
            if (gpu > 0) {
                addSample(impl->stats_gpu_sum_us, impl->stats_gpu_max_us, impl->stats_gpu_count, uint64_t(gpu * 1e6));
                std::lock_guard<std::mutex> timing(impl->deadline_mutex);
                // Inclui encode na CPU e espera pela fila compartilhada com o Qt,
                // não apenas GPUStart -> End (que subestimaria a folga necessária).
                if (!done.error)
                    impl->render_budget.record(done.GPUEndTime - encode_started);
            }
            if (render_target > 0 && done.GPUEndTime > render_target)
                impl->deadline_late++;
		}];
		[cmd commit];
		return true;
	}

	// Runs on the present thread once the GPU has drawn the picture: hold it until
	// the flip lands on the vblank (a flip just past one is fine: the cut
	// lands in the top black bar), then present.
	void presentSteered(id<CAMetalDrawable> drawable, void (^on_shown)(id<MTLDrawable>),
	                    std::shared_ptr<std::atomic<double>> present_call, double arrival, double ready)
	{
		const double learned = steer_latency.load();
		const double aim = learned > 0 ? learned : flip_latency.load();
		const double period = vblank_period.load();
		// The learned aim already holds its margins: present late only a hair.
		const double late_ok = learned > 0 ? 0.0002 : steer_late_ok;
		auto earliest = [&](double t) {
			const double ph = vblankPhase(t);
			return t + (ph > late_ok ? period - ph : ph < 0 ? -ph : 0);
		};
		// Earliest refresh this picture could make from when the GPU finished
		// it, not from when this job got its turn: pictures queue here behind
		// the one waiting for its refresh, and judged by their turn they never
		// count as held, so the queue stayed full (3 pictures, ~50 ms).
		const double flip = CACurrentMediaTime() + aim;
		double slot = earliest(ready + aim);
		// Keep one picture per refresh. Pictures that arrive right at a refresh
		// boundary would otherwise jitter between two refreshes: two in one
		// (one never seen) and none in the next (a repeat), a visible stutter.
		// So follow the previous picture's refresh; skip one only when this
		// picture cannot make it, and drop one only after half a second of
		// holding pictures back (to win the latency back). Replayed on a
		// 3.6-minute trace of real arrivals (04/10/2026): holding 4 pictures
		// gave 8 drops + 12 repeats per 10 s, 30 gave 2.4 + 6.3 for +3 ms;
		// clocks with a jitter buffer (percentile or worst-case sized) did
		// worse on both counts.
		if (last_slot > 0 && slot - last_slot < 0.5) {
			double next = last_slot + period;
			next -= vblankPhase(next);
			if (slot < next - period / 2) {
				if (next - slot > period * 1.5) {
					// Two or more refreshes behind its earliest: the pictures
					// are queueing up (measured: stuck at 40-48 ms). Drop this
					// one so the queue drains; holding by one refresh is fine.
					// (Dropping whenever a newer picture waited behind made
					// every hold a drop: 20+ per 10 s.)
					stats_slot_dropped++;
					discardSteered();
					return;
				}
				if (++held_run > unsigned(hold_limit.load())) {
					held_run = 0;
					stats_slot_dropped++;
				} else {
					slot = next;
					stats_slot_held++;
				}
			} else {
				held_run = 0;
				if (slot > next + period / 2)
					stats_slot_skipped += unsigned(std::lround((slot - next) / period));
			}
		}
		slot = std::max(slot, earliest(flip)); // cannot go back in time
		last_slot = slot;
		const double wait = std::max(0.0, slot - flip);
		if (wait > 0) {
			const uint64_t target = mach_absolute_time() + secondsToMach(wait);
			mach_wait_until(target);
			const uint64_t late_us = uint64_t(std::max(0.0, machToSeconds(mach_absolute_time()) - machToSeconds(target)) * 1e6);
			stats_wake_late_sum_us += late_us;
			stats_wake_count++;
			maxInto(stats_wake_late_max_us, late_us);
			const uint64_t wait_us = uint64_t(wait * 1e6);
			stats_steer_wait_sum_us += wait_us;
			uint64_t prev = stats_steer_wait_max_us.load();
			while (wait_us > prev && !stats_steer_wait_max_us.compare_exchange_weak(prev, wait_us)) {}
		}
		stats_steered++;
		present_call->store(CACurrentMediaTime());
		// Attached only now: a dropped picture's drawable is never presented.
		[drawable addPresentedHandler:on_shown];
		[drawable present];
	}

	// A steered picture that will never be shown: its drawable goes back
	// unpresented, so give back its place in the present count.
	void discardSteered()
	{
		if (--presents_waiting < 0)
			presents_waiting.store(0);
		std::lock_guard<std::mutex> lock(presented_callback_mutex);
		if (presented_callback)
			presented_callback();
	}

	void onDisplayLink(CAMetalDisplayLinkUpdate *update) API_AVAILABLE(macos(14.0))
	{
        if (display_link_stop.load() || !use_display_link.load()) return;
        bool latch_video;
        double period;
        {
            std::lock_guard<std::mutex> state(state_mutex);
            latch_video = dirty && want_video && video != nullptr;
            period = 1.0 / pacing_policy.preferredFramesPerSecond;
        }
        if (deadline_enabled && vsync_enabled.load() && latch_video) {
            // Não prende encode_mutex/state_mutex: Qt e novos quadros podem chegar
            // enquanto o drawable espera. Só seleciona a imagem depois da espera.
            std::unique_lock<std::mutex> timing(deadline_mutex);
            const double wait = p5m::display::lateLatchWait(CACurrentMediaTime(),
                update.targetTimestamp, period, render_budget.seconds());
            if (wait > 0) {
                const auto began = std::chrono::steady_clock::now();
                deadline_changed.wait_for(timing, std::chrono::duration<double>(wait), [this] {
                    return display_link_stop.load() || !use_display_link.load() || !vsync_enabled.load();
                });
                deadline_waits++;
                deadline_wait_us += std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now() - began).count();
            }
        }
        std::lock_guard<std::mutex> encoding(encode_mutex);
        if (display_link_stop.load() || !use_display_link.load()) return;
		std::shared_ptr<VideoFrame> v;
		bool overlay_on;
		MetalRenderer::Fit fit;
		float zoom;
		id<MTLTexture> ui;
		QSize size;
		{
			std::lock_guard<std::mutex> lock(state_mutex);
			if (!dirty) {
				// Sem novidade, suspende também os callbacks. render() acorda o link.
				display_link.paused = YES;
				return;
			}
			dirty = false;
			v = want_video ? video : nullptr;
			overlay_on = want_overlay;
			fit = want_fit;
			zoom = want_zoom;
			ui = overlay;
			size = pixel_size;
		}
		@autoreleasepool {
			if (!encodeAndPresent(update.drawable, v, overlay_on, fit, zoom, ui, size, update.targetTimestamp)) {
				// Formato antigo ou drawable indisponível: repetir no próximo callback,
				// mesmo que o stream esteja parado e não venha outro quadro.
				std::lock_guard<std::mutex> lock(state_mutex);
				dirty = true;
			}
		}
	}

	void applyDisplayLinkControl() API_AVAILABLE(macos(14.0))
	{
		// Executado somente na thread do próprio display link.
		display_link_control_pending.store(false);
		std::lock_guard<std::mutex> state(state_mutex);
		const auto &policy = pacing_policy;
		const CAFrameRateRange wanted = CAFrameRateRangeMake(
			policy.minimumFramesPerSecond, policy.maximumFramesPerSecond,
			policy.preferredFramesPerSecond);
		const CAFrameRateRange current = display_link.preferredFrameRateRange;
		if (current.minimum != wanted.minimum || current.maximum != wanted.maximum ||
		    current.preferred != wanted.preferred)
			display_link.preferredFrameRateRange = wanted;
		display_link.paused = !(use_display_link.load() && dirty);
	}

	void requestDisplayLinkControl() API_AVAILABLE(macos(14.0))
	{
		std::lock_guard<std::mutex> control(display_link_control_mutex);
		CFRunLoopRef rl = display_link_runloop.load();
		if (!rl || display_link_stop.load() || display_link_control_pending.exchange(true))
			return;
		auto keep_alive = shared_from_this();
		CFRunLoopPerformBlock(rl, kCFRunLoopCommonModes, ^{
			if (!keep_alive->display_link_stop.load())
				keep_alive->applyDisplayLinkControl();
		});
		CFRunLoopWakeUp(rl);
	}

	void startDisplayLink() API_AVAILABLE(macos(14.0))
	{
		display_link_stop.store(false);
		display_link_control_pending.store(false);
		auto keep_alive = shared_from_this();
		display_link_target = [ChiakiDisplayLinkTarget new];
		display_link_target.handler = ^(CAMetalDisplayLinkUpdate *update) { keep_alive->onDisplayLink(update); };
		display_link = [[CAMetalDisplayLink alloc] initWithMetalLayer:layer];
		display_link.delegate = display_link_target;
		display_link.preferredFrameLatency = 1.0f;
		display_link.paused = YES;
		display_link_done = dispatch_semaphore_create(0);
		CAMetalDisplayLink *link = display_link;
		display_link_thread = [[NSThread alloc] initWithBlock:^{
			{
				std::lock_guard<std::mutex> control(keep_alive->display_link_control_mutex);
				keep_alive->display_link_runloop.store(CFRunLoopGetCurrent());
			}
			// Mantém o run loop vivo mesmo com o display link pausado, sem giro vazio.
			CFRunLoopSourceContext context = {};
			CFRunLoopSourceRef idle_source = CFRunLoopSourceCreate(nullptr, 0, &context);
			CFRunLoopAddSource(CFRunLoopGetCurrent(), idle_source, kCFRunLoopCommonModes);
			keep_alive->applyDisplayLinkControl();
			[link addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
			while (!keep_alive->display_link_stop.load()) {
				@autoreleasepool {
					CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
				}
			}
			[link invalidate];
			CFRunLoopRemoveSource(CFRunLoopGetCurrent(), idle_source, kCFRunLoopCommonModes);
			CFRelease(idle_source);
			{
				std::lock_guard<std::mutex> control(keep_alive->display_link_control_mutex);
				keep_alive->display_link_runloop.store(nullptr);
			}
			dispatch_semaphore_signal(keep_alive->display_link_done);
		}];
		display_link_thread.name = @"chiaki-display-link";
		display_link_thread.qualityOfService = NSQualityOfServiceUserInteractive;
		[display_link_thread start];
	}

	bool stopDisplayLink()
	{
		if (!display_link_thread)
			return true;
		display_link_stop.store(true);
        deadline_changed.notify_all();
		{
			std::lock_guard<std::mutex> control(display_link_control_mutex);
			if (CFRunLoopRef rl = display_link_runloop.load())
				CFRunLoopStop(rl);
		}
		// Rompe o ciclo target -> handler -> Impl. Uma chamada em andamento e
		// o bloco da thread mantêm o Impl vivo até retornarem, mesmo se a parada
		// ultrapassar o prazo limitado abaixo.
		display_link.delegate = nil;
		display_link_target.handler = nil;
		const long stopped = dispatch_semaphore_wait(display_link_done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
		if (stopped != 0) {
			qCWarning(chiakiGui) << "Metal renderer: display-link thread exceeded the 2 s stop window; keeping its state alive until exit";
			// A camada ainda pertence ao link: nunca chamar nextDrawable aqui.
			return false;
		}
		display_link = nil;
		display_link_target = nil;
		display_link_thread = nil;
		return true;
	}

	void logFormatOnce(int format, const char *how)
	{
		if (format < 0 || format >= AV_PIX_FMT_NB || logged_formats[format])
			return;
		logged_formats[format] = true;
		const char *name = av_get_pix_fmt_name(static_cast<AVPixelFormat>(format));
		qCInfo(chiakiGui) << "Metal renderer:" << (name ? name : "unknown") << how;
	}

	std::shared_ptr<VideoFrame> wrapVideoToolbox(AVFrame *frame)
	{
		CVPixelBufferRef pb = reinterpret_cast<CVPixelBufferRef>(frame->data[3]);
		if (!pb || CVPixelBufferGetPlaneCount(pb) != 2)
			return nullptr;

		int bits;
		double norm;
		MTLPixelFormat formats[2];
		switch (CVPixelBufferGetPixelFormatType(pb)) {
		case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
		case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
			bits = 8;
			norm = 255.0;
			formats[0] = MTLPixelFormatR8Unorm;
			formats[1] = MTLPixelFormatRG8Unorm;
			break;
		case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
		case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
			// 10 bits in the top of 16-bit words.
			bits = 10;
			norm = 65535.0 / 64.0;
			formats[0] = MTLPixelFormatR16Unorm;
			formats[1] = MTLPixelFormatRG16Unorm;
			break;
		default: {
			const OSType f = CVPixelBufferGetPixelFormatType(pb);
			const char fourcc[5] = { char(f >> 24), char(f >> 16), char(f >> 8), char(f), 0 };
			qCWarning(chiakiGui) << "Metal renderer: unsupported CVPixelBuffer format" << fourcc;
			return nullptr;
		}
		}

		auto v = std::make_shared<VideoFrame>();
		for (int i = 0; i < 2; i++) {
			const size_t w = CVPixelBufferGetWidthOfPlane(pb, i);
			const size_t h = CVPixelBufferGetHeightOfPlane(pb, i);
			if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texture_cache, pb, nil,
			                                              formats[i], w, h, i, &v->cv_tex[i]) != kCVReturnSuccess) {
				qCWarning(chiakiGui) << "Metal renderer: CVMetalTextureCacheCreateTextureFromImage failed for plane" << i;
				return nullptr;
			}
			v->tex[i] = CVMetalTextureGetTexture(v->cv_tex[i]);
		}
		v->tex[2] = v->tex[1];
		fillColorParams(v->params, frame, bits, norm, 2);
		return v;
	}

	// (Re)creates the scaler and its textures for these sizes. False if MetalFX
	// cannot do it, which turns upscaling off for the session.
	bool ensureScaler(const QSize &in, const QSize &out)
	{
		if (fx_scaler && in == fx_in_size && out == fx_out_size)
			return true;
		MTLFXSpatialScalerDescriptor *desc = [MTLFXSpatialScalerDescriptor new];
		desc.inputWidth = in.width();
		desc.inputHeight = in.height();
		desc.outputWidth = out.width();
		desc.outputHeight = out.height();
		desc.colorTextureFormat = MTLPixelFormatRGBA16Float;
		desc.outputTextureFormat = MTLPixelFormatRGBA16Float;
		desc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
		fx_scaler = [desc newSpatialScalerWithDevice:device];
		if (!fx_scaler) {
			fx_scaler_active.store(false);
			qCWarning(chiakiGui) << "Metal renderer: MetalFX spatial scaler unavailable for" << in << "->" << out << ", upscaling off";
			fx_enabled = false;
			return false;
		}
		fx_scaler_active.store(true);

		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
		                                                                              width:in.width()
		                                                                             height:in.height()
		                                                                          mipmapped:NO];
		td.storageMode = MTLStorageModePrivate;
		td.usage = fx_scaler.colorTextureUsage | MTLTextureUsageRenderTarget;
		fx_in = [device newTextureWithDescriptor:td];
		td.width = out.width();
		td.height = out.height();
		td.usage = fx_scaler.outputTextureUsage | MTLTextureUsageShaderRead;
		fx_out = [device newTextureWithDescriptor:td];
		fx_scaler.colorTexture = fx_in;
		fx_scaler.outputTexture = fx_out;
		fx_scaler.inputContentWidth = in.width();
		fx_scaler.inputContentHeight = in.height();

		if (fx_in_size != in || fx_out_size.isEmpty())
			qCInfo(chiakiGui) << "Metal renderer: MetalFX spatial upscaling" << in << "->" << out;
		fx_in_size = in;
		fx_out_size = out;
		return true;
	}

	id<MTLTexture> uploadPlane(const AVFrame *frame, int plane, MTLPixelFormat format, int w, int h)
	{
		MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
		                                                                                width:w
		                                                                               height:h
		                                                                            mipmapped:NO];
		desc.usage = MTLTextureUsageShaderRead;
		desc.storageMode = MTLStorageModeShared;
		id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
		[tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
		       mipmapLevel:0
		         withBytes:frame->data[plane]
		       bytesPerRow:frame->linesize[plane]];
		return tex;
	}

	// Software decode and the startup warmup frame. Not the fast path.
	std::shared_ptr<VideoFrame> uploadSoftware(AVFrame *frame)
	{
		const int w = frame->width, h = frame->height;
		const int cw = (w + 1) / 2, ch = (h + 1) / 2;
		auto v = std::make_shared<VideoFrame>();
		switch (frame->format) {
		case AV_PIX_FMT_YUV420P:
			v->tex[0] = uploadPlane(frame, 0, MTLPixelFormatR8Unorm, w, h);
			v->tex[1] = uploadPlane(frame, 1, MTLPixelFormatR8Unorm, cw, ch);
			v->tex[2] = uploadPlane(frame, 2, MTLPixelFormatR8Unorm, cw, ch);
			fillColorParams(v->params, frame, 8, 255.0, 3);
			break;
		case AV_PIX_FMT_YUV420P10LE:
			v->tex[0] = uploadPlane(frame, 0, MTLPixelFormatR16Unorm, w, h);
			v->tex[1] = uploadPlane(frame, 1, MTLPixelFormatR16Unorm, cw, ch);
			v->tex[2] = uploadPlane(frame, 2, MTLPixelFormatR16Unorm, cw, ch);
			fillColorParams(v->params, frame, 10, 65535.0, 3);
			break;
		case AV_PIX_FMT_NV12:
			v->tex[0] = uploadPlane(frame, 0, MTLPixelFormatR8Unorm, w, h);
			v->tex[1] = uploadPlane(frame, 1, MTLPixelFormatRG8Unorm, cw, ch);
			v->tex[2] = v->tex[1];
			fillColorParams(v->params, frame, 8, 255.0, 2);
			break;
		case AV_PIX_FMT_P010LE:
			v->tex[0] = uploadPlane(frame, 0, MTLPixelFormatR16Unorm, w, h);
			v->tex[1] = uploadPlane(frame, 1, MTLPixelFormatRG16Unorm, cw, ch);
			v->tex[2] = v->tex[1];
			fillColorParams(v->params, frame, 10, 65535.0 / 64.0, 2);
			break;
		default:
			return nullptr;
		}
		if (!v->tex[0] || !v->tex[1] || !v->tex[2])
			return nullptr;
		return v;
	}
};

MetalRenderer::MetalRenderer()
	: d(std::make_shared<Impl>())
{
}

MetalRenderer::~MetalRenderer()
{
	// O callback captura QmlMainWindow. Limpe-o antes que o teardown libere a
	// janela; uma notificação presented tardia fica sem alvo de interface.
	setPresentedCallback({});
	setRefreshCallback({});
	d->stopDisplayLink();
	d->stopVblankClock();
	if (d->queue)
		waitIdle();
	d->stopPresentThread(); // after the GPU: no steered present left to post
}

// Whether the window's screen can show more than SDR white (an XDR panel or
// an HDR monitor). Main thread (AppKit).
static void screenHdrState(QWindow *window, bool &capable, float &headroom)
{
	NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window->winId());
	NSScreen *screen = view.window.screen ?: NSScreen.mainScreen;
	capable = screen && screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0;
	const double available = screen ? screen.maximumExtendedDynamicRangeColorComponentValue : 1.0;
	headroom = std::isfinite(available) ? float(std::max(1.0, available)) : 1.0f;
}

std::unique_ptr<MetalRenderer> MetalRenderer::create(QWindow *window)
{
	std::unique_ptr<MetalRenderer> r(new MetalRenderer());
	Impl *d = r->d.get();
	d->window = window;

	d->device = MTLCreateSystemDefaultDevice();
	if (!d->device) {
		qCCritical(chiakiGui) << "Metal renderer: no Metal device";
		return nullptr;
	}
	d->queue = [d->device newCommandQueue];
	if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, d->device, nil, &d->texture_cache) != kCVReturnSuccess) {
		qCCritical(chiakiGui) << "Metal renderer: CVMetalTextureCacheCreate failed";
		return nullptr;
	}
	if (!d->buildPipelines())
		return nullptr;

	const char *fx_env = std::getenv("CHIAKI_METALFX");
	// Off by default: MetalFX costs ~5 ms of GPU per frame, all of it before the
	// present; the Catmull-Rom enlarge in video_fs costs ~2.4 ms less and looked
	// the same on the 13" panel (04/10/2026).
	const bool fx_wanted = fx_env && fx_env[0] == '1';
	d->fx_enabled = fx_wanted && [MTLFXSpatialScalerDescriptor supportsDevice:d->device];
	qCInfo(chiakiGui) << "Metal renderer: MetalFX spatial upscaling"
	                  << (d->fx_enabled ? "on" : fx_wanted ? "unsupported" : "off (CHIAKI_METALFX=1 turns it on)");

	NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window->winId());
	if (!view) {
		qCCritical(chiakiGui) << "Metal renderer: window has no NSView";
		return nullptr;
	}
	view.wantsLayer = YES;
	// Qt 6 wraps the window's content layer in a container layer; for a
	// MetalSurface window that content layer is a CAMetalLayer. Drawing into
	// it (instead of stacking our own on top) leaves one opaque layer in the
	// tree, which is what lets a fullscreen window go direct to the display.
	CAMetalLayer *qt_metal_layer = nil;
	if ([view.layer isKindOfClass:[CAMetalLayer class]])
		qt_metal_layer = (CAMetalLayer *)view.layer;
	for (CALayer *sub in view.layer.sublayers)
		if (!qt_metal_layer && [sub isKindOfClass:[CAMetalLayer class]])
			qt_metal_layer = (CAMetalLayer *)sub;
	{
		QStringList tree;
		tree << QString::fromUtf8(NSStringFromClass([view.layer class]).UTF8String);
		for (CALayer *sub in view.layer.sublayers)
			tree << QStringLiteral("  ") + QString::fromUtf8(NSStringFromClass([sub class]).UTF8String);
		qCInfo(chiakiGui) << "Metal renderer: view layer tree" << tree;
	}
	const bool own_layer = !qt_metal_layer;
    d->qt_layer = !own_layer;
	if (qt_metal_layer) {
		d->layer = qt_metal_layer;
	} else {
		d->layer = [CAMetalLayer layer];
		d->layer.frame = view.layer.bounds;
		d->layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
		[view.layer addSublayer:d->layer];
	}
	d->layer.device = d->device;
	d->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	d->layer.framebufferOnly = YES;
	d->layer.opaque = YES;
	d->layer.presentsWithTransaction = NO;
	if (const char *q = std::getenv("CHIAKI_METAL_QUEUE"); q && q[0] >= '1' && q[0] <= '2')
		d->max_presents_waiting = q[0] - '0';
	// One drawable on screen plus the ones allowed to wait: nextDrawable
	// never blocks the render thread.
	d->layer.maximumDrawableCount = d->max_presents_waiting + 1;
	d->layer.contentsScale = window->devicePixelRatio();
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	d->layer.colorspace = srgb;
	CGColorSpaceRelease(srgb);

    if (const char *e = std::getenv("CHIAKI_METAL_DEADLINE"); e && e[0] == '1')
        d->deadline_enabled = true;
    qCInfo(chiakiGui) << "Metal renderer: deadline pacing" << d->deadline_enabled
        << "(experimental; CHIAKI_METAL_DEADLINE=1 enables bounded waiting)";
#if P5M_STATE_REPORTING
    if (@available(macOS 27.0, *))
        d->state_reporter = [SRStateReporter reporterForDomain:@"io.github.beecrepaldi-afk.p5m.mac.presentation"];
#endif
	// Tela fixa mantém fila imediata; VRR usa link. Late latch só em opt-in.
	// O link nasce apenas quando necessário: mesmo pausado, ele torna
	// nextDrawable proibido na camada até invalidate() terminar.
	if (const char *dl_env = std::getenv("CHIAKI_METAL_DISPLAYLINK");
	    dl_env && (dl_env[0] == '0' || dl_env[0] == '1'))
		d->display_link_override = dl_env[0] - '0';

	// Sem VSync, apresenta no término da GPU. A espera guiada fica só para
	// comparação explícita: no teste real reduziu60fps para40fps e somou atraso.
	if (const char *e = std::getenv("CHIAKI_TEAR_STEER"); e && e[0] == '1')
		d->steer_enabled = true;
	if (const char *e = std::getenv("CHIAKI_TEAR_OFFSET_US"))
		d->steer_offset = std::atof(e) / 1e6;
	if (d->steer_enabled)
		d->startPresentThread();
	d->startVblankClock();
	// AppKit só na thread principal. A folga muda com brilho, bateria e
	// outras janelas HDR; não basta consultá-la ao trocar de monitor.
	auto refresh_hdr = [weak = std::weak_ptr<Impl>(r->d), window]() {
		if (auto impl = weak.lock()) {
			bool capable;
			float headroom;
			screenHdrState(window, capable, headroom);
			NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window->winId());
			NSScreen *screen = view.window.screen ?: [NSScreen mainScreen];
			bool refresh_needed = false;
			auto policy = p5m::display::decidePacing(screen.minimumRefreshInterval,
				screen.maximumRefreshInterval, screen.maximumFramesPerSecond,
				impl->source_fps.load(), impl->vsync_enabled.load(), impl->display_link_override);
			{
				std::lock_guard<std::mutex> state(impl->state_mutex);
				// VSync pode ter mudado durante a consulta de AppKit acima.
				policy.useDisplayLink = p5m::display::useLinkForFrame(policy.variableRefresh,
                    impl->vsync_enabled.load(), impl->display_link_override, impl->deadline_enabled,
                    impl->want_video && impl->video != nullptr);
				if (impl->pacing_policy.useDisplayLink != policy.useDisplayLink ||
				    impl->pacing_policy.minimumFramesPerSecond != policy.minimumFramesPerSecond ||
				    impl->pacing_policy.maximumFramesPerSecond != policy.maximumFramesPerSecond) {
					qCInfo(chiakiGui) << "Metal renderer: display pacing"
						<< (policy.useDisplayLink ? "CAMetalDisplayLink" : "present queue")
						<< "variable refresh" << policy.variableRefresh
						<< "range" << policy.minimumFramesPerSecond << policy.maximumFramesPerSecond;
					impl->dirty = true;
					refresh_needed = true;
				}
				impl->pacing_policy = policy;
			}
			impl->variable_refresh.store(policy.variableRefresh);
			const bool previous_capable = impl->hdr_capable.exchange(capable);
			const float previous = impl->hdr_headroom.exchange(headroom);
			if (previous_capable != capable || std::abs(previous - headroom) > 0.01f) {
				std::lock_guard<std::mutex> lock(impl->state_mutex);
				impl->dirty = true;
				refresh_needed = impl->hdr_wanted.load() || refresh_needed;
			}
			std::function<void()> refresh;
			{
				std::lock_guard<std::mutex> state(impl->state_mutex);
				refresh = impl->refresh_callback;
			}
            bool streaming;
            { std::lock_guard<std::mutex> state(impl->state_mutex);
              streaming = impl->want_video && impl->video != nullptr; }
            NSWindow *native = view.window;
            const bool visible = native.visible && (native.occlusionState & NSWindowOcclusionStateVisible);
            const bool native_fullscreen = native.styleMask & NSWindowStyleMaskFullScreen;
            const bool borderless = native.styleMask == NSWindowStyleMaskBorderless;
            const bool covers_view = NSEqualRects(NSRectFromCGRect(impl->layer.frame), view.bounds);
            NSDictionary *state = @{
                @"streaming": @(streaming), @"visible": @(visible),
                @"hdr": @(impl->hdr_active.load()),
                @"pixelFormat": impl->hdr_active.load() ? @"RGBA16Float" : @"BGRA8Unorm",
                @"vsync": @(impl->vsync_enabled.load()),
                @"displayLink": @(impl->use_display_link.load()),
                @"nativeFullscreen": @(native_fullscreen), @"borderless": @(borderless),
                @"windowOpaque": @(native.opaque), @"layerOpaque": @(impl->layer.opaque),
                @"layerCoversView": @(covers_view), @"qtLayer": @(impl->qt_layer)
            };
            if (![state isEqualToDictionary:impl->last_window_state]) {
                impl->last_window_state = state;
                qCInfo(chiakiGui) << "[presentation-state] prerequisites only; composition unverified;"
                    << "streaming" << streaming << "visible" << visible
                    << "HDR" << impl->hdr_active.load() << "VSync" << impl->vsync_enabled.load()
                    << "displayLink" << impl->use_display_link.load()
                    << "native fullscreen" << native_fullscreen << "borderless" << borderless
                    << "opaque window/layer" << bool(native.opaque) << bool(impl->layer.opaque)
                    << "layer covers view" << covers_view << "Qt layer" << impl->qt_layer;
#if P5M_STATE_REPORTING
                if (@available(macOS 27.0, *))
                    [impl->state_reporter reportTransitionToStateLabel:(!visible ? @"Hidden" : streaming ? @"Streaming" : @"Menu")
                        stableMetadata:state volatileMetadata:nil];
#endif
            }
			if (refresh_needed && refresh)
				refresh();
			if (@available(macOS 14.0, *))
				impl->requestDisplayLinkControl();
			if (impl->hdr_wanted.load() && std::abs(previous - headroom) > 0.05f)
				qCInfo(chiakiGui) << "Metal renderer: linear EDR headroom" << headroom;
		}
	};
	refresh_hdr();
	qCInfo(chiakiGui) << "Metal renderer: automatic display pacing; manual override"
	                  << d->display_link_override;
	qCInfo(chiakiGui) << "Metal renderer: screen HDR (EDR) capable" << d->hdr_capable.load();
	QObject::connect(window, &QWindow::screenChanged, window,
	                 [weak = std::weak_ptr<Impl>(r->d), refresh_hdr](QScreen *) {
		                 if (auto impl = weak.lock())
			                 impl->selectVblankDisplay();
		                 refresh_hdr();
	                 });
	auto *hdr_timer = new QTimer(window);
	hdr_timer->setInterval(1000);
	QObject::connect(hdr_timer, &QTimer::timeout, window, refresh_hdr);
	hdr_timer->start();
	qCInfo(chiakiGui) << "Metal renderer: steered tearing without VSync"
	                  << (!d->steer_enabled ? "off (immediate presentation; CHIAKI_TEAR_STEER=1 to compare)" : d->cv_link_available.load() ? "on" : "unavailable")
	                  << "offset" << d->steer_offset * 1e6 << "us";

	qCInfo(chiakiGui) << "Metal renderer on" << d->device.name.UTF8String
	                  << "layer" << (own_layer ? "own sublayer" : "Qt's CAMetalLayer");
	return r;
}

QQuickGraphicsDevice MetalRenderer::graphicsDevice() const
{
	return QQuickGraphicsDevice::fromDeviceAndCommandQueue((MTLDevice *)d->device, (MTLCommandQueue *)d->queue);
}

bool MetalRenderer::resize(const QSize &pixel_size)
{
	std::lock_guard<std::mutex> encoding(d->encode_mutex);
	if (pixel_size.isEmpty())
		return false;
	if (pixel_size == d->pixel_size && d->overlay)
		return false;

    { std::lock_guard<std::mutex> timing(d->deadline_mutex); d->render_budget.reset(); }
	d->layer.contentsScale = d->window->devicePixelRatio();
	d->layer.drawableSize = CGSizeMake(pixel_size.width(), pixel_size.height());

	MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                                width:pixel_size.width()
	                                                                               height:pixel_size.height()
	                                                                            mipmapped:NO];
	desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	desc.storageMode = MTLStorageModePrivate;
	id<MTLTexture> ui = [d->device newTextureWithDescriptor:desc];
	std::lock_guard<std::mutex> lock(d->state_mutex);
	d->pixel_size = pixel_size;
	d->overlay = ui;
	return true;
}

bool MetalRenderer::hasOverlay() const
{
	return d->overlay != nil;
}

QQuickRenderTarget MetalRenderer::overlayRenderTarget() const
{
	return QQuickRenderTarget::fromMetalTexture((MTLTexture *)d->overlay, MTLPixelFormatBGRA8Unorm, d->pixel_size);
}

QSize MetalRenderer::pixelSize() const
{
	return d->pixel_size;
}

void MetalRenderer::setHoldLimit(int pictures)
{
	d->hold_limit.store(qMax(1, pictures));
}

void MetalRenderer::setHiddenTop(int pixels)
{
	d->hidden_top.store(qMax(0, pixels));
}

void MetalRenderer::setHdr(bool enabled)
{
	if (d->hdr_wanted.exchange(enabled) != enabled) {
		std::lock_guard<std::mutex> lock(d->state_mutex);
		d->dirty = true;
	}
}

void MetalRenderer::setRefreshCallback(std::function<void()> callback)
{
	std::lock_guard<std::mutex> state(d->state_mutex);
	d->refresh_callback = std::move(callback);
}

void MetalRenderer::setSourceFrameRate(double fps)
{
	if (std::isfinite(fps) && fps > 0.0)
		d->source_fps.store(fps);
}

void MetalRenderer::setVSync(bool enabled)
{
	std::lock_guard<std::mutex> encoding(d->encode_mutex);
	d->vsync_enabled.store(enabled);
    d->deadline_changed.notify_all();
	d->layer.displaySyncEnabled = enabled ? YES : NO;
	{
		std::lock_guard<std::mutex> state(d->state_mutex);
		d->pacing_policy.useDisplayLink = p5m::display::useLinkForFrame(d->pacing_policy.variableRefresh,
            enabled, d->display_link_override, d->deadline_enabled, d->want_video && d->video != nullptr);
		d->dirty = true;
	}
}

bool MetalRenderer::presentSlotFree(bool count_deferred)
{
	if (d->use_display_link)
		return true;
	if (d->presents_waiting.load() < d->max_presents_waiting)
		return true;
	// A present that never reports (window hidden, display asleep) must not
	// stall the video for good.
	if (Impl::nowUs() - d->last_submit_us.load() > 100000) {
		d->presents_waiting.store(0);
		return true;
	}
	if (count_deferred) {
		std::lock_guard<std::mutex> lock(d->stats_mutex);
		d->stats_deferred++;
	}
	return false;
}

void MetalRenderer::setPresentedCallback(std::function<void()> callback)
{
	std::lock_guard<std::mutex> lock(d->presented_callback_mutex);
	d->presented_callback = std::move(callback);
}

bool MetalRenderer::setVideoFrame(AVFrame *frame)
{
	if (!frame)
		return false;
	std::shared_ptr<VideoFrame> v;
	if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
		d->logFormatOnce(frame->format, "frames sampled directly (zero-copy)");
		v = d->wrapVideoToolbox(frame);
	} else {
		d->logFormatOnce(frame->format, "frames uploaded from system memory");
		v = d->uploadSoftware(frame);
	}
	if (!v) {
		d->logFormatOnce(frame->format, "frames not supported, dropping");
		av_frame_free(&frame);
		return false;
	}
	d->noteFrame();
	v->frame = frame;
	v->width = frame->width;
	v->height = frame->height;
	if (frame->sample_aspect_ratio.num > 0 && frame->sample_aspect_ratio.den > 0)
		v->sar = av_q2d(frame->sample_aspect_ratio);
	v->arrival = CACurrentMediaTime();
	std::lock_guard<std::mutex> lock(d->state_mutex);
	v->presentation_id = ++d->next_video_id;
	d->video = std::move(v);
	return true;
}

void MetalRenderer::clearVideo()
{
	{
		std::lock_guard<std::mutex> lock(d->state_mutex);
		d->video.reset();
		d->dirty = true;
	}
	if (d->texture_cache)
		CVMetalTextureCacheFlush(d->texture_cache, 0);
}

bool MetalRenderer::hasVideoFrame() const
{
	std::lock_guard<std::mutex> lock(d->state_mutex);
	return d->video != nullptr;
}

bool MetalRenderer::render(bool draw_video, bool draw_overlay, Fit fit, float zoom_factor)
{
	bool use_link;
	{
		std::lock_guard<std::mutex> state(d->state_mutex);
		use_link = p5m::display::useLinkForFrame(d->pacing_policy.variableRefresh,
            d->vsync_enabled.load(), d->display_link_override, d->deadline_enabled,
            draw_video && d->video != nullptr);
        d->pacing_policy.useDisplayLink = use_link;
		if (d->pacing_policy.variableRefresh)
			d->pacing_policy.preferredFramesPerSecond = std::clamp(d->source_fps.load(),
				d->pacing_policy.minimumFramesPerSecond, d->pacing_policy.maximumFramesPerSecond);
	}
	// Parar fora de encode_mutex: um callback já em andamento precisa sair
	// antes de invalidate devolver a camada à apresentação direta.
	if ((!use_link || d->display_link_stop.load()) && d->display_link_thread) {
		d->use_display_link.store(false);
		if (!d->stopDisplayLink())
			return false;
	}
	std::lock_guard<std::mutex> encoding(d->encode_mutex);
	if (@available(macOS 14.0, *)) {
		if (use_link && !d->display_link_thread) {
			d->use_display_link.store(true);
			d->startDisplayLink();
		}
		d->requestDisplayLinkControl();
	}
	if (d->use_display_link) {
		// The display link draws at the right moment; just say what to draw.
		std::lock_guard<std::mutex> lock(d->state_mutex);
		if (d->pixel_size.isEmpty())
			return false;
		d->want_video = draw_video;
		d->want_overlay = draw_overlay;
		d->want_fit = fit;
		d->want_zoom = zoom_factor;
		d->dirty = true;
		if (@available(macOS 14.0, *))
			d->requestDisplayLinkControl();
		return true;
	}

	std::shared_ptr<VideoFrame> video;
	id<MTLTexture> ui;
	QSize size;
	{
		std::lock_guard<std::mutex> lock(d->state_mutex);
		video = draw_video ? d->video : nullptr;
		ui = d->overlay;
		size = d->pixel_size;
	}
	@autoreleasepool {
		return d->encodeAndPresent(nil, video, draw_overlay, fit, zoom_factor, ui, size);
	}
}

void MetalRenderer::waitIdle()
{
	id<MTLCommandBuffer> cmd = [d->queue commandBuffer];
	[cmd commit];
	[cmd waitUntilCompleted];
}
