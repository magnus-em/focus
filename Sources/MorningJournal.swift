import AVFoundation
import Foundation
import Speech

/// Live speech-to-text into a text field. On-device when the Mac supports it,
/// which also lifts the ~1 minute cap server recognition has.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// `onText` gets the full transcript of this listening run each time it updates.
    func start(onText: @escaping (String) -> Void) {
        guard !isListening else { return }
        error = nil
        Task {
            guard await Self.authorize() else {
                error = "Allow Focus under System Settings → Privacy & Security → Microphone and Speech Recognition."
                return
            }
            begin(onText: onText)
        }
    }

    func stop() {
        guard isListening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isListening = false
    }

    private func begin(onText: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition isn't available right now."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "Couldn't start the microphone."
            return
        }
        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, err in
            Task { @MainActor in
                guard let self else { return }
                if let result { onText(result.bestTranscription.formattedString) }
                if err != nil || result?.isFinal == true { self.stop() }
            }
        }
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// Hands text to a user-made Shortcut (Receive text → Journal "Create Entry"),
/// since Journal has no API of its own.
enum JournalShortcut {
    static func send(_ text: String, shortcut: String) async -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("focus-journal-\(UUID().uuidString).txt")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return "Couldn't write the entry." }
        defer { try? FileManager.default.removeItem(at: url) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["run", shortcut, "--input-path", url.path]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        return await withCheckedContinuation { c in
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { c.resume(returning: nil); return }
                let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                c.resume(returning: msg.isEmpty ? "Shortcut “\(shortcut)” failed." : msg)
            }
            do { try p.run() } catch { c.resume(returning: "Couldn't run Shortcuts.") }
        }
    }
}
