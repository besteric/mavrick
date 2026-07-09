//
//  SiriRemoteVoiceCapture.swift
//  Mavrick
//
//  Manages the full Siri Remote voice capture pipeline:
//    PacketLogger hex dump → BLE parser → Opus decoder → WAV output
//
//  Prerequisites:
//    - PacketLogger.app (from Xcode Additional Tools)
//    - brew install opus
//
//  Usage:
//    1. Open PacketLogger.app, select your Siri Remote, start capture
//    2. In Mavrick menu: Start Voice Capture (starts monitoring the log)
//    3. Press and hold Siri button, speak
//    4. Stop Voice Capture — decoded WAV written to /tmp/
//

import Foundation

final class SiriRemoteVoiceCapture: VoicePacketParserDelegate {

    // MARK: - State

    private let opusDecoder: OpusDecoder
    private let parser = VoicePacketParser()
    private var decodedAudio = Data()

    private(set) var isCapturing = false

    /// Remote MAC address string (e.g. "AA:BB:CC:DD:EE:FF")
    var remoteMAC: String?

    /// Called when a decoded WAV file is ready.
    var onWavReady: ((URL) -> Void)?
    var onVoiceStateChange: ((Bool) -> Void)?

    /// File handle for reading PacketLogger log in real-time.
    private var logFileHandle: FileHandle?
    private var logMonitorSource: DispatchSourceRead?

    // MARK: - Init

    init() {
        opusDecoder = OpusDecoder(sampleRate: 16000, channels: 1)
        parser.delegate = self
    }

    // MARK: - Public API

    /// Start monitoring a log file for voice data.
    /// Reads existing content first (for pre-saved logs), then monitors for new data.
    func startCapture(from logPath: String = "/tmp/packetlogger.log") {
        guard !isCapturing else { return }
        resetDecodedAudio()

        // Read existing file content first (for pre-saved PacketLogger dumps)
        if FileManager.default.fileExists(atPath: logPath),
           let existing = try? String(contentsOfFile: logPath, encoding: .utf8) {
            for line in existing.components(separatedBy: "\n") {
                guard !line.isEmpty else { continue }
                processLine(line)
            }
            // Clear file after reading, so we don't re-process on next capture
            try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
            print("📄 Processed existing log (\(existing.count) bytes)")
        } else {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }

        guard let fh = FileHandle(forReadingAtPath: logPath) else {
            print("❌ Cannot open log file: \(logPath)")
            return
        }

        logFileHandle = fh

        let source = DispatchSource.makeReadSource(fileDescriptor: fh.fileDescriptor,
                                                    queue: DispatchQueue(label: "com.mavrick.voicelog"))
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let data = fh.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                for line in str.components(separatedBy: "\n") {
                    guard !line.isEmpty else { continue }
                    self.processLine(line)
                }
            }
        }
        source.setCancelHandler {
            try? fh.close()
        }
        source.resume()
        logMonitorSource = source
        isCapturing = true

        print("🎤 Voice capture monitoring: \(logPath)")
        print("💡 In PacketLogger: select remote → start capture → hold Siri button & speak")
    }

    /// Stop monitoring and write WAV file.
    func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false

        logMonitorSource?.cancel()
        logMonitorSource = nil
        logFileHandle = nil

        if !decodedAudio.isEmpty {
            let url = writeWav()
            onWavReady?(url)
        } else {
            print("🎤 No voice data captured")
        }

        print("🎤 Voice capture stopped")
    }

    // MARK: - Line processing

    private func processLine(_ line: String) {
        // Filter by MAC if set, or accept all RECV lines
        guard line.contains("RECV") else { return }

        if let mac = remoteMAC, !mac.isEmpty {
            if line.contains(mac) || line.contains("00:00:00:00:00:00") {
                parser.feedLine(line)
            }
        } else {
            parser.feedLine(line)
        }
    }

    // MARK: - VoicePacketParserDelegate

    func voiceSessionStarted() {
        print("🗣 Voice started")
        opusDecoder.reset()
        resetDecodedAudio()
        onVoiceStateChange?(true)
    }

    func voiceSessionEnded() {
        print("🗣 Voice ended — \(decodedAudio.count) bytes PCM")
        onVoiceStateChange?(false)
    }

    func voicePacketReceived(_ opusData: Data) {
        do {
            let pcm = try opusDecoder.decode(packet: opusData)
            decodedAudio.append(pcm)
        } catch {
            // Skip individual decode errors
        }
    }

    // MARK: - WAV Output

    private func resetDecodedAudio() {
        decodedAudio = Data()
    }

    private func writeWav() -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = URL(fileURLWithPath: "/tmp/mavrick_voice_\(timestamp).wav")

        let sampleRate: Int32 = 16000
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let dataSize = Int32(decodedAudio.count)
        let byteRate = Int32(numChannels) * Int32(bitsPerSample) * sampleRate / 8
        let blockAlign = Int16(numChannels) * bitsPerSample / 8
        let totalSize: Int32 = 36 + dataSize

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        withUnsafeBytes(of: totalSize.littleEndian) { header.append(contentsOf: $0) }
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        withUnsafeBytes(of: Int32(16).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: Int16(1).littleEndian) { header.append(contentsOf: $0) }  // PCM
        withUnsafeBytes(of: numChannels.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { header.append(contentsOf: $0) }
        header.append("data".data(using: .ascii)!)
        withUnsafeBytes(of: dataSize.littleEndian) { header.append(contentsOf: $0) }

        let wav = header + decodedAudio
        try? wav.write(to: url)
        print("📼 WAV saved: \(url.path) (\(wav.count) bytes)")
        return url
    }
}
