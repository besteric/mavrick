//
//  OpusBridge.h
//  Mavrick
//
//  Thin C wrapper around libopus for clean Swift interop
//

#ifndef OpusBridge_h
#define OpusBridge_h

#include <stdint.h>
#include <stddef.h>

/// Opaque handle for the Opus decoder state.
typedef struct OpusDecoderBridge OpusDecoderBridge;

/// Create a decoder for the given sample rate and channel count. Returns NULL on failure.
OpusDecoderBridge *opus_bridge_create(int sample_rate, int channels);

/// Decode one Opus packet into PCM int16 samples. Returns the number of decoded
/// samples (per channel), or a negative value on error. The caller must provide
/// pcm_out with at least 5760 * channels * sizeof(int16_t) bytes.
int opus_bridge_decode(OpusDecoderBridge *decoder,
                       const uint8_t *packet, int packet_len,
                       int16_t *pcm_out, int max_samples);

/// Reset decoder state (call when starting a new voice session).
void opus_bridge_reset(OpusDecoderBridge *decoder);

/// Destroy the decoder and free resources.
void opus_bridge_destroy(OpusDecoderBridge *decoder);

#endif /* OpusBridge_h */
