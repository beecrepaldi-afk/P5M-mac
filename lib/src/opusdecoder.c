// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include <chiaki/config.h>
#if CHIAKI_LIB_ENABLE_OPUS

#include <chiaki/opusdecoder.h>

#include <opus/opus.h>
#include <opus/opus_multistream.h>

#include <string.h>
#include <math.h>
#include <stdio.h>

static void chiaki_opus_decoder_header(ChiakiAudioHeader *header, void *user);
static void chiaki_opus_decoder_frame(uint8_t *buf, size_t buf_size, void *user);

CHIAKI_EXPORT void chiaki_opus_decoder_init(ChiakiOpusDecoder *decoder, ChiakiLog *log)
{
	decoder->log = log;
	decoder->opus_decoder = NULL;
	decoder->ms_decoder = NULL;
	decoder->ms_pending = false;
	memset(&decoder->audio_header, 0, sizeof(decoder->audio_header));

	decoder->pcm_buf = NULL;
	decoder->pcm_buf_size = 0;

	decoder->cb_user = NULL;
	decoder->settings_cb = NULL;
	decoder->frame_cb = NULL;
}

CHIAKI_EXPORT void chiaki_opus_decoder_fini(ChiakiOpusDecoder *decoder)
{
	free(decoder->pcm_buf);
	if(decoder->opus_decoder)
		opus_decoder_destroy(decoder->opus_decoder);
	if(decoder->ms_decoder)
		opus_multistream_decoder_destroy(decoder->ms_decoder);
}

// P5M: lê o tamanho de um quadro Opus (RFC 6716, 3.2.1).
static bool p5m_opus_frame_len(const uint8_t **p, const uint8_t *end, size_t *len)
{
	if(*p >= end)
		return false;
	if(**p < 252)
	{
		*len = **p;
		*p += 1;
		return true;
	}
	if(*p + 1 >= end)
		return false;
	*len = (size_t)(*p)[0] + 4 * (size_t)(*p)[1];
	*p += 2;
	return true;
}

// P5M: confere se o pacote multistream tem `streams` streams, as `coupled` primeiras
// em estéreo. As streams antes da última vêm no formato autodelimitado (RFC 6716,
// apêndice B). Só os códigos 0 e 1, que são o que o PS5 manda a taxa constante.
static bool p5m_opus_ms_layout_fits(const uint8_t *buf, size_t size, int streams, int coupled)
{
	const uint8_t *p = buf, *end = buf + size;
	for(int i = 0; i < streams; i++)
	{
		if(p >= end)
			return false;
		uint8_t toc = *p++;
		bool stereo = (toc & 0x4) != 0;
		if(stereo != (i < coupled))
			return false;
		if(i == streams - 1)
			return true;
		size_t len;
		if(!p5m_opus_frame_len(&p, end, &len))
			return false;
		switch(toc & 3)
		{
			case 0: break;
			case 1: len *= 2; break;
			default: return false;
		}
		if(len > (size_t)(end - p))
			return false;
		p += len;
	}
	return false;
}

// P5M: a cada 10 s, volume de cada canal e quanto dele está abaixo de ~150 Hz.
// O LFE fica perto de 100% de graves; o centro concentra os diálogos.
static void p5m_channel_stats(ChiakiOpusDecoder *decoder, const int16_t *pcm, int samples)
{
	unsigned channels = decoder->audio_header.channels;
	if(channels > 12)
		channels = 12;
	const double a = 0.98055; // passa-baixa de um polo em ~150 Hz a 48 kHz
	for(int i = 0; i < samples; i++)
	{
		for(unsigned c = 0; c < channels; c++)
		{
			double x = (double)pcm[(size_t)i * decoder->audio_header.channels + c] / 32768.0;
			decoder->ch_lp[c] = a * decoder->ch_lp[c] + (1.0 - a) * x;
			decoder->ch_sum_sq[c] += x * x;
			decoder->ch_lf_sum_sq[c] += decoder->ch_lp[c] * decoder->ch_lp[c];
		}
	}
	decoder->ch_samples += (uint64_t)samples;
	if(decoder->ch_samples < (uint64_t)decoder->audio_header.rate * 10)
		return;

	char line[512];
	size_t w = 0;
	for(unsigned c = 0; c < channels && w < sizeof(line); c++)
	{
		double rms = sqrt(decoder->ch_sum_sq[c] / (double)decoder->ch_samples);
		double db = rms > 1e-9 ? 20.0 * log10(rms) : -180.0;
		double lf = decoder->ch_sum_sq[c] > 0.0 ? 100.0 * decoder->ch_lf_sum_sq[c] / decoder->ch_sum_sq[c] : 0.0;
		int r = snprintf(line + w, sizeof(line) - w, "%sch%u %.1f dB (lows %.0f%%)", c ? ", " : "", c, db, lf);
		if(r < 0)
			break;
		w += (size_t)r;
	}
	CHIAKI_LOGI(decoder->log, "[audio-channels] 10s levels: %s", line);
	memset(decoder->ch_sum_sq, 0, sizeof(decoder->ch_sum_sq));
	memset(decoder->ch_lf_sum_sq, 0, sizeof(decoder->ch_lf_sum_sq));
	decoder->ch_samples = 0;
}

static void p5m_opus_ms_create(ChiakiOpusDecoder *decoder, const uint8_t *buf, size_t size)
{
	decoder->ms_pending = false;
	int channels = (int)decoder->audio_header.channels;
	int coupled = -1;
	for(int c = channels / 2; c >= 0; c--)
	{
		if(p5m_opus_ms_layout_fits(buf, size, channels - c, c))
		{
			coupled = c;
			break;
		}
	}
	if(coupled < 0)
	{
		CHIAKI_LOGE(decoder->log, "[audio-channels] could not work out the Opus multistream layout for %d channels", channels);
		return;
	}
	// O app oficial usa o mapeamento identidade: pares estéreo primeiro, depois mono.
	unsigned char mapping[255];
	for(int i = 0; i < channels; i++)
		mapping[i] = (unsigned char)i;
	int error;
	decoder->ms_decoder = opus_multistream_decoder_create((opus_int32)decoder->audio_header.rate, channels,
		channels - coupled, coupled, mapping, &error);
	if(error != OPUS_OK)
	{
		CHIAKI_LOGE(decoder->log, "[audio-channels] opus_multistream_decoder_create failed: %s", opus_strerror(error));
		decoder->ms_decoder = NULL;
		return;
	}
	CHIAKI_LOGI(decoder->log, "[audio-channels] Opus multistream decoder: %d channels, %d streams, %d coupled",
		channels, channels - coupled, coupled);
}

CHIAKI_EXPORT void chiaki_opus_decoder_get_sink(ChiakiOpusDecoder *decoder, ChiakiAudioSink *sink)
{
	sink->user = decoder;
	sink->header_cb = chiaki_opus_decoder_header;
	sink->frame_cb = chiaki_opus_decoder_frame;
}

static void chiaki_opus_decoder_header(ChiakiAudioHeader *header, void *user)
{
	ChiakiOpusDecoder *decoder = user;
	memcpy(&decoder->audio_header, header, sizeof(decoder->audio_header));

	opus_decoder_destroy(decoder->opus_decoder);
	decoder->opus_decoder = NULL;
	if(decoder->ms_decoder)
		opus_multistream_decoder_destroy(decoder->ms_decoder);
	decoder->ms_decoder = NULL;
	decoder->ms_pending = false;
	memset(decoder->ch_sum_sq, 0, sizeof(decoder->ch_sum_sq));
	memset(decoder->ch_lf_sum_sq, 0, sizeof(decoder->ch_lf_sum_sq));
	memset(decoder->ch_lp, 0, sizeof(decoder->ch_lp));
	decoder->ch_samples = 0;

	if(header->channels > 2)
	{
		// P5M: as streams só são conhecidas no primeiro pacote.
		decoder->ms_pending = true;
		CHIAKI_LOGI(decoder->log, "ChiakiOpusDecoder waiting for the first %u-channel packet", (unsigned)header->channels);
	}
	else
	{
		int error;
		decoder->opus_decoder = opus_decoder_create(header->rate, header->channels, &error);

		if(error != OPUS_OK)
		{
			CHIAKI_LOGE(decoder->log, "ChiakiOpusDecoder failed to initialize opus decoder: %s", opus_strerror(error));
			decoder->opus_decoder = NULL;
			return;
		}

		CHIAKI_LOGI(decoder->log, "ChiakiOpusDecoder initialized: %u channels at %u Hz (PCM input preserved)", (unsigned)header->channels, (unsigned)header->rate);
	}

	size_t pcm_buf_size_required = chiaki_audio_header_frame_buf_size(header);
	int16_t *pcm_buf_old = decoder->pcm_buf;
	if(!decoder->pcm_buf || decoder->pcm_buf_size != pcm_buf_size_required)
		decoder->pcm_buf = realloc(decoder->pcm_buf, pcm_buf_size_required);

	if(!decoder->pcm_buf)
	{
		free(pcm_buf_old);
		decoder->pcm_buf = NULL;
		CHIAKI_LOGE(decoder->log, "ChiakiOpusDecoder failed to alloc pcm buffer");
		opus_decoder_destroy(decoder->opus_decoder);
		decoder->opus_decoder = NULL;
		decoder->ms_pending = false;
		decoder->pcm_buf_size = 0;
		return;
	}

	decoder->pcm_buf_size = pcm_buf_size_required;

	if(decoder->settings_cb)
		decoder->settings_cb(header->channels, header->rate, decoder->cb_user);
}

static void chiaki_opus_decoder_frame(uint8_t *buf, size_t buf_size, void *user)
{
	ChiakiOpusDecoder *decoder = user;
	if(decoder->ms_pending && buf_size)
		p5m_opus_ms_create(decoder, buf, buf_size);
	if(!decoder->opus_decoder && !decoder->ms_decoder)
	{
		// A falha do cabeçalho já informa o motivo; não repetir por pacote.
		return;
	}

	const unsigned char *opus_buf = buf_size ? buf : NULL;
	int r = decoder->ms_decoder
		? opus_multistream_decode(decoder->ms_decoder, opus_buf, (opus_int32)buf_size, decoder->pcm_buf, (int)decoder->audio_header.frame_size, 0)
		: opus_decode(decoder->opus_decoder, opus_buf, (opus_int32)buf_size, decoder->pcm_buf, decoder->audio_header.frame_size, 0);
	if(r < 1)
		CHIAKI_LOGE(decoder->log, "Decoding audio frame with opus failed: %s", opus_strerror(r));
	else if(decoder->ms_decoder)
		p5m_channel_stats(decoder, decoder->pcm_buf, r);
	if(r >= 1 && decoder->frame_cb)
		decoder->frame_cb(decoder->pcm_buf, (size_t)r, decoder->cb_user);
}

#endif
