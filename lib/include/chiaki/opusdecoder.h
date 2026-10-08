// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_OPUSDECODER_H
#define CHIAKI_OPUSDECODER_H

#include <chiaki/config.h>
#if CHIAKI_LIB_ENABLE_OPUS

#include "audioreceiver.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*ChiakiOpusDecoderSettingsCallback)(uint32_t channels, uint32_t rate, void *user);
typedef void (*ChiakiOpusDecoderFrameCallback)(int16_t *buf, size_t samples_count, void *user);

typedef struct chiaki_opus_decoder_t
{
	ChiakiLog *log;
	struct OpusDecoder *opus_decoder;
	struct OpusMSDecoder *ms_decoder; // P5M: multicanal (5.1/7.1), criado no primeiro pacote
	bool ms_pending;
	// P5M: medição por canal no multicanal, para descobrir a ordem (LFE = só graves).
	double ch_sum_sq[12];
	double ch_lf_sum_sq[12];
	double ch_lp[12];
	uint64_t ch_samples;
	ChiakiAudioHeader audio_header;
	int16_t *pcm_buf;
	size_t pcm_buf_size;

	ChiakiOpusDecoderSettingsCallback settings_cb;
	ChiakiOpusDecoderFrameCallback frame_cb;
	void *cb_user;
} ChiakiOpusDecoder;

CHIAKI_EXPORT void chiaki_opus_decoder_init(ChiakiOpusDecoder *decoder, ChiakiLog *log);
CHIAKI_EXPORT void chiaki_opus_decoder_fini(ChiakiOpusDecoder *decoder);
CHIAKI_EXPORT void chiaki_opus_decoder_get_sink(ChiakiOpusDecoder *decoder, ChiakiAudioSink *sink);

static inline void chiaki_opus_decoder_set_cb(ChiakiOpusDecoder *decoder, ChiakiOpusDecoderSettingsCallback settings_cb, ChiakiOpusDecoderFrameCallback frame_cb, void *user)
{
	decoder->settings_cb = settings_cb;
	decoder->frame_cb = frame_cb;
	decoder->cb_user = user;
}

#ifdef __cplusplus
}
#endif

#endif

#endif // CHIAKI_OPUSDECODER_H
