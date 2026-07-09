//
//  OpusDecoder.swift
//  Mavrick
//
//  Swift wrapper around the OpusBridge C layer for decoding Siri Remote voice.
//

import Foundation

enum OpusDecoderError: Error {
    case createFailed
    case decodeFailed
    case notInitialized
}

final class OpusDecoder {
    private var bridge: OpaquePointer?
    private let maxFrameSize = 5760  // 120ms @ 48kHz

    init(sampleRate: Int32 = 16000, channels: Int32 = 1) {
        guard let b = opus_bridge_create(sampleRate, channels) else {
            return
        }
        self.bridge = b
    }

    /// Decode a single Opus packet → PCM Int16 samples.
    func decode(packet: Data) throws -> Data {
        guard let bridge = bridge else {
            throw OpusDecoderError.notInitialized
        }
        let sampleCount = maxFrameSize * 1  // mono
        var pcm = [Int16](repeating: 0, count: sampleCount)

        let frameSize = packet.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int32 in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return opus_bridge_decode(bridge, ptr, Int32(buf.count), &pcm, Int32(sampleCount))
        }

        if frameSize < 0 {
            throw OpusDecoderError.decodeFailed
        }

        let validSamples = Int(frameSize)
        let validBytes = validSamples * MemoryLayout<Int16>.size
        return Data(bytes: &pcm, count: validBytes)
    }

    func reset() {
        guard let bridge = bridge else { return }
        opus_bridge_reset(bridge)
    }

    deinit {
        guard let bridge = bridge else { return }
        opus_bridge_destroy(bridge)
    }
}
