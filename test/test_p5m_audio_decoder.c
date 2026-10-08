// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
#include <chiaki/opusdecoder.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(condition) do { if(!(condition)) { fprintf(stderr, "Check failed at line %d: %s\n", __LINE__, #condition); exit(1); } } while(0)

typedef struct {
    unsigned settings_calls;
    unsigned frame_calls;
    uint32_t channels;
    uint32_t rate;
} CallbackState;

static void settings_cb(uint32_t channels, uint32_t rate, void *user)
{
    CallbackState *state = user;
    state->settings_calls++;
    state->channels = channels;
    state->rate = rate;
}

static void frame_cb(int16_t *pcm, size_t samples, void *user)
{
    CallbackState *state = user;
    CHECK(pcm != NULL);
    CHECK(samples == 480);
    state->frame_calls++;
}

static void valid_header(ChiakiOpusDecoder *decoder, ChiakiAudioSink *sink,
                         CallbackState *state, uint8_t channels)
{
    ChiakiAudioHeader header;
    chiaki_audio_header_set(&header, channels, 16, 48000, 480);
    const unsigned previous_settings = state->settings_calls;
    sink->header_cb(&header, sink->user);
    CHECK(decoder->opus_decoder != NULL);
    CHECK(state->settings_calls == previous_settings + 1);
    CHECK(state->channels == channels && state->rate == 48000);
    CHECK(decoder->pcm_buf_size == (size_t)channels * 480 * sizeof(int16_t));
    // PLC gera PCM sintético sem rede nem dispositivo de áudio.
    const unsigned previous_frames = state->frame_calls;
    sink->frame_cb(NULL, 0, sink->user);
    CHECK(state->frame_calls == previous_frames + 1);
}

int main(void)
{
    ChiakiLog log;
    chiaki_log_init(&log, 0, NULL, NULL);
    ChiakiOpusDecoder decoder;
    ChiakiAudioSink sink;
    CallbackState state = {0};
    chiaki_opus_decoder_init(&decoder, &log);
    chiaki_opus_decoder_set_cb(&decoder, settings_cb, frame_cb, &state);
    chiaki_opus_decoder_get_sink(&decoder, &sink);

    valid_header(&decoder, &sink, &state, 1);
    valid_header(&decoder, &sink, &state, 2);
    const uint8_t invalid_channels[] = {0, 6, 8};
    for(size_t i = 0; i < sizeof(invalid_channels); i++)
    {
        ChiakiAudioHeader header;
        chiaki_audio_header_set(&header, invalid_channels[i], 16, 48000, 480);
        const unsigned previous_settings = state.settings_calls;
        const unsigned previous_frames = state.frame_calls;
        sink.header_cb(&header, sink.user);
        CHECK(decoder.opus_decoder == NULL);
        CHECK(state.settings_calls == previous_settings);
        sink.frame_cb(NULL, 0, sink.user);
        CHECK(state.frame_calls == previous_frames);
        // Um cabeçalho recusado não deve inutilizar a próxima sessão estéreo.
        valid_header(&decoder, &sink, &state, 2);
    }
    CHECK(state.settings_calls == 5 && state.frame_calls == 5);
    chiaki_opus_decoder_fini(&decoder);
    puts("Audio decoder header rejection and stereo recovery passed.");
    return 0;
}
