import Foundation
import Speech
import AVFoundation
import AppKit

/// 语音识别（SFSpeechRecognizer），用于「语音输入」。
/// 内置静音检测：说完停顿一段时间自动结束录音。
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    var onUpdate: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    /// 说完后静音多久自动结束（秒）
    var silenceTimeout: TimeInterval = 1.5
    /// 一直没说话多久放弃（秒）
    var noSpeechTimeout: TimeInterval = 8
    /// 录音开始/结束时的提示音
    var listenSound = true

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var timer: Timer?
    private var lastVoiceTime = Date()
    private var tapInstalled = false

    /// 应用设置（语言、静音超时）
    func applySettings(_ s: AppSettings) {
        silenceTimeout = s.silenceTimeout
        noSpeechTimeout = s.noSpeechTimeout
        listenSound = s.listenSound
        if recognizer?.locale.identifier != s.voiceLanguage {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: s.voiceLanguage))
        }
    }

    private func playCue(_ name: String) {
        guard listenSound else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func start() {
        guard !isRecording else { return }
        transcript = ""
        lastVoiceTime = Date()

        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.transcript = text
                    self.onUpdate?(text)
                }
            }
            if error != nil {
                DispatchQueue.main.async { self.stop() }
            }
            // 不依赖 isFinal：结束由静音检测负责
        }

        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            guard let self, let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(n))
            if rms > 0.012 {                       // 检测到人声
                Task { @MainActor in self.noteVoice() }
            }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            setRecording(true)
            playCue("Tink")
            startSilenceTimer()
        } catch {
            stop()
        }
    }

    private func startSilenceTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.checkSilence() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @MainActor
    private func noteVoice() { lastVoiceTime = Date() }

    @MainActor
    private func checkSilence() {
        guard isRecording else { return }
        let elapsed = Date().timeIntervalSince(lastVoiceTime)
        if !transcript.isEmpty && elapsed > silenceTimeout {
            stop()                                 // 讲完停顿 → 自动结束
        } else if transcript.isEmpty && elapsed > noSpeechTimeout {
            stop()                                 // 一直没说话 → 放弃
        }
    }

    func stop() {
        let wasRecording = isRecording
        timer?.invalidate()
        timer = nil
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if wasRecording { playCue("Pop") }
        setRecording(false)
    }

    private func setRecording(_ v: Bool) {
        isRecording = v
        onStateChange?(v)
    }
}

/// 语音合成（AVSpeechSynthesizer），用于「语音输出」
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    var enabled = true
    /// 一段朗读播完时回调（用于连续对话自动接听）
    var onFinish: (() -> Void)?

    private var language = "zh-CN"
    private var rate: Float = 0.5
    private var volume: Float = 1.0
    private var pitch: Float = 1.0
    private var voiceName = ""

    override init() {
        super.init()
        synth.delegate = self
    }

    /// 应用设置（语速、音量、音色、音调）
    func configure(_ s: AppSettings) {
        enabled = s.voiceEnabled
        language = s.voiceLanguage
        rate = Float(s.voiceRate)
        volume = Float(s.voiceVolume)
        pitch = Float(s.voicePitch)
        voiceName = s.voiceName
    }

    func say(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        if !voiceName.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceName) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: language)
        }
        u.rate = rate
        u.volume = volume
        u.pitchMultiplier = pitch
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onFinish?() }
    }
}
