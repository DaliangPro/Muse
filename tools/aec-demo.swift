import AVFoundation
import Foundation

let duration: TimeInterval = 10
let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

// MARK: - System volume save/restore (failsafe against ducking)

func getSystemVolume() -> Int {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "output volume of (get volume settings)"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return Int(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "50") ?? 50
}

func setSystemVolume(_ vol: Int) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "set volume output volume \(vol)"]
    try? task.run()
    task.waitUntilExit()
}

// MARK: - Recording

func record(voiceProcessing: Bool, filename: String) throws {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode

    // Save volume before any audio engine changes
    let savedVolume = getSystemVolume()

    try inputNode.setVoiceProcessingEnabled(voiceProcessing)

    if voiceProcessing {
        inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )
    }

    let format = inputNode.outputFormat(forBus: 0)
    let outputURL = desktop.appendingPathComponent(filename)

    let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)

    print("  format: \(Int(format.sampleRate))Hz, \(format.channelCount)ch")

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        try? file.write(from: buffer)
    }

    try engine.start()

    // Always restore volume after engine starts (ensure identical conditions)
    setSystemVolume(savedVolume)
    print("  volume locked at \(savedVolume)%")

    for i in stride(from: Int(duration), through: 1, by: -1) {
        print("  \(i)s remaining...", terminator: "\r")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 1)
    }
    print("                        ")

    engine.stop()
    inputNode.removeTap(onBus: 0)

    print("  saved: \(outputURL.path)")
}

// -- Main --

print("=== AEC A/B Demo ===")
print("Duration: \(Int(duration))s per recording")
print("Play music through speakers and speak during recording.\n")

// Round 1: Raw
print("[1/2] RAW (no AEC)")
print("  Press Enter to start...")
_ = readLine()
do {
    try record(voiceProcessing: false, filename: "aec_off.wav")
} catch {
    print("  ERROR: \(error)")
    exit(1)
}

// Round 2: AEC
print("\n[2/2] AEC ON (Voice Processing IO)")
print("  Press Enter to start...")
_ = readLine()
do {
    try record(voiceProcessing: true, filename: "aec_on.wav")
} catch {
    print("  ERROR: \(error)")
    exit(1)
}

print("\nDone! Files on Desktop:")
print("  aec_off.wav  - raw mic input")
print("  aec_on.wav   - with echo cancellation")
