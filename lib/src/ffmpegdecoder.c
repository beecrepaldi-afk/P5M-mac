
#include <chiaki/ffmpegdecoder.h>
#include <chiaki/time.h>
#include <libavcodec/avcodec.h>
#include <libavutil/pixdesc.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
// P5M: decode with VideoToolbox directly, in real-time mode, instead of
// through ffmpeg's hwaccel. Same output (a CVPixelBuffer in an AVFrame with a
// VideoToolbox frames context), so the rest of the app does not change.
#include <VideoToolbox/VideoToolbox.h>
#include <libavutil/hwcontext.h>

typedef struct
{
	bool hevc, hdr;
	VTDecompressionSessionRef session;
	CMVideoFormatDescriptionRef fmt;
	uint8_t ps[3][1024];   // HEVC: VPS SPS PPS; H.264: -, SPS, PPS
	size_t ps_size[3];
	bool ps_dirty;
	CVPixelBufferRef out;
	OSStatus out_status;
	AVBufferRef *frames_ctx;
	int frames_w, frames_h;
	AVFrame *pending;
	uint8_t *sample;
	size_t sample_cap;
	unsigned errors;
} VtDirect;

static void vt_direct_out_cb(void *user, void *source_frame, OSStatus status, VTDecodeInfoFlags flags,
		CVImageBufferRef image, CMTime pts, CMTime duration)
{
	(void)source_frame; (void)flags; (void)pts; (void)duration;
	VtDirect *vt = user;
	vt->out_status = status;
	if(status == noErr && image)
	{
		if(vt->out)
			CVPixelBufferRelease(vt->out);
		vt->out = CVPixelBufferRetain(image);
	}
}

static void vt_direct_free_session(VtDirect *vt)
{
	if(vt->session)
	{
		VTDecompressionSessionInvalidate(vt->session);
		CFRelease(vt->session);
		vt->session = NULL;
	}
}

static void vt_direct_free(VtDirect *vt)
{
	if(!vt)
		return;
	vt_direct_free_session(vt);
	if(vt->fmt)
		CFRelease(vt->fmt);
	if(vt->out)
		CVPixelBufferRelease(vt->out);
	av_buffer_unref(&vt->frames_ctx);
	av_frame_free(&vt->pending);
	free(vt->sample);
	free(vt);
}

static void cf_dict_set_int(CFMutableDictionaryRef d, CFStringRef key, int32_t v)
{
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
	CFDictionarySetValue(d, key, n);
	CFRelease(n);
}

static bool vt_direct_make_session(VtDirect *vt, ChiakiLog *log)
{
	const uint8_t *ptrs[3];
	size_t sizes[3];
	CMVideoFormatDescriptionRef fmt = NULL;
	OSStatus st;
	if(vt->hevc)
	{
		for(int i = 0; i < 3; i++) { ptrs[i] = vt->ps[i]; sizes[i] = vt->ps_size[i]; }
		st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, 3, ptrs, sizes, 4, NULL, &fmt);
	}
	else
	{
		for(int i = 0; i < 2; i++) { ptrs[i] = vt->ps[i + 1]; sizes[i] = vt->ps_size[i + 1]; }
		st = CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, ptrs, sizes, 4, &fmt);
	}
	if(st != noErr || !fmt)
	{
		CHIAKI_LOGE(log, "VT direct: format description failed (%d)", (int)st);
		return false;
	}
	if(vt->session && VTDecompressionSessionCanAcceptFormatDescription(vt->session, fmt))
	{
		if(vt->fmt)
			CFRelease(vt->fmt);
		vt->fmt = fmt;
		return true;
	}
	vt_direct_free_session(vt);
	if(vt->fmt)
		CFRelease(vt->fmt);
	vt->fmt = fmt;

	CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(spec, kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder, kCFBooleanTrue);
	CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	cf_dict_set_int(attrs, kCVPixelBufferPixelFormatTypeKey,
			vt->hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
	CFDictionarySetValue(attrs, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);
	CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, empty);
	CFRelease(empty);

	VTDecompressionOutputCallbackRecord cb = { vt_direct_out_cb, vt };
	st = VTDecompressionSessionCreate(NULL, fmt, spec, attrs, &cb, &vt->session);
	CFRelease(spec);
	CFRelease(attrs);
	if(st != noErr)
	{
		CHIAKI_LOGE(log, "VT direct: session creation failed (%d)", (int)st);
		vt->session = NULL;
		return false;
	}
	VTSessionSetProperty(vt->session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
	CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fmt);
	CHIAKI_LOGI(log, "VT direct: decoding %s %dx%d with VideoToolbox (real-time, no ffmpeg)",
			vt->hevc ? "HEVC" : "H.264", (int)dim.width, (int)dim.height);
	return true;
}

static const uint8_t *vt_direct_next_start(const uint8_t *p, const uint8_t *end, size_t *sc_len)
{
	for(; p + 3 <= end; p++)
	{
		if(p[0] == 0 && p[1] == 0)
		{
			if(p[2] == 1) { *sc_len = 3; return p; }
			if(p + 4 <= end && p[2] == 0 && p[3] == 1) { *sc_len = 4; return p; }
		}
	}
	*sc_len = 0;
	return end;
}

// Aumenta o buffer sem deixar a capacidade ultrapassar SIZE_MAX.
static bool vt_direct_reserve_sample(VtDirect *vt, size_t required)
{
	if(required <= vt->sample_cap)
		return true;
	size_t capacity = vt->sample_cap ? vt->sample_cap : 4096;
	while(capacity < required)
	{
		if(capacity > SIZE_MAX / 2)
		{
			capacity = required;
			break;
		}
		capacity *= 2;
	}
	uint8_t *sample = realloc(vt->sample, capacity);
	if(!sample)
		return false;
	vt->sample = sample;
	vt->sample_cap = capacity;
	return true;
}

static void vt_direct_release_pb(void *opaque, uint8_t *data)
{
	(void)opaque;
	CVPixelBufferRelease((CVPixelBufferRef)data);
}

static void vt_direct_color(AVFrame *f, CVPixelBufferRef pb, bool hdr)
{
	f->color_range = AVCOL_RANGE_MPEG;
	f->colorspace = hdr ? AVCOL_SPC_BT2020_NCL : AVCOL_SPC_BT709;
	f->color_primaries = hdr ? AVCOL_PRI_BT2020 : AVCOL_PRI_BT709;
	f->color_trc = hdr ? AVCOL_TRC_SMPTE2084 : AVCOL_TRC_BT709;
	CFTypeRef v = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, NULL);
	if(v)
	{
		if(CFEqual(v, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) f->colorspace = AVCOL_SPC_SMPTE170M;
		else if(CFEqual(v, kCVImageBufferYCbCrMatrix_ITU_R_2020)) f->colorspace = AVCOL_SPC_BT2020_NCL;
		else if(CFEqual(v, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) f->colorspace = AVCOL_SPC_BT709;
		CFRelease(v);
	}
	v = CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, NULL);
	if(v)
	{
		if(CFEqual(v, kCVImageBufferColorPrimaries_ITU_R_2020)) f->color_primaries = AVCOL_PRI_BT2020;
		else if(CFEqual(v, kCVImageBufferColorPrimaries_SMPTE_C)) f->color_primaries = AVCOL_PRI_SMPTE170M;
		else if(CFEqual(v, kCVImageBufferColorPrimaries_ITU_R_709_2)) f->color_primaries = AVCOL_PRI_BT709;
		CFRelease(v);
	}
	v = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, NULL);
	if(v)
	{
		if(CFEqual(v, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)) f->color_trc = AVCOL_TRC_SMPTE2084;
		else if(CFEqual(v, kCVImageBufferTransferFunction_ITU_R_2100_HLG)) f->color_trc = AVCOL_TRC_ARIB_STD_B67;
		else if(CFEqual(v, kCVImageBufferTransferFunction_ITU_R_709_2)) f->color_trc = AVCOL_TRC_BT709;
		CFRelease(v);
	}
}

// Decodes one access unit (Annex B). True when it went through (a picture
// may or may not come out: parameter-set-only units give none).
static bool vt_direct_decode(ChiakiFfmpegDecoder *decoder, VtDirect *vt, const uint8_t *buf, size_t size,
		int64_t pts, int64_t duration)
{
	size_t used = 0;
	const uint8_t *end = buf + size;
	size_t sc;
	const uint8_t *p = vt_direct_next_start(buf, end, &sc);
	while(p < end)
	{
		const uint8_t *nal = p + sc;
		size_t sc_next;
		const uint8_t *next = vt_direct_next_start(nal, end, &sc_next);
		size_t len = (size_t)(next - nal);
		while(len > 0 && nal[len - 1] == 0 && next < end) // trailing zeros of the next start code
			len--;
		if(len > 0)
		{
			int slot = -1;
			bool skip = false;
			if(vt->hevc)
			{
				int type = (nal[0] >> 1) & 0x3f;
				if(type >= 32 && type <= 34) slot = type - 32;
				else if(type == 35) skip = true; // access unit delimiter
			}
			else
			{
				int type = nal[0] & 0x1f;
				if(type == 7) slot = 1;
				else if(type == 8) slot = 2;
				else if(type == 9) skip = true;
			}
			if(slot >= 0)
			{
				if(len <= sizeof(vt->ps[slot]) && (vt->ps_size[slot] != len || memcmp(vt->ps[slot], nal, len) != 0))
				{
					memcpy(vt->ps[slot], nal, len);
					vt->ps_size[slot] = len;
					vt->ps_dirty = true;
				}
			}
			else if(!skip)
			{
				if(len > UINT32_MAX || used > SIZE_MAX - 4 || len > SIZE_MAX - used - 4)
				{
					CHIAKI_LOGE(decoder->log, "VT direct: sample size exceeds the 32-bit length prefix or size_t");
					return false;
				}
				if(!vt_direct_reserve_sample(vt, used + 4 + len))
				{
					CHIAKI_LOGE(decoder->log, "VT direct: sample buffer allocation failed");
					return false;
				}
				vt->sample[used++] = (uint8_t)(len >> 24);
				vt->sample[used++] = (uint8_t)(len >> 16);
				vt->sample[used++] = (uint8_t)(len >> 8);
				vt->sample[used++] = (uint8_t)len;
				memcpy(vt->sample + used, nal, len);
				used += len;
			}
		}
		p = next;
		sc = sc_next;
	}

	if(vt->ps_dirty)
	{
		bool have = vt->ps_size[1] && vt->ps_size[2] && (!vt->hevc || vt->ps_size[0]);
		if(have)
		{
			if(!vt_direct_make_session(vt, decoder->log))
				return false;
			vt->ps_dirty = false;
		}
	}
	if(!used || !vt->session)
		return true;

	CMBlockBufferRef block = NULL;
	CMSampleBufferRef sample = NULL;
	OSStatus st = CMBlockBufferCreateWithMemoryBlock(NULL, vt->sample, used, kCFAllocatorNull, NULL, 0, used, 0, &block);
	if(st == noErr)
		st = CMSampleBufferCreateReady(NULL, block, vt->fmt, 1, 0, NULL, 1, &used, &sample);
	if(st != noErr)
	{
		if(block)
			CFRelease(block);
		return false;
	}
	vt->out_status = noErr;
	VTDecodeInfoFlags info = 0;
	st = VTDecompressionSessionDecodeFrame(vt->session, sample, 0, NULL, &info);
	CFRelease(sample);
	CFRelease(block);
	if(st != noErr || vt->out_status != noErr)
	{
		if(vt->errors++ < 5)
			CHIAKI_LOGW(decoder->log, "VT direct: frame not decoded (%d / %d)", (int)st, (int)vt->out_status);
		if(st == kVTInvalidSessionErr)
		{
			vt_direct_free_session(vt);
			vt->ps_dirty = true;
		}
		return false;
	}
	// A successful decode may legitimately produce no image for this access
	// unit (for example, while the decoder is still reordering pictures).
	if(!vt->out)
		return true;

	CVPixelBufferRef pb = vt->out;
	vt->out = NULL;
	const int w = (int)CVPixelBufferGetWidth(pb), h = (int)CVPixelBufferGetHeight(pb);
	if(!vt->frames_ctx || vt->frames_w != w || vt->frames_h != h)
	{
		av_buffer_unref(&vt->frames_ctx);
		AVBufferRef *ctx = av_hwframe_ctx_alloc(decoder->hw_device_ctx);
		if(ctx)
		{
			AVHWFramesContext *fc = (AVHWFramesContext *)ctx->data;
			fc->format = AV_PIX_FMT_VIDEOTOOLBOX;
			fc->sw_format = vt->hdr ? AV_PIX_FMT_P010 : AV_PIX_FMT_NV12;
			fc->width = w;
			fc->height = h;
			if(av_hwframe_ctx_init(ctx) < 0)
				av_buffer_unref(&ctx);
		}
		vt->frames_ctx = ctx;
		vt->frames_w = w;
		vt->frames_h = h;
	}
	AVFrame *f = av_frame_alloc();
	if(!f || !vt->frames_ctx)
	{
		av_frame_free(&f);
		CVPixelBufferRelease(pb);
		return false;
	}
	f->format = AV_PIX_FMT_VIDEOTOOLBOX;
	f->width = w;
	f->height = h;
	f->data[3] = (uint8_t *)pb;
	f->buf[0] = av_buffer_create((uint8_t *)pb, 1, vt_direct_release_pb, NULL, 0);
	if(!f->buf[0])
	{
		CVPixelBufferRelease(pb);
		av_frame_free(&f);
		return false;
	}
	f->hw_frames_ctx = av_buffer_ref(vt->frames_ctx);
	if(!f->hw_frames_ctx)
	{
		av_frame_free(&f);
		return false;
	}
	f->pts = pts;
	f->best_effort_timestamp = pts;
	f->duration = duration;
	f->sample_aspect_ratio = (AVRational){ 1, 1 };
	vt_direct_color(f, pb, vt->hdr);
	av_frame_free(&vt->pending);
	vt->pending = f;
	return true;
}
#endif

static enum AVCodecID chiaki_codec_av_codec_id(ChiakiCodec codec)
{
	switch(codec)
	{
		case CHIAKI_CODEC_H265:
		case CHIAKI_CODEC_H265_HDR:
			return AV_CODEC_ID_H265;
		default:
			return AV_CODEC_ID_H264;
	}
}

static double chiaki_ffmpeg_decoder_default_frame_duration_us(unsigned int max_fps)
{
	double fps = max_fps > 0 ? (double)max_fps : 60.0;
	if(fps <= 0.0)
		fps = 60.0;
	return 1000000.0 / fps;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_ffmpeg_decoder_init(ChiakiFfmpegDecoder *decoder, ChiakiLog *log,
		ChiakiCodec codec, unsigned int max_fps, const char *hw_decoder_name, AVBufferRef *hw_device_ctx,
		ChiakiFfmpegFrameAvailable frame_available_cb, void *frame_available_cb_user)
{
	ChiakiErrorCode err = chiaki_mutex_init(&decoder->mutex, false);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	chiaki_mutex_lock(&decoder->mutex);
	decoder->log = log;
	decoder->frame_available_cb = frame_available_cb;
	decoder->frame_available_cb_user = frame_available_cb_user;
	decoder->hdr_enabled = codec == CHIAKI_CODEC_H265_HDR;
	decoder->frames_lost = 0;
	decoder->frame_recovered = false;
	decoder->synthetic_packet_pts = 0;
	decoder->synthetic_framerate = (AVRational){max_fps > 0 ? (int)max_fps : 60, 1};
	decoder->synthetic_time_base = (AVRational){1, 1000000};
	decoder->synthetic_frame_duration_us = chiaki_ffmpeg_decoder_default_frame_duration_us(max_fps);
	decoder->synthetic_candidate_duration_us = decoder->synthetic_frame_duration_us;
	decoder->synthetic_last_sample_time_us = 0;
	decoder->synthetic_candidate_count = 0;

	decoder->hw_device_ctx = hw_device_ctx ? av_buffer_ref(hw_device_ctx) : NULL;
	decoder->hw_pix_fmt = AV_PIX_FMT_NONE;

#if LIBAVCODEC_VERSION_INT < AV_VERSION_INT(58, 10, 100)
	avcodec_register_all();
#endif
	enum AVCodecID av_codec = chiaki_codec_av_codec_id(codec);
	decoder->av_codec = avcodec_find_decoder(av_codec);
	if(!decoder->av_codec)
	{
		CHIAKI_LOGE(log, "%s Codec not available", chiaki_codec_name(codec));
		goto error_mutex;
	}

	decoder->codec_context = avcodec_alloc_context3(decoder->av_codec);
	if(!decoder->codec_context)
	{
		CHIAKI_LOGE(log, "Failed to alloc codec context");
		goto error_mutex;
	}

	if(hw_decoder_name)
	{
		CHIAKI_LOGI(log, "Trying to use hardware decoder \"%s\"", hw_decoder_name);
		enum AVHWDeviceType type = av_hwdevice_find_type_by_name(hw_decoder_name);
		if(type == AV_HWDEVICE_TYPE_NONE)
		{
			CHIAKI_LOGE(log, "Hardware decoder \"%s\" not found", hw_decoder_name);
			goto error_codec_context;
		}

		for(int i = 0;; i++)
		{
			const AVCodecHWConfig *config = avcodec_get_hw_config(decoder->av_codec, i);
			if(!config)
			{
				CHIAKI_LOGE(log, "avcodec_get_hw_config failed");
				goto error_codec_context;
			}
			if(config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX && config->device_type == type)
			{
				decoder->hw_pix_fmt = config->pix_fmt;
				break;
			}
		}

		if(!decoder->hw_device_ctx && av_hwdevice_ctx_create(&decoder->hw_device_ctx, type, NULL, NULL, 0) < 0)
		{
			CHIAKI_LOGE(log, "Failed to create hwdevice context");
			goto error_codec_context;
		}
		decoder->codec_context->hw_device_ctx = av_buffer_ref(decoder->hw_device_ctx);
		CHIAKI_LOGI(log, "Using hardware decoder \"%s\" with pix_fmt=%s", hw_decoder_name, av_get_pix_fmt_name(decoder->hw_pix_fmt));
	}

	// The stream has no B-frames: output each picture as soon as it decodes.
	decoder->codec_context->flags |= AV_CODEC_FLAG_LOW_DELAY;
	decoder->codec_context->framerate = decoder->synthetic_framerate;
	decoder->codec_context->pkt_timebase = decoder->synthetic_time_base;
	decoder->codec_context->time_base = decoder->synthetic_time_base;

	if(avcodec_open2(decoder->codec_context, decoder->av_codec, NULL) < 0)
	{
		CHIAKI_LOGE(log, "Failed to open codec context");
		goto error_codec_context;
	}
	decoder->vt_direct = NULL;
#ifdef __APPLE__
	{
		const char *env = getenv("CHIAKI_VT_DIRECT");
		// On by default: 2.6x faster than ffmpeg's hwaccel in the offline
		// bench (0.78 vs 2.03 ms per 1080p frame, same pictures).
		// CHIAKI_VT_DIRECT=0 goes back to ffmpeg.
		if(!(env && env[0] == '0') && decoder->hw_device_ctx && hw_decoder_name && strcmp(hw_decoder_name, "videotoolbox") == 0)
		{
			VtDirect *vt = calloc(1, sizeof(VtDirect));
			if(vt)
			{
				vt->hevc = av_codec == AV_CODEC_ID_H265;
				vt->hdr = decoder->hdr_enabled;
				decoder->vt_direct = vt;
				CHIAKI_LOGI(log, "VT direct: on (CHIAKI_VT_DIRECT=0 turns it off)");
			}
		}
	}
#endif
	chiaki_mutex_unlock(&decoder->mutex);
	return CHIAKI_ERR_SUCCESS;
error_codec_context:
	if(decoder->hw_device_ctx)
		av_buffer_unref(&decoder->hw_device_ctx);
	avcodec_free_context(&decoder->codec_context);
error_mutex:
	chiaki_mutex_unlock(&decoder->mutex);
	chiaki_mutex_fini(&decoder->mutex);
	return CHIAKI_ERR_UNKNOWN;
}

CHIAKI_EXPORT void chiaki_ffmpeg_decoder_fini(ChiakiFfmpegDecoder *decoder)
{
	chiaki_mutex_lock(&decoder->mutex);
#ifdef __APPLE__
	vt_direct_free(decoder->vt_direct);
	decoder->vt_direct = NULL;
#endif
	avcodec_free_context(&decoder->codec_context);
	if(decoder->hw_device_ctx)
		av_buffer_unref(&decoder->hw_device_ctx);
	chiaki_mutex_unlock(&decoder->mutex);
	chiaki_mutex_fini(&decoder->mutex);
}

CHIAKI_EXPORT bool chiaki_ffmpeg_decoder_video_sample_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	ChiakiFfmpegDecoder *decoder = user;

	chiaki_mutex_lock(&decoder->mutex);
	decoder->frames_lost += frames_lost;
	decoder->frame_recovered = frame_recovered;
	if(decoder->synthetic_last_sample_time_us)
	{
		double observed_duration_us = (double)(chiaki_time_now_monotonic_us() - decoder->synthetic_last_sample_time_us);
		int64_t delivered_frames = (int64_t)frames_lost + 1;
		double default_duration_us = chiaki_ffmpeg_decoder_default_frame_duration_us((unsigned int)decoder->synthetic_framerate.num);
		if(delivered_frames > 1)
			observed_duration_us /= (double)delivered_frames;
		if(observed_duration_us < default_duration_us)
			observed_duration_us = default_duration_us;
		else if(observed_duration_us > 1000000.0 / 15.0)
			observed_duration_us = 1000000.0 / 15.0;

		double candidate_diff = decoder->synthetic_candidate_duration_us > 0.0
			? fabs(observed_duration_us - decoder->synthetic_candidate_duration_us) / decoder->synthetic_candidate_duration_us
			: 1.0;
		double current_diff = decoder->synthetic_frame_duration_us > 0.0
			? fabs(observed_duration_us - decoder->synthetic_frame_duration_us) / decoder->synthetic_frame_duration_us
			: 1.0;
		if(current_diff >= 0.20)
		{
			if(candidate_diff <= 0.10)
				decoder->synthetic_candidate_count++;
			else
			{
				decoder->synthetic_candidate_duration_us = observed_duration_us;
				decoder->synthetic_candidate_count = 1;
			}
			if(decoder->synthetic_candidate_count >= 3)
			{
				decoder->synthetic_frame_duration_us = decoder->synthetic_candidate_duration_us;
				decoder->synthetic_candidate_count = 0;
			}
		}
		else
		{
			decoder->synthetic_candidate_duration_us = decoder->synthetic_frame_duration_us;
			decoder->synthetic_candidate_count = 0;
		}
	}
	decoder->synthetic_last_sample_time_us = chiaki_time_now_monotonic_us();

	int64_t synthetic_duration_pts = (int64_t)(decoder->synthetic_frame_duration_us + 0.5);
	if(synthetic_duration_pts < 1)
		synthetic_duration_pts = 1;
	if(frames_lost > 0)
		decoder->synthetic_packet_pts += synthetic_duration_pts * (int64_t)frames_lost;

#ifdef __APPLE__
	if(decoder->vt_direct)
	{
		uint64_t start_us = chiaki_time_now_monotonic_us();
		bool ok = vt_direct_decode(decoder, decoder->vt_direct, buf, buf_size, decoder->synthetic_packet_pts, synthetic_duration_pts);
		decoder->synthetic_packet_pts += synthetic_duration_pts;
		{
			static uint64_t window_start_us = 0, sum_us = 0, max_us = 0;
			static unsigned count = 0;
			uint64_t now = chiaki_time_now_monotonic_us();
			uint64_t took = now - start_us;
			sum_us += took;
			if(took > max_us)
				max_us = took;
			count++;
			if(!window_start_us)
				window_start_us = now;
			if(now - window_start_us >= 10000000)
			{
				CHIAKI_LOGI(decoder->log, "[decode] 10s (VT direct): %u packets, avg %.2f ms, max %.1f ms, errors %u",
						count, sum_us / 1000.0 / count, max_us / 1000.0, ((VtDirect *)decoder->vt_direct)->errors);
				window_start_us = now;
				sum_us = max_us = 0;
				count = 0;
			}
		}
		chiaki_mutex_unlock(&decoder->mutex);
		if(ok)
			decoder->frame_available_cb(decoder, decoder->frame_available_cb_user);
		return ok;
	}
#endif
	AVPacket *packet = av_packet_alloc();
	packet->data = buf;
	packet->size = buf_size;
	packet->pts = decoder->synthetic_packet_pts;
	packet->dts = decoder->synthetic_packet_pts;
	packet->duration = synthetic_duration_pts;
#if LIBAVCODEC_VERSION_INT >= AV_VERSION_INT(59, 8, 100)
	packet->time_base = decoder->synthetic_time_base;
#endif
	decoder->synthetic_packet_pts += synthetic_duration_pts;
	int r;
	uint64_t decode_start_us = chiaki_time_now_monotonic_us();
send_packet:
	r = avcodec_send_packet(decoder->codec_context, packet);
	if(r != 0)
	{
		if(r == AVERROR(EAGAIN))
		{
			CHIAKI_LOGW(decoder->log, "AVCodec internal buffer is full, dropping a decoded frame to push new packet");
			AVFrame *frame = av_frame_alloc();
			if(!frame)
			{
				CHIAKI_LOGE(decoder->log, "Failed to alloc AVFrame");
				goto hell;
			}
			r = avcodec_receive_frame(decoder->codec_context, frame);
			av_frame_free(&frame);
			if(r != 0)
			{
				CHIAKI_LOGE(decoder->log, "Failed to pull frame from full codec buffer");
				goto hell;
			}
			decoder->frames_lost++;
			goto send_packet;
		}
		else
		{
			char errbuf[128];
			av_make_error_string(errbuf, sizeof(errbuf), r);
			CHIAKI_LOGE(decoder->log, "Failed to push frame: %s", errbuf);
			goto hell;
		}
	}
	av_packet_free(&packet);
	{
		// Decode diary, one line every 10 s (VideoToolbox decodes inside send).
		static uint64_t window_start_us = 0, sum_us = 0, max_us = 0;
		static unsigned count = 0, over_8ms = 0;
		uint64_t now = chiaki_time_now_monotonic_us();
		uint64_t took = now - decode_start_us;
		sum_us += took;
		if(took > max_us)
			max_us = took;
		over_8ms += took > 8000;
		count++;
		if(!window_start_us)
			window_start_us = now;
		if(now - window_start_us >= 10000000)
		{
			CHIAKI_LOGI(decoder->log, "[decode] 10s: %u packets, avg %.2f ms, max %.1f ms, >8ms %u",
					count, sum_us / 1000.0 / count, max_us / 1000.0, over_8ms);
			window_start_us = now;
			sum_us = max_us = 0;
			count = over_8ms = 0;
		}
	}
	chiaki_mutex_unlock(&decoder->mutex);
	decoder->frame_available_cb(decoder, decoder->frame_available_cb_user);
	return true;
hell:
	av_packet_free(&packet);
	chiaki_mutex_unlock(&decoder->mutex);
	return false;
}

CHIAKI_EXPORT ChiakiFfmpegFrame chiaki_ffmpeg_decoder_pull_frame(ChiakiFfmpegDecoder *decoder, int32_t *frames_lost)
{
	chiaki_mutex_lock(&decoder->mutex);
	double synthetic_duration = decoder->synthetic_frame_duration_us / 1000000.0;
	// always try to pull as much as possible and return only the very last frame
	AVFrame *frame_last = NULL;
	AVFrame *frame = NULL;
#ifdef __APPLE__
	if(decoder->vt_direct)
	{
		frame = ((VtDirect *)decoder->vt_direct)->pending;
		((VtDirect *)decoder->vt_direct)->pending = NULL;
	}
	else
#endif
	while(true)
	{
		AVFrame *next_frame;
		if(frame_last)
		{
			av_frame_unref(frame_last);
			next_frame = frame_last;
		}
		else
		{
			next_frame = av_frame_alloc();
			if(!next_frame)
				break;
		}
		frame_last = frame;
		frame = next_frame;
		int r = avcodec_receive_frame(decoder->codec_context, frame);
		if(r)
		{
			if(r != AVERROR(EAGAIN))
				CHIAKI_LOGE(decoder->log, "Decoding with FFMPEG failed");
			av_frame_free(&frame);
			frame = frame_last;
			break;
		}
	}
	*frames_lost = decoder->frames_lost;
	bool recovered = false;
	if(frame && decoder->frame_recovered)
	{
		recovered = true;
		decoder->frame_recovered = false;
		frame->decode_error_flags |= 1;
	}
	decoder->frames_lost = 0;
	AVRational pkt_timebase = decoder->codec_context->pkt_timebase;
	AVRational ctx_timebase = decoder->codec_context->time_base;
	AVRational framerate = decoder->codec_context->framerate;
	chiaki_mutex_unlock(&decoder->mutex);

	ChiakiFfmpegFrame frame_plus_stats = {};
	frame_plus_stats.frame = frame;
	frame_plus_stats.recovered = recovered;
	if(frame)
	{
		chiaki_ffmpeg_frame_get_timing(
			frame,
			pkt_timebase,
			ctx_timebase,
			framerate,
			&frame_plus_stats.pts,
			&frame_plus_stats.duration);
		if(frame->duration <= 0)
			frame_plus_stats.duration = synthetic_duration;
	}

	return frame_plus_stats;
}

CHIAKI_EXPORT void chiaki_ffmpeg_frame_get_timing(
	AVFrame *frame,
	AVRational pkt_timebase,
	AVRational ctx_timebase,
	AVRational framerate,
	double *out_pts,
	double *out_duration)
{
	AVRational time_base = pkt_timebase;
	if(time_base.num <= 0 || time_base.den <= 0)
		time_base = ctx_timebase;
	if(time_base.num <= 0 || time_base.den <= 0)
		time_base = (AVRational){1, 1000000};

	int64_t best_effort_pts = frame->best_effort_timestamp;
	int64_t raw_pts = frame->pts;
	int64_t pts = best_effort_pts;
	if(pts == AV_NOPTS_VALUE)
		pts = raw_pts;
	if(pts == AV_NOPTS_VALUE)
		pts = 0;
	*out_pts = av_q2d(time_base) * (double)pts;

	if(frame->duration > 0)
	{
		*out_duration = av_q2d(time_base) * (double)frame->duration;
		return;
	}

	double fps = (framerate.num > 0 && framerate.den > 0) ? av_q2d(framerate) : 60.0;
	if(fps <= 0.0)
		fps = 60.0;
	*out_duration = 1.0 / fps;
}

CHIAKI_EXPORT enum AVPixelFormat chiaki_ffmpeg_decoder_get_pixel_format(ChiakiFfmpegDecoder *decoder)
{
	if (decoder->hw_device_ctx) {
		return decoder->hdr_enabled
			? AV_PIX_FMT_P010LE
			: AV_PIX_FMT_NV12;
	} else {
		return decoder->hdr_enabled
			? AV_PIX_FMT_YUV420P10LE
			: AV_PIX_FMT_YUV420P;
	}
}
