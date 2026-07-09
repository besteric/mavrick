//
//  VoicePacketParser.swift
//  Mavrick
//
//  Parses PacketLogger hex dump output to extract Siri Remote voice frames.
//
//  PacketLogger output format (each line ~93 chars = 31 bytes × 3):
//    ... 40 20 ... B8 <len> <opus_data> ...
//
//  Voice session markers (in the BLE notification data):
//    Start: ends with "1B 23 00 00 10"
//    End:   ends with "1B 23 00 10 00"
//

import Foundation

/// Callbacks for voice session events and decoded audio.
protocol VoicePacketParserDelegate: AnyObject {
    func voiceSessionStarted()
    func voiceSessionEnded()
    func voicePacketReceived(_ opusData: Data)
}

final class VoicePacketParser {
    weak var delegate: VoicePacketParserDelegate?

    private var isVoiceActive = false
    private var currentFrame = ""

    /// Feed one line of PacketLogger hex dump output.
    func feedLine(_ line: String) {
        // Only process RECV lines for the target device
        guard line.contains("RECV") else { return }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Voice start marker
        if trimmed.hasSuffix("1B 23 00 00 10") {
            isVoiceActive = true
            currentFrame = ""
            delegate?.voiceSessionStarted()
            return
        }

        // Voice end marker
        if trimmed.hasSuffix("1B 23 00 10 00") {
            // Flush any remaining frame
            flushFrame()
            isVoiceActive = false
            delegate?.voiceSessionEnded()
            return
        }

        guard isVoiceActive else { return }

        // Extract hex bytes from the data portion (starts at column 54)
        guard trimmed.count > 54 else { return }
        let dataStr = String(trimmed.dropFirst(54))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !dataStr.isEmpty else { return }

        // Each full line is 31 bytes (93 chars = 31 × 3, minus trailing space = 92)
        let isFullLine = dataStr.count >= 92

        if isFullLine {
            // Check if this is a frame header: starts with "40 20" and contains "B8" at position 54
            if dataStr.hasPrefix("40 20") {
                let b8Index = dataStr.index(dataStr.startIndex, offsetBy: 54)
                if dataStr[b8Index...].hasPrefix("B8") {
                    // New frame header — flush previous, start new
                    flushFrame()
                    // Frame starts 3 chars before B8 (the length byte + space)
                    let startIdx = dataStr.index(b8Index, offsetBy: -3)
                    currentFrame = String(dataStr[startIdx...])
                } else {
                    // Continuation line
                    currentFrame += " " + String(dataStr.dropFirst(4 * 3))
                }
            } else {
                // Continuation line
                currentFrame += " " + String(dataStr.dropFirst(4 * 3))
            }
        } else {
            // Short line (last line of a BLE notification)
            currentFrame += " " + dataStr
        }
    }

    private func flushFrame() {
        guard !currentFrame.isEmpty else { return }
        let hexStr = currentFrame.replacingOccurrences(of: " ", with: "")

        // First byte is packet length
        guard hexStr.count >= 2 else {
            currentFrame = ""
            return
        }

        let packetLenHex = String(hexStr.prefix(2))
        guard let packetLen = UInt8(packetLenHex, radix: 16) else {
            currentFrame = ""
            return
        }

        // Extract Opus data (after the length byte)
        let opusHex = String(hexStr.dropFirst(2))
        guard opusHex.count >= Int(packetLen) * 2 else {
            currentFrame = ""
            return
        }

        let opusData = Data(hexString: String(opusHex.prefix(Int(packetLen) * 2)))
        if !opusData.isEmpty {
            delegate?.voicePacketReceived(opusData)
        }

        currentFrame = ""
    }

    var active: Bool { isVoiceActive }
}

// MARK: - Hex string → Data

extension Data {
    init(hexString: String) {
        let len = hexString.count / 2
        var bytes = [UInt8](repeating: 0, count: len)
        var i = 0
        var idx = hexString.startIndex
        while i < len {
            let byteStr = hexString[idx..<hexString.index(idx, offsetBy: 2)]
            bytes[i] = UInt8(byteStr, radix: 16) ?? 0
            i += 1
            idx = hexString.index(idx, offsetBy: 2)
        }
        self.init(bytes)
    }
}
