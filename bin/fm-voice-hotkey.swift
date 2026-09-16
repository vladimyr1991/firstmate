// fm-voice-hotkey: the hold-to-talk daemon behind bin/fm-voice.sh.
//
// It does exactly three things and knows nothing about Herdr, whisper, or
// firstmate: observe one global chord, record the default microphone into a
// fresh 0700 temp directory ONLY while the chord is held, and hand the WAV to
// `<submit> submit <dir>/rec.wav` on release. An ordinary modifier chord is a
// Carbon hot key and needs no Accessibility or Input Monitoring grant. An fn
// chord cannot be a Carbon hot key (Fn is not a Carbon modifier), so it is an
// active CGEvent tap on the session's keyboard events that swallows the chord's
// key, so the letter is never typed; that tap exists only while this process
// runs, and macOS gates creating it behind Input Monitoring (to see key events)
// and, for an active tap, Accessibility. bin/fm-voice.sh start asks for them
// through --request-fn-chord before launching, never on a press, and a missing
// grant is a refusal that names its pane, here and there. It also
// removes the directory it made once submit exits: the creator is the only
// deleter, submit never deletes a recording, so nothing handed to submit can
// aim a deletion at a directory it did not create. Every policy decision - focus rule,
// silence gates, hallucination list, sound names, exit codes - lives in
// bin/fm-voice.sh so the shell test suite covers it; this file stays a thin,
// dependency-free (Carbon, Cocoa, AVFoundation) recorder.
//
// Usage (bin/fm-voice.sh start owns the invocation):
//   fm-voice-hotkey --hotkey <spec> --max-seconds <n> --submit <path>
//                   --sounds on|off --tmpdir <dir>
//   fm-voice-hotkey --probe-mic       prints authorized|denied|restricted|notDetermined
//   fm-voice-hotkey --probe-fn-chord  prints authorized when an fn chord tap can
//                                     be created right now, otherwise the pane
//                                     still missing: input-monitoring|accessibility
//   fm-voice-hotkey --request-fn-chord  asks macOS for whatever --probe-fn-chord
//                                     reports missing (the system dialog adds the
//                                     hosting app to that pane), then prints the
//                                     --probe-fn-chord result afterwards
//   fm-voice-hotkey --hotkey <fn chord> --simulate-events
//                                     reads one synthetic keyboard event per stdin
//                                     line, "<keyDown|keyUp|flagsChanged> <key|->
//                                     [fn,shift,cmd,ctrl,alt]", and prints the tap's
//                                     decision for each: pass | swallow [press|release].
//                                     No tap, no grant, no microphone: it is the
//                                     test seam for the chord classification.
//
// Exit codes: 0 on SIGTERM/SIGINT, 2 bad arguments, 3 a permission is denied
// (microphone, or Input Monitoring/Accessibility for an fn chord), 4 hot key
// registration or tap creation failed.
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

let fnKeyboardEventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    | CGEventMask(1 << CGEventType.keyUp.rawValue)
    | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

// A tap that passes every event through unchanged; used only to learn whether
// macOS lets this process create an active keyboard tap at all.
let fnPassthroughCallback: CGEventTapCallBack = { _, _, event, _ in
    Unmanaged.passUnretained(event)
}

// The Input Monitoring preflight first, then the real test rather than a second
// preflight: try to create the exact kind of tap the fn chord needs and drop it
// again at once. Input Monitoring alone lets a process listen; swallowing the
// chord's key needs an active tap, which macOS additionally gates behind
// Accessibility. The tap is disabled and invalidated before this returns, so
// nothing is observed.
func probeFnChord() -> String {
    guard CGPreflightListenEventAccess() else { return "input-monitoring" }
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: fnKeyboardEventMask, callback: fnPassthroughCallback, userInfo: nil
    ) else { return "accessibility" }
    CGEvent.tapEnable(tap: tap, enable: false)
    CFMachPortInvalidate(tap)
    return "authorized"
}

// Raise the system dialog for whichever grant is missing. macOS adds the hosting
// app to that pane switched off and returns at once; the operator switches it on.
func requestFnChord() -> String {
    switch probeFnChord() {
    case "input-monitoring":
        CGRequestListenEventAccess()
    case "accessibility":
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    default:
        break
    }
    return probeFnChord()
}

func fnChordDenial(_ missing: String) -> String {
    switch missing {
    case "input-monitoring":
        return "Input Monitoring is not granted to the terminal app hosting Herdr, and an fn chord can only be seen through keyboard events; switch that app on in System Settings > Privacy & Security > Input Monitoring, then start again"
    default:
        return "Accessibility is not granted to the terminal app hosting Herdr, and only Accessibility lets the fn chord's key be swallowed instead of typed; switch that app on in System Settings > Privacy & Security > Accessibility, then start again"
    }
}

func usage(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

var simulateEvents = false
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "--probe-mic":
        print(probeMic())
        exit(0)
    case "--probe-fn-chord":
        print(probeFnChord())
        exit(0)
    case "--request-fn-chord":
        print(requestFnChord())
        exit(0)
    case "--simulate-events":
        simulateEvents = true
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
guard simulateEvents || (!submitPath.isEmpty && FileManager.default.isExecutableFile(atPath: submitPath)) else {
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

@discardableResult
func runSubmit(_ arguments: [String], completion: ((Int32, String) -> Void)? = nil) -> Process? {
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
        return nil
    }
    return p
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

enum Hotkey {
    case carbon(UInt32, UInt32)
    case fn(CGEventFlags, UInt16)
}

func parseHotkey(_ spec: String) -> Hotkey? {
    var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, let key = parts.popLast(), let code = keyCode(for: key) else { return nil }
    var carbonMods: UInt32 = 0
    var eventMods: CGEventFlags = []
    var hasFn = false
    for m in parts {
        switch m {
        case "ctrl":
            carbonMods |= UInt32(controlKey)
            eventMods.insert(.maskControl)
        case "alt":
            carbonMods |= UInt32(optionKey)
            eventMods.insert(.maskAlternate)
        case "shift":
            carbonMods |= UInt32(shiftKey)
            eventMods.insert(.maskShift)
        case "cmd":
            carbonMods |= UInt32(cmdKey)
            eventMods.insert(.maskCommand)
        case "fn":
            guard !hasFn else { return nil }
            hasFn = true
        default: return nil
        }
    }
    if hasFn { return .fn(eventMods, UInt16(code)) }
    return .carbon(carbonMods, code)
}

guard let hotkey = parseHotkey(hotkeySpec) else {
    usage("invalid hotkey: \(hotkeySpec)")
}

// MARK: - fn chord classification

// The fn chord the tap matches, and whether its key is down since a press the
// tap swallowed. Globals because a CGEventTapCallBack is a C function pointer
// and cannot capture anything.
var fnRequiredModifiers: CGEventFlags = []
var fnVirtualKey: Int64 = -1
var fnKeyDown = false
let chordModifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

enum FnChordEdge { case press, release, none }

// One decision per keyboard event, shared by the real tap and --simulate-events.
// Press = key down of the chord's key with Fn held and exactly the chord's other
// modifiers. The key then counts as held until its own key up, whatever Fn or
// the modifiers do meanwhile: every key down (autorepeat) and the key up of
// that key are swallowed so the letter is never typed, and only that key up is
// the release. Releasing Fn first changes nothing; the recording runs until the
// letter comes up or the cap. Every other event passes through untouched.
func classifyFnChordEvent(type: CGEventType, keycode: Int64, flags: CGEventFlags) -> (swallow: Bool, edge: FnChordEdge) {
    guard type == .keyDown || type == .keyUp, keycode == fnVirtualKey else { return (false, .none) }
    if fnKeyDown {
        guard type == .keyUp else { return (true, .none) }
        fnKeyDown = false
        return (true, .release)
    }
    let exactChord = flags.contains(.maskSecondaryFn)
        && flags.intersection(chordModifierMask) == fnRequiredModifiers
    guard type == .keyDown, exactChord else { return (false, .none) }
    fnKeyDown = true
    return (true, .press)
}

func simulateFnChordEvents() -> Never {
    guard case let .fn(requiredModifiers, virtualKey) = hotkey else {
        usage("--simulate-events needs an fn chord, got \(hotkeySpec)")
    }
    fnRequiredModifiers = requiredModifiers
    fnVirtualKey = Int64(virtualKey)
    let types: [String: CGEventType] = ["keyDown": .keyDown, "keyUp": .keyUp, "flagsChanged": .flagsChanged]
    let flagNames: [String: CGEventFlags] = [
        "fn": .maskSecondaryFn, "shift": .maskShift, "cmd": .maskCommand,
        "ctrl": .maskControl, "alt": .maskAlternate,
    ]
    while let line = readLine() {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 2, parts.count <= 3, let type = types[parts[0]] else {
            usage("bad event line: \(line)")
        }
        var keycode: Int64 = -1
        if parts[1] != "-" {
            guard let code = keyCode(for: parts[1]) else { usage("bad key in event line: \(line)") }
            keycode = Int64(code)
        }
        var flags: CGEventFlags = []
        if parts.count == 3 {
            for name in parts[2].split(separator: ",") {
                guard let flag = flagNames[String(name)] else { usage("bad flag in event line: \(line)") }
                flags.insert(flag)
            }
        }
        let decision = classifyFnChordEvent(type: type, keycode: keycode, flags: flags)
        var out = decision.swallow ? "swallow" : "pass"
        switch decision.edge {
        case .press: out += " press"
        case .release: out += " release"
        case .none: break
        }
        print(out)
    }
    exit(0)
}

if simulateEvents { simulateFnChordEvents() }

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
    var submit: Process?            // the in-flight `submit`, cancelled on shutdown
    var transcribing = false
    var held = false                // Carbon repeats the press event while the chord is held

    func press() {
        guard !held else { return }
        held = true
        start()
    }

    func start() {
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

    func release() {
        held = false
        finish(atCap: false)
    }

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
        submit = runSubmit(["submit", "\(dir)/rec.wav"]) { [weak self] _, out in
            let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { say(line) }
            try? FileManager.default.removeItem(atPath: dir)
            self?.submit = nil
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

    // SIGTERM the in-flight submit so nothing is typed after a stop, and give its
    // EXIT trap a bounded moment to release the lock and delete its own scratch
    // directory; the recording directory is removed by this daemon, not by submit.
    func cancelSubmit(timeout: TimeInterval) {
        guard let p = submit, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        submit = nil
    }
}

let recorder = Recorder()

// MARK: - hot key

var hotKeyRef: EventHotKeyRef?
var inputTap: CFMachPort?
let hotKeyID = EventHotKeyID(signature: OSType(0x464D_5643), id: 1) // "FMVC"

// The callback only classifies the event and flips `held`: macOS holds the
// session's keyboard stream while it runs, so the microphone and submit work
// is handed to the main queue, whose FIFO order keeps press before release.
func fnChordPressed() {
    recorder.held = true
    DispatchQueue.main.async { recorder.start() }
}

func fnChordReleased() {
    recorder.held = false
    DispatchQueue.main.async { recorder.finish(atCap: false) }
}

let fnChordCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = inputTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let decision = classifyFnChordEvent(
        type: type, keycode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags
    )
    switch decision.edge {
    case .press: fnChordPressed()
    case .release: fnChordReleased()
    case .none: break
    }
    return decision.swallow ? nil : Unmanaged.passUnretained(event)
}

switch hotkey {
case let .carbon(modifiers, virtualKey):
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
case let .fn(requiredModifiers, virtualKey):
    let access = probeFnChord()
    if access != "authorized" {
        print(fnChordDenial(access))
        exit(3)
    }
    fnRequiredModifiers = requiredModifiers
    fnVirtualKey = Int64(virtualKey)
    inputTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: fnKeyboardEventMask, callback: fnChordCallback, userInfo: nil
    )
    guard let tap = inputTap else {
        print("fn chord event tap could not be created although the probe allowed it; retry start, and if this persists check System Settings > Privacy & Security > Accessibility and > Input Monitoring for the terminal app hosting Herdr")
        exit(4)
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}

// MARK: - lifecycle

sweepLeftovers()

func shutdown() {
    recorder.abort()
    if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
    if let tap = inputTap { CFMachPortInvalidate(tap) }
    recorder.cancelSubmit(timeout: 3)
    sweepLeftovers()
    exit(0)
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGHUP, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { shutdown() }
termSource.resume()
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSource.setEventHandler { shutdown() }
intSource.resume()
let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
hupSource.setEventHandler { shutdown() }
hupSource.resume()

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
say("ready: hold \(hotkeySpec) to talk")
app.run()
