//
//  OpusBridge.c
//  Mavrick
//
//  Thin C wrapper around libopus for clean Swift interop.
//  Uses the system/homebrew libopus.
//

#include "OpusBridge.h"
#include <opus/opus.h>
#include <stdlib.h>

struct OpusDecoderBridge {
    OpusDecoder *decoder;
    int sample_rate;
    int channels;
};

OpusDecoderBridge *opus_bridge_create(int sample_rate, int channels) {
    int err = 0;
    OpusDecoder *dec = opus_decoder_create(sample_rate, channels, &err);
    if (err != OPUS_OK || dec == NULL) {
        return NULL;
    }
    OpusDecoderBridge *bridge = malloc(sizeof(OpusDecoderBridge));
    bridge->decoder = dec;
    bridge->sample_rate = sample_rate;
    bridge->channels = channels;
    return bridge;
}

int opus_bridge_decode(OpusDecoderBridge *bridge,
                       const uint8_t *packet, int packet_len,
                       int16_t *pcm_out, int max_samples) {
    if (bridge == NULL || bridge->decoder == NULL) return -1;
    return opus_decode(bridge->decoder, packet, packet_len,
                       pcm_out, max_samples, 0);
}

void opus_bridge_reset(OpusDecoderBridge *bridge) {
    if (bridge && bridge->decoder) {
        opus_decoder_ctl(bridge->decoder, OPUS_RESET_STATE);
    }
}

void opus_bridge_destroy(OpusDecoderBridge *bridge) {
    if (bridge) {
        if (bridge->decoder) {
            opus_decoder_destroy(bridge->decoder);
        }
        free(bridge);
    }
}
