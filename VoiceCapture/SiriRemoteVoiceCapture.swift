//
//  SiriRemoteVoiceCapture.swift
//  Mavrick
//
//  Manages the full Siri Remote voice capture pipeline:
//    PacketLogger → BLE parser → Opus decoder → WAV output
//
//  Prerequisites:
//    - PacketLogger.app (Additional Tools for Xcode)
//    - brew install opus blackhole-2ch
//

import Foundation

/// Manages voice capture from the Siri Remote.
final class SiriRemoteVoiceCapture: VoicePacketParserDelegate {

    // MARK: - State

    private let opusDecoder: OpusDecoder
    private let parser = VoicePacketParser()
    private var decodedAudio = Data()
    private(set) var isCapturing = false
    private var packetLoggerProcess: Process?
    private var outputPipe: Pipe?
    private var readSource: DispatchSourceRead?

    /// Remote MAC address string (e.g. "AA:BB:CC:DD:EE:FF"), used to filter PacketLogger lines.
    var remoteMAC: String?

    /// Called when a decoded WAV file is ready.
    var onWavReady: ((URL) -> Void)?

    /// Called on voice session state changes.
    var onVoiceStateChange: ((Bool) -> Void)?

    // MARK: - Init

    init() {
        opusDecoder = OpusDecoder(sampleRate: 16000, channels: 1)
        parser.delegate = self
    }

    // MARK: - Public API

    /// Start capturing voice data. Launches PacketLogger as a subprocess.
    func startCapture() {
        guard !isCapturing else { return }
        resetDecodedAudio()

        guard let packetLoggerPath = findPacketLogger() else {
            print("❌ PacketLogger.app not found. Install from Xcode Additional Tools.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: packetLoggerPath)
        process.arguments = []  // PacketLogger starts logging immediately

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        // Read stdout asynchronously line by line
        let readSource = DispatchSource.makeReadSource(fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                                                        queue: DispatchQueue(label: "com.mavrick.voicecapture"))
        readSource.setEventHandler { [weak self] in
            guard let self = self else { return }
            let data = pipe.fileHandleForReading.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                for line in str.components(separatedBy: "\n") {
                    guard !line.isEmpty else { continue }
                    // Filter by MAC if set
                    if let mac = self.remoteMAC, !mac.isEmpty {
                        if line.contains(mac) || line.contains("00:00:00:00:00:00") {
                            self.parser.feedLine(line)
                        }
                    } else {
                        self.parser.feedLine(line)
                    }
                }
            }
        }
        readSource.setCancelHandler {
            try? pipe.fileHandleForReading.close()
        }
        readSource.resume()

        self.readSource = readSource
        self.outputPipe = pipe
        self.packetLoggerProcess = process

        do {
            try process.run()
            isCapturing = true
            print("🎤 Voice capture started (PacketLogger PID: \(process.processIdentifier))")
        } catch {
            print("❌ Failed to launch PacketLogger: \(error)")
            readSource.cancel()
        }
    }

    /// Stop capturing and finalize WAV.
    func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false

        // Terminate PacketLogger
        packetLoggerProcess?.terminate()
        packetLoggerProcess?.waitUntilExit()
        packetLoggerProcess = nil

        // Stop reading
        readSource?.cancel()
        readSource = nil
        outputPipe = nil

        // Write WAV
        if !decodedAudio.isEmpty {
            let url = writeWav()
            onWavReady?(url)
        }

        print("🎤 Voice capture stopped")
    }

    // MARK: - VoicePacketParserDelegate

    func voiceSessionStarted() {
        print("🗣 Voice started")
        opusDecoder.reset()
        resetDecodedAudio()
        onVoiceStateChange?(true)
    }

    func voiceSessionEnded() {
        print("🗣 Voice ended — decoded \(decodedAudio.count) bytes PCM")
        onVoiceStateChange?(false)
    }

    func voicePacketReceived(_ opusData: Data) {
        do {
            let pcm = try opusDecoder.decode(packet: opusData)
            decodedAudio.append(pcm)
        } catch {
            // Silently skip decode errors for individual packets
        }
    }

    // MARK: - WAV Output

    private func resetDecodedAudio() {
        decodedAudio = Data()
    }

    private func writeWav() -> URL {
        let url = URL(fileURLWithPath: "/tmp/mavrick_voice_\(Int(Date().timeIntervalSince1970)).wav")

        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let sampleRate: Int32 = 16000
        let dataSize = Int32(decodedAudio.count)
        let byteRate = Int32(numChannels) * Int32(bitsPerSample) * sampleRate / 8
        let blockAlign = Int16(numChannels) * bitsPerSample / 8
        let totalSize: Int32 = 36 + dataSize
        let audioFormat: Int16 = 1  // PCM

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        withUnsafeBytes(of: totalSize.littleEndian) { header.append(contentsOf: $0) }
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        withUnsafeBytes(of: Int32(16).littleEndian) { header.append(contentsOf: $0) }   // chunk size
        withUnsafeBytes(of: audioFormat.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: numChannels.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { header.append(contentsOf: $0) }
        header.append("data".data(using: .ascii)!)
        withUnsafeBytes(of: dataSize.littleEndian) { header.append(contentsOf: $0) }

        let wav = header + decodedAudio
        try? wav.write(to: url)
        print("📼 WAV written: \(url.path) (\(wav.count) bytes)")
        return url
    }

    // MARK: - Helpers

    private func findPacketLogger() -> String? {
        let paths = [
            "/Applications/Additional Tools/Hardware/PacketLogger.app/Contents/MacOS/PacketLogger",
            "/Applications/PacketLogger.app/Contents/MacOS/PacketLogger",
            "\(NSHomeDirectory())/Downloads/PacketLogger.app/Contents/MacOS/PacketLogger",
        ]
        for p in paths {
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        // Fallback: use which/mdfind
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["kMDItemFSName == 'PacketLogger'"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        if let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .components(separatedBy: "\n").first(where: { $0.contains("PacketLogger.app") }) {
            return "\(result)/Contents/MacOS/PacketLogger"
        }
        return nil
    }
}
