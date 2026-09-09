// fm-voice-hotkey: the hold-to-talk daemon behind bin/fm-voice.sh.
//
// It does exactly three things and knows nothing about Herdr, whisper, or
// firstmate: register one global modifier chord with Carbon (no Accessibility
// or Input Monitoring grant needed), record the default microphone into a
// fresh 0700 temp directory ONLY while the chord is held, and hand the WAV to
// `<submit> submit <wav>` on release. Every policy decision - focus rule,
// silence gates, hallucination list, sound names, exit codes - lives in
// bin/fm-voice.sh so the shell test suite covers it; this file stays a thin,
// dependency-free (Carbon, Cocoa, AVFoundation) recorder.
//
// Usage (bin/fm-voice.sh start owns the invocation):
//   fm-voice-hotkey --hotkey <spec> --max-seconds <n> --submit <path>
//                   --sounds on|off --tmpdir <dir>
//   fm-voice-hotkey --probe-mic       prints authorized|denied|restricted|notDetermined
//
// Exit codes: 0 on SIGTERM/SIGINT, 2 bad arguments, 3 microphone denied,
// 4 hot key registration failed.
//
// Pane lines (stdout, one per state): "HH:MM:SS recording",
// "HH:MM:SS transcribing (N.N s[, stopped at cap])", the submit line verbatim,
// or "HH:MM:SS busy: still transcribing". Cues are delegated to
// `<submit> cue <state>` when --sounds is on. No audio path is ever printed.

import AVFoundation
import Carbon
import Cocoa

// MARK: - arguments

var hotkeySpec = "ctrl+alt+space"
var maxSeconds = 120.0
var submitPath = ""
var soundsOn = true
var tmpDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"

func probeMic() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
}

func usage(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "--probe-mic":
        print(probeMic())
        exit(0)
    case "--hotkey", "--max-seconds", "--submit", "--sounds", "--tmpdir":
        guard !args.isEmpty else { usage("missing value for \(flag)") }
        let value = args.removeFirst()
        switch flag {
        case "--hotkey": hotkeySpec = value
        case "--max-seconds":
            guard let n = Double(value), n >= 1 else { usage("bad --max-seconds \(value)") }
            maxSeconds = n
        case "--submit": submitPath = value
        case "--sounds": soundsOn = (value == "on")
        default: tmpDir = value
        }
    default:
        usage("unknown argument \(flag)")
    }
}
guard !submitPath.isEmpty, FileManager.default.isExecutableFile(atPath: submitPath) else {
    usage("--submit must name the executable fm-voice.sh")
}

// MARK: - output helpers

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

func say(_ line: String) {
    print("\(stamp()) \(line)")
    fflush(stdout)
}

func runSubmit(_ arguments: [String], completion: ((Int32, String) -> Void)? = nil) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: submitPath)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.standardError
    p.terminationHandler = { proc in
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(decoding: data, as: UTF8.self)
        DispatchQueue.main.async { completion?(proc.terminationStatus, out) }
    }
    do { try p.run() } catch {
        DispatchQueue.main.async { completion?(127, "failed: cannot run \(submitPath)\n") }
    }
}

func cue(_ state: String) {
    guard soundsOn else { return }
    runSubmit(["cue", state])
}

// MARK: - hot key parsing

func keyCode(for key: String) -> UInt32? {
    let table: [String: Int] = [
        "space": kVK_Space, "esc": kVK_Escape, "tab": kVK_Tab, "return": kVK_Return,
        "`": kVK_ANSI_Grave, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11,
        "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16,
        "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19,
    ]
    return table[key].map { UInt32($0) }
}

func parseHotkey(_ spec: String) -> (UInt32, UInt32)? {
    var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, let key = parts.popLast(), let code = keyCode(for: key) else { return nil }
    var mods: UInt32 = 0
    for m in parts {
        switch m {
        case "ctrl": mods |= UInt32(controlKey)
        case "alt": mods |= UInt32(optionKey)
        case "shift": mods |= UInt32(shiftKey)
        case "cmd": mods |= UInt32(cmdKey)
        default: return nil
        }
    }
    return (mods, code)
}

guard let (modifiers, virtualKey) = parseHotkey(hotkeySpec) else {
    usage("invalid hotkey: \(hotkeySpec)")
}

// MARK: - microphone permission (asked at start, never on the first press)

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    break
case .notDetermined:
    let sema = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .audio) { ok in granted = ok; sema.signal() }
    sema.wait()
    if !granted {
        print("microphone access is denied for the terminal app hosting Herdr; enable it in System Settings > Privacy & Security > Microphone")
        exit(3)
    }
default:
    print("microphone access is denied for the terminal app hosting Herdr; enable it in System Settings > Privacy & Security > Microphone")
    exit(3)
}

// MARK: - recorder

func sweepLeftovers() {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }
    for name in names where name.hasPrefix("fm-voice.") {
        try? fm.removeItem(atPath: (tmpDir as NSString).appendingPathComponent(name))
    }
}

final class Recorder {
    var recorder: AVAudioRecorder?
    var directory: String?
    var capTimer: Timer?
    var transcribing = false

    func press() {
        if transcribing {
            say("busy: still transcribing")
            cue("busy")
            return
        }
        guard recorder == nil else { return }
        var template = Array("\(tmpDir)/fm-voice.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else {
            say("failed: cannot create a temp directory under \(tmpDir)")
            return
        }
        let dir = String(cString: template)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("rec.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else { throw NSError(domain: "fm-voice", code: 1) }
            recorder = r
            directory = dir
        } catch {
            try? FileManager.default.removeItem(atPath: dir)
            say("failed: cannot open the microphone (\(error.localizedDescription))")
            return
        }
        say("recording")
        cue("recording")
        capTimer = Timer.scheduledTimer(withTimeInterval: maxSeconds, repeats: false) { [weak self] _ in
            self?.finish(atCap: true)
        }
    }

    func release() { finish(atCap: false) }

    func finish(atCap: Bool) {
        guard let r = recorder, let dir = directory else { return }
        capTimer?.invalidate()
        capTimer = nil
        let seconds = r.currentTime
        r.stop()                       // the device closes here, before anything else runs
        recorder = nil
        directory = nil
        let note = atCap ? ", stopped at cap" : ""
        say(String(format: "transcribing (%.1f s%@)", seconds, note))
        cue("transcribing")
        transcribing = true
        runSubmit(["submit", "\(dir)/rec.wav"]) { [weak self] _, out in
            let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { say(line) }
            try? FileManager.default.removeItem(atPath: dir)
            self?.transcribing = false
        }
    }

    func abort() {
        capTimer?.invalidate()
        recorder?.stop()
        recorder = nil
        if let dir = directory { try? FileManager.default.removeItem(atPath: dir) }
        directory = nil
    }
}

let recorder = Recorder()

// MARK: - Carbon hot key

var hotKeyRef: EventHotKeyRef?
let hotKeyID = EventHotKeyID(signature: OSType(0x464D_5643), id: 1) // "FMVC"
var eventTypes = [
    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
]
let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
    guard let event = event else { return noErr }
    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed): recorder.press()
    case UInt32(kEventHotKeyReleased): recorder.release()
    default: break
    }
    return noErr
}, eventTypes.count, &eventTypes, nil, nil)
if handlerStatus != noErr {
    print("hot key handler installation failed (status \(handlerStatus))")
    exit(4)
}
let registerStatus = RegisterEventHotKey(virtualKey, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
if registerStatus != noErr {
    print("hot key registration failed (status \(registerStatus))")
    exit(4)
}

// MARK: - lifecycle

sweepLeftovers()

func shutdown() {
    recorder.abort()
    if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
    sweepLeftovers()
    exit(0)
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { shutdown() }
termSource.resume()
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSource.setEventHandler { shutdown() }
intSource.resume()

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
say("ready: hold \(hotkeySpec) to talk")
app.run()
