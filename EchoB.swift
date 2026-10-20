// Native macOS control panel for Moondrop ECHO-B.
// Same Conexant CAF protocol as echob.py: HID report ID 1, SET_REPORT out / GET_REPORT in.
import IOKit.hid
import SwiftUI

let vendorID = 0x35D8, productID = 0x149B
let reportID: CFIndex = 1
let words = 13                                  // app always pads to 13 words -> 62-byte report

let cmdSetParam: UInt32 = 90                    // data [90, index]
let cmdGetParam: UInt32 = 346                   // data [param]
let cmdGetPEQBand: UInt32 = 477                 // data [band 1...9]
let cmdSave: UInt32 = 220                       // data [slot, ...] / [255] commits to flash
let cmdGetLiveCoeffs: UInt32 = 446              // data [0, band]; slot must be 0, others hang the device
let paramEQMode: UInt32 = 90
let paramSampleRate: UInt32 = 62                // index matches slotRates numbering
let slotRates: [(UInt32, Double)] = [(4, 44100), (5, 48000), (6, 96000), (7, 192000), (8, 384000)]
let filterNames = [0: "Peak", 1: "Low shelf", 2: "High shelf", 3: "Low pass", 4: "High pass"]
let gainRange = -12.0...12.0, freqRange = 20.0...20000.0, qRange = 0.2...10.0, preampRange = -12.0...0.0
let standardFreqs = [63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
let standardQ = (2.0.squareRoot() * 256).rounded() / 256     // device stores q·256

func hz(_ f: Int) -> String { f >= 1000 ? String(format: "%.2fk", Double(f) / 1000) : "\(f)" }

func cafID(_ name: String) -> UInt32 {
    let b = name.utf8.map { UInt32($0) - 32 }
    return (b[0] << 8) | (b[1] << 14) | (b[2] << 20) | (b[3] << 26)
}

let ctrlModule = cafID("CTRL")

func encode(_ cmd: UInt32, _ data: [UInt32]) -> [UInt8] {
    var out: [UInt8] = [UInt8(reportID), 0]
    func le(_ v: UInt32) { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
    le(UInt32(words) | cmd << 16)
    le(ctrlModule)
    (data + Array(repeating: 0, count: words - data.count)).forEach(le)
    return out
}

func i32(_ b: [UInt8], _ o: Int) -> Int {
    Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
}

// device stores PEQ gain as a 24-bit signed value
func s24(_ v: Int) -> Int {
    let x = v & 0xFFFFFF
    return x & 0x800000 != 0 ? x - (1 << 24) : x
}

/// RBJ peaking biquad, normalized: [b0, b1, b2, a1, a2].
func peakCoeffs(_ fs: Double, _ freq: Double, _ q: Double, _ gain: Double) -> [Double] {
    if gain == 0 { return [1, 0, 0, 0, 0] }
    let A = pow(10, gain / 40), w = 2 * Double.pi * freq / fs
    let alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha / A
    return [(1 + alpha * A) / a0, -2 * c / a0, (1 - alpha * A) / a0, -2 * c / a0, (1 - alpha / A) / a0]
}

/// Device fixed point, matching the app's native EqDesignFx: 24-bit values scaled by 2^(23-n),
/// n = smallest power of two above the largest coefficient, shift byte = n + 2, feedback stored negated.
/// `preamp` (dB) scales the numerator: a broadband gain inside the DSP, the only preamp the device has.
func deviceCoeffs(_ fs: Double, _ freq: Double, _ q: Double, _ gain: Double, preamp: Double = 0) -> (UInt32, [Int]) {
    if gain == 0 && preamp == 0 { return (3, [1 << 22, 0, 0, 0, 0]) }      // device stores flat bands as identity
    let c = peakCoeffs(fs, freq, q, gain), k = pow(10, preamp / 20)
    let co = [c[0] * k, c[1] * k, c[2] * k, -c[3], -c[4]]
    let n = max(0, Int(floor(log2(co.map(abs).max()!))) + 1)            // shift 2 is the lowest seen on the device
    let scale = pow(2.0, Double(23 - n))
    return (UInt32(n + 2), co.map { Int(($0 * scale).rounded()) })
}

/// Inverse of deviceCoeffs: device fixed point back to normalized [b0, b1, b2, a1, a2].
func biquad(_ shift: Int, _ co: [Int]) -> [Double] {
    let c = co.map { Double(s24($0)) / pow(2, Double(25 - shift)) }
    return [c[0], c[1], c[2], -c[3], -c[4]]
}

/// Summed magnitude response in dB of normalized biquads [b0, b1, b2, a1, a2].
func responseDB(_ biquads: [[Double]], at f: Double, fs: Double) -> Double {
    let w = 2 * Double.pi * f / fs
    let cw = cos(w), sw = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
    return biquads.reduce(0) { sum, c in
        let nr = c[0] + c[1] * cw + c[2] * c2, ni = -(c[1] * sw + c[2] * s2)
        let dr = 1 + c[3] * cw + c[4] * c2, di = -(c[3] * sw + c[4] * s2)
        return sum + 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}

/// Custom PEQ response (display only, 48 kHz).
func responseDB(_ bands: [Band], at f: Double) -> Double {
    responseDB(bands.map { peakCoeffs(48000, Double($0.freq), $0.q, Double($0.gain)) }, at: f, fs: 48000)
}

/// Preamp savePEQ baked into band 1: what the DSP runs minus what the band params alone give.
func derivedPreamp(_ bands: [Band], live: [[Double]], fs: Double) -> Double {
    let params = bands.map { peakCoeffs(fs, Double($0.freq), $0.q, Double($0.gain)) }
    let db = responseDB(live, at: 1000, fs: fs) - responseDB(params, at: 1000, fs: fs)
    return ((db * 10).rounded() / 10).clamped(to: preampRange)
}

struct HIDError: Error, CustomStringConvertible { let description: String }

typealias Filter = (freq: Double, gain: Double, q: Double)

/// Parses Parametric EQ text as exported by squig.link, AutoEQ and Equalizer APO:
/// `Preamp: -2.8 dB` and `Filter 1: ON PK Fc 35 Hz Gain 1.8 dB Q 0.500`. OFF filters are skipped.
func parseEQ(_ text: String) throws -> (preamp: Double, filters: [Filter]) {
    var preamp = 0.0, filters: [Filter] = []
    for line in text.split(whereSeparator: \.isNewline) {
        let t = line.split(whereSeparator: \.isWhitespace).map(String.init)
        func value(after key: String) -> Double? {
            t.firstIndex(of: key).flatMap { $0 + 1 < t.count ? Double(t[$0 + 1]) : nil }
        }
        if t.first == "Preamp:" { preamp = value(after: "Preamp:") ?? 0; continue }
        guard t.first?.hasPrefix("Filter") == true, let on = t.firstIndex(of: "ON"), on + 1 < t.count else { continue }
        guard ["PK", "PEQ"].contains(t[on + 1]) else {
            throw HIDError(description: "\(t[on + 1]) filters (shelf / pass) aren't supported yet, only PK")
        }
        guard let f = value(after: "Fc"), let g = value(after: "Gain"), let q = value(after: "Q") else {
            throw HIDError(description: "Can't read: \(line)")
        }
        filters.append((f, g, q))
    }
    guard !filters.isEmpty else { throw HIDError(description: "No Parametric EQ filters in the clipboard") }
    guard filters.count <= 9 else { throw HIDError(description: "ECHO-B has 9 bands, this EQ has \(filters.count) active filters") }
    return (preamp, filters)
}

/// Highest point of the summed curve, 20 Hz to 20 kHz. Above 0 dB the EQ can clip loud tracks.
func peakDB(_ bands: [Band]) -> Double {
    stride(from: 0.0, through: 3, by: 0.005).map { responseDB(bands, at: freqRange.lowerBound * pow(10, $0)) }.max() ?? 0
}

/// Same format back out.
func exportEQ(_ bands: [Band], preamp: Double) -> String {
    let lines = bands.enumerated().map { i, b in
        String(format: "Filter %d: ON PK Fc %d Hz Gain %.1f dB Q %.3f", i + 1, b.freq, Double(b.gain), b.q)
    }
    return ([String(format: "Preamp: %.1f dB", preamp == 0 ? 0 : preamp)] + lines).joined(separator: "\n")
}

struct Band: Identifiable, Equatable {
    let id: Int
    var freq: Int, q: Double, gain: Int
    let type: String
}

struct EchoB {
    let dev: IOHIDDevice

    func xfer(_ cmd: UInt32, _ data: [UInt32] = []) throws -> [UInt8] {
        let out = encode(cmd, data)
        var r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, out, out.count)
        guard r == kIOReturnSuccess else {
            throw HIDError(description: "Send failed (cmd \(cmd), 0x\(String(UInt32(bitPattern: r), radix: 16))). Replug ECHO-B.")
        }
        var buf = [UInt8](repeating: 0, count: out.count)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            var len = buf.count
            r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeInput, reportID, &buf, &len)
            if r == kIOReturnSuccess, len > 5, buf[5] & 0x80 != 0 {     // reply bit set
                if Int16(bitPattern: UInt16(buf[2]) | UInt16(buf[3]) << 8) < 0 {
                    throw HIDError(description: "Device rejected cmd \(cmd)")
                }
                return buf
            }
            usleep(5000)                                                // busy: keep polling, like the app
        }
        throw HIDError(description: "No reply for cmd \(cmd). Replug ECHO-B.")
    }

    // fire-and-forget like the app's coefficient writes: one read, reply not awaited
    func send(_ cmd: UInt32, _ data: [UInt32]) {
        let out = encode(cmd, data)
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, out, out.count)
        var buf = [UInt8](repeating: 0, count: out.count), len = buf.count
        IOHIDDeviceGetReport(dev, kIOHIDReportTypeInput, reportID, &buf, &len)
    }

    func eqMode() throws -> Int { i32(try xfer(cmdGetParam, [paramEQMode]), 14) }

    func peqBands() throws -> [Band] {
        try (1...9).map { band in
            let r = try xfer(cmdGetPEQBand, [UInt32(band)])
            return Band(id: i32(r, 14), freq: i32(r, 18), q: Double(i32(r, 22)) / 256,
                        gain: s24(i32(r, 30)), type: filterNames[i32(r, 26)] ?? "Type \(i32(r, 26))")
        }
    }

    func setPreset(_ index: Int) throws {
        _ = try xfer(cmdSetParam, [paramEQMode, UInt32(index)])     // also makes the DSP reload coefficients
        _ = try xfer(cmdSave, [255])
        // ponytail: fixed wait for the async DSP reload (reads right after return the old preset); poll if it ever flakes
        usleep(500_000)
    }

    /// The DSP only reloads coefficients on an actual mode change, so selecting 0 while on 0 isn't enough.
    func reloadCustom() throws {
        _ = try xfer(cmdSetParam, [paramEQMode, 1])
        usleep(500_000)
        try setPreset(0)
    }

    func sampleRate() throws -> Double {
        let idx = UInt32(i32(try xfer(cmdGetParam, [paramSampleRate]), 14))
        return slotRates.first { $0.0 == idx }?.1 ?? 48000
    }

    /// Biquads the DSP is running right now, i.e. the active preset's real curve.
    func liveBiquads() throws -> [[Double]] {
        try (1...9).map { band in
            let r = try xfer(cmdGetLiveCoeffs, [0, UInt32(band)])
            return biquad(i32(r, 18), (0..<5).map { i32(r, 22 + 4 * $0) })
        }
    }

    /// Same sequence as the app's saveEQParamsToFlash(custom): params, coefficients per rate slot, commit.
    func savePEQ(_ bands: [Band], preamp: Double) throws {
        for b in bands {
            _ = try xfer(cmdSave, [0, UInt32(b.id), UInt32(b.freq), UInt32(Int(b.q * 256)), 0,
                                   UInt32(bitPattern: Int32(b.gain))])
        }
        var writes: [[UInt32]] = []
        for b in bands {
            for (slot, fs) in slotRates {
                let (shift, co) = deviceCoeffs(fs, Double(b.freq), Double(Int(b.q * 256)) / 256, Double(b.gain),
                                               preamp: b.id == bands.first?.id ? preamp : 0)
                writes.append([slot, UInt32(b.id), shift] + co.map { UInt32(truncatingIfNeeded: $0) })
            }
        }
        for (i, w) in writes.enumerated() {
            if i == writes.count - 1 { _ = try xfer(cmdSave, w) } else { send(cmdSave, w) }
        }
        _ = try xfer(cmdSave, [255])
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var connected = false
    @Published var preset: Int?
    @Published var bands: [Band] = []
    @Published var savedBands: [Band] = []      // what the device currently holds
    @Published var preamp = 0.0                 // dB, baked into band 1's coefficients on write
    @Published var savedPreamp = 0.0
    @Published var live: [[Double]] = []        // active preset's curve as the DSP runs it
    @Published var sampleRate = 48000.0
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?              // result of a paste / copy, cleared on the next device read
    @Published var dragging: Int?               // band dot being dragged in the graph

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let queue = DispatchQueue(label: "echob.hid")
    private var timer: Timer?

    var dirty: Bool { bands != savedBands || preamp != savedPreamp }
    var peak: Double { bands.isEmpty ? 0 : peakDB(bands) }

    init() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        // ponytail: presence polling every 1.5s; switch to matching/removal callbacks if it ever matters
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPresence() }
        }
        checkPresence()
    }

    private func device() -> EchoB? {
        guard let dev = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else { return nil }
        IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        return EchoB(dev: dev)
    }

    private func checkPresence() {
        let present = device() != nil
        guard present != connected else { return }
        connected = present
        if present { refresh() } else { preset = nil; bands = []; savedBands = []; live = []; error = nil }
    }

    func refresh() { run { _ in } }

    func select(_ index: Int) { run { try $0.setPreset(index) } }

    /// Writes the edited Custom PEQ to flash and switches to it.
    func write() {
        guard connected, dirty else { return }
        let snapshot = bands, pre = preamp
        run {
            try $0.savePEQ(snapshot, preamp: pre)
            try $0.reloadCustom()
        }
    }

    func revert() { bands = savedBands; preamp = savedPreamp }

    /// Just enough preamp that the loudest boost lands at 0 dB.
    func autoPreamp() { preamp = (-(peak * 10).rounded(.up) / 10).clamped(to: preampRange) }

    /// Standard 9-band graphic EQ layout: ISO 266 octave centers, one-octave bandwidth (Q √2), 0 dB.
    func resetStandard() {
        for (i, f) in zip(bands.indices, standardFreqs) {
            (bands[i].freq, bands[i].q, bands[i].gain) = (f, standardQ, 0)
        }
        preamp = 0
    }

    /// Loads Parametric EQ text from the clipboard into the bands (not written until Write).
    func pasteEQ() {
        do {
            let eq = try parseEQ(NSPasteboard.general.string(forType: .string) ?? "")
            resetStandard()
            for (i, f) in zip(bands.indices, eq.filters.sorted { $0.freq < $1.freq }) {
                bands[i].freq = Int(f.freq.rounded()).clamped(to: Int(freqRange.lowerBound)...Int(freqRange.upperBound))
                // ponytail: device params hold whole dB as far as we know; try fractional gain if the 220 format allows it
                bands[i].gain = Int(f.gain.rounded()).clamped(to: Int(gainRange.lowerBound)...Int(gainRange.upperBound))
                bands[i].q = (f.q.clamped(to: qRange) * 256).rounded() / 256
            }
            preamp = ((eq.preamp * 10).rounded() / 10).clamped(to: preampRange)
            var notes = ["Pasted \(eq.filters.count) filters. Check the curve, then Write to ECHO-B."]
            if eq.filters.contains(where: { $0.gain != $0.gain.rounded() }) {
                notes.append("Gains rounded to whole dB, so the peak moved a little: Auto refits the preamp.")
            }
            notice = notes.joined(separator: " ")
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    func copyEQ() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportEQ(bands, preamp: preamp), forType: .string)
        notice = "Copied as Parametric EQ text (squig.link, AutoEQ, Equalizer APO)."
    }

    // Runs a device action off the main thread, then re-reads state.
    private func run(_ action: @escaping (EchoB) throws -> Void) {
        guard let dev = device(), !busy else { return }
        busy = true
        queue.async {
            let result = Result { () -> (Int, [Band], [[Double]], Double) in
                try action(dev)
                return (try dev.eqMode(), try dev.peqBands(), try dev.liveBiquads(), try dev.sampleRate())
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let (mode, bands, live, fs)):
                    self.preset = mode
                    self.bands = bands
                    self.savedBands = bands
                    self.live = live
                    self.sampleRate = fs
                    // Custom's preamp only shows in its live coefficients; under a preset they're the preset's
                    self.savedPreamp = mode == 0 ? derivedPreamp(bands, live: live, fs: fs) : 0
                    self.preamp = self.savedPreamp
                    self.error = nil
                    self.notice = nil
                case .failure(let e): self.error = "\(e)"
                }
            }
        }
    }
}

// MARK: - UI

struct ResponseGraph: View {
    @Binding var bands: [Band]
    @Binding var dragging: Int?
    var fixed: [[Double]]? = nil                // read-only curve (built-in preset) instead of the editable bands
    var fs = 48000.0
    var preamp = 0.0

    private func px(_ f: Double, _ w: Double) -> Double { log10(f / freqRange.lowerBound) / 3 * w }
    private func fx(_ x: Double, _ w: Double) -> Double {
        min(max(freqRange.lowerBound * pow(1000, x / w), freqRange.lowerBound), freqRange.upperBound)
    }
    private let span = 14.0                     // ±dB shown, headroom so ±12 labels aren't clipped
    private func py(_ db: Double, _ h: Double) -> Double { (span - db) / (2 * span) * h }

    var body: some View {
        GeometryReader { geo in
            let w = Double(geo.size.width), h = Double(geo.size.height)
            Canvas { ctx, _ in
                for f: Double in [50, 100, 200, 500, 1000, 2000, 5000, 10000] {
                    var p = Path(); p.move(to: CGPoint(x: px(f, w), y: 0)); p.addLine(to: CGPoint(x: px(f, w), y: h))
                    ctx.stroke(p, with: .color(.secondary.opacity(0.15)))
                    let label = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
                    ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: px(f, w), y: h - 7))
                }
                for db in stride(from: -12.0, through: 12, by: 6) {
                    var p = Path(); p.move(to: CGPoint(x: 0, y: py(db, h))); p.addLine(to: CGPoint(x: w, y: py(db, h)))
                    ctx.stroke(p, with: .color(.secondary.opacity(db == 0 ? 0.4 : 0.15)))
                    ctx.draw(Text(db > 0 ? "+\(Int(db))" : "\(Int(db))").font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: 12, y: py(db, h) - 7))
                }
                var curve = Path()
                for sx in stride(from: 0.0, through: w, by: 2) {
                    let f = fx(sx, w)
                    let db = min(max(fixed.map { responseDB($0, at: f, fs: fs) } ?? responseDB(bands, at: f) + preamp, -13), 13)
                    let pt = CGPoint(x: sx, y: py(db, h))
                    if sx == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                }
                var area = curve
                area.addLine(to: CGPoint(x: w, y: py(0, h))); area.addLine(to: CGPoint(x: 0, y: py(0, h))); area.closeSubpath()
                ctx.fill(area, with: .color(.accentColor.opacity(0.12)))
                ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2)
                for (i, b) in bands.enumerated() where fixed == nil {
                    let c = CGPoint(x: px(Double(b.freq), w), y: py(Double(b.gain), h))
                    let r: Double = dragging == i ? 9 : 7
                    let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    ctx.fill(dot, with: .color(b.gain == 0 ? .gray : .accentColor))
                    if dragging == i { ctx.stroke(dot, with: .color(.white), lineWidth: 2) }
                    ctx.draw(Text("\(b.id)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white), at: c)
                }
                for (name, f) in [("Bass", 70.0), ("Mids", 1000), ("Treble", 9000)] {   // < 250 Hz, 250 Hz–4 kHz, > 4 kHz
                    ctx.draw(Text(name).font(.caption2).foregroundStyle(.tertiary), at: CGPoint(x: px(f, w), y: 12))
                }
                if let i = dragging, fixed == nil, bands.indices.contains(i) {
                    let b = bands[i]
                    ctx.draw(Text("Band \(b.id) · \(hz(b.freq)) Hz · \(b.gain > 0 ? "+" : "")\(b.gain) dB · Q \(String(format: "%.2f", b.q))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: w / 2, y: 30))
                }
            }
            .help(fixed == nil ? "Drag a dot: left/right moves its frequency, up/down sets its gain. Set the width (Q) in the table below."
                               : "The curve this built-in preset applies, read from the ECHO-B")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragging == nil {
                        // grab the nearest band dot
                        let near = bands.indices.min { a, b in
                            hypot(px(Double(bands[a].freq), w) - g.startLocation.x, py(Double(bands[a].gain), h) - g.startLocation.y)
                                < hypot(px(Double(bands[b].freq), w) - g.startLocation.x, py(Double(bands[b].gain), h) - g.startLocation.y)
                        }
                        guard let near, hypot(px(Double(bands[near].freq), w) - g.startLocation.x,
                                              py(Double(bands[near].gain), h) - g.startLocation.y) < 20 else { return }
                        dragging = near
                    }
                    guard let i = dragging else { return }
                    bands[i].freq = Int(fx(g.location.x, w).rounded())
                    bands[i].gain = Int((span - g.location.y / h * 2 * span).rounded()).clamped(to: -12...12)
                }
                .onEnded { _ in
                    dragging = nil
                })
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

struct BandRow: View {
    @Binding var band: Band
    var active = false                          // being dragged in the graph

    private var logFreq: Binding<Double> {
        Binding(get: { log10(Double(band.freq)) }, set: { band.freq = Int(pow(10, $0).rounded()) })
    }
    private var logQ: Binding<Double> {
        Binding(get: { log10(band.q) }, set: { band.q = (pow(10, $0) * 256).rounded() / 256 })
    }
    private var gain: Binding<Double> {
        Binding(get: { Double(band.gain) }, set: { band.gain = Int($0.rounded()) })
    }
    // typed values, clamped to what the device takes
    private var freqField: Binding<Int> {
        Binding(get: { band.freq }, set: { band.freq = $0.clamped(to: Int(freqRange.lowerBound)...Int(freqRange.upperBound)) })
    }
    private var gainField: Binding<Int> {
        Binding(get: { band.gain }, set: { band.gain = $0.clamped(to: Int(gainRange.lowerBound)...Int(gainRange.upperBound)) })
    }
    private var qField: Binding<Double> {
        Binding(get: { band.q }, set: { band.q = ($0.clamped(to: qRange) * 256).rounded() / 256 })
    }
    private func field<F: ParseableFormatStyle>(_ value: Binding<F.FormatInput>, _ format: F, width: CGFloat) -> some View
    where F.FormatOutput == String {
        TextField("", value: value, format: format)
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: width)
    }
    var body: some View {
        GridRow {
            Text("\(band.id)").font(.callout.bold()).foregroundStyle(active ? Color.accentColor : .secondary)
                .help("Band \(band.id), the same number as its dot on the graph")
            Slider(value: logFreq, in: log10(freqRange.lowerBound)...log10(freqRange.upperBound))
            field(freqField, IntegerFormatStyle<Int>().grouping(.never), width: 62)
            Slider(value: gain, in: gainRange)
            field(gainField, IntegerFormatStyle<Int>().sign(strategy: .always(includingZero: false)), width: 44)
            Slider(value: logQ, in: log10(qRange.lowerBound)...log10(qRange.upperBound))
            field(qField, FloatingPointFormatStyle<Double>().precision(.fractionLength(2)), width: 50)
        }
        .monospacedDigit()
        .font(.callout)
    }
}

/// SwiftUI's segmented Picker makes every segment as wide as "Custom"; this one fits each label.
struct PresetControl: NSViewRepresentable {
    let labels: [String]
    let tooltips: [String]
    var selected: Int?
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                   target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        c.segmentDistribution = .fit
        for i in labels.indices.dropFirst() { c.setWidth(34, forSegment: i) }
        for (i, tip) in tooltips.enumerated() { c.setToolTip(tip, forSegment: i) }
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        context.coordinator.onSelect = onSelect
        c.selectedSegment = selected ?? -1
        c.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect) }

    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void
        init(_ onSelect: @escaping (Int) -> Void) { self.onSelect = onSelect }
        @objc func changed(_ c: NSSegmentedControl) { onSelect(c.selectedSegment) }
    }
}

struct ContentView: View {
    @StateObject private var m = Model()
    // ponytail: preset count unknown (names live on Moondrop's cloud); 0...5 shown, device rejects invalid ones
    private let presets = 0...5
    private var builtIn: Bool { (m.preset ?? 0) != 0 }
    private var preampField: Binding<Double> {
        Binding(get: { m.preamp }, set: { m.preamp = (($0 * 10).rounded() / 10).clamped(to: preampRange) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Circle().fill(m.connected ? Color.green : Color.secondary).frame(width: 9, height: 9)
                Text(m.connected ? "ECHO-B connected" : "Plug in ECHO-B…").font(.headline)
                Spacer()
                if m.busy { ProgressView().controlSize(.small); Text("Working…").font(.caption).foregroundStyle(.secondary) }
                Button { m.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!m.connected || m.busy)
                    .help("Re-read device")
            }

            PresetControl(labels: presets.map { $0 == 0 ? "Custom" : "\($0)" },
                          tooltips: presets.map { $0 == 0 ? "Your own 9-band EQ, editable below"
                                                          : "Built-in Moondrop tuning \($0), read-only. Switches right away." },
                          selected: m.preset) { m.select($0) }
                .fixedSize()
                .disabled(!m.connected || m.busy)

            HStack {
                if builtIn, let p = m.preset {
                    Text("Preset \(p)").font(.subheadline).foregroundStyle(.secondary)
                    Text("· built-in Moondrop tuning, read-only. Pick Custom to make your own.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Custom PEQ").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Paste EQ") { m.pasteEQ() }
                    .disabled(!m.connected || m.bands.isEmpty || m.busy || builtIn)
                    .help("Paste Parametric EQ text from squig.link or AutoEQ (PK filters, up to 9)")
                Button("Copy EQ") { m.copyEQ() }
                    .disabled(m.bands.isEmpty || builtIn)
                    .help("Copy the bands as Parametric EQ text")
                Button("Reset") { m.resetStandard() }
                    .disabled(!m.connected || m.bands.isEmpty || m.busy || builtIn)
                    .help("Standard 9-band layout: 63 Hz to 16 kHz in octaves, Q 1.41, 0 dB")
            }

            ResponseGraph(bands: $m.bands, dragging: $m.dragging, fixed: builtIn ? m.live : nil, fs: m.sampleRate, preamp: m.preamp)
                .frame(height: 200)
                .disabled(!m.connected || m.bands.isEmpty || m.busy || builtIn)

            HStack(spacing: 6) {
                Text("Preamp").font(.callout).foregroundStyle(.secondary)
                TextField("", value: preampField, format: FloatingPointFormatStyle<Double>().precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 56)
                Text("dB").font(.callout).foregroundStyle(.secondary)
                Button("Auto") { m.autoPreamp() }
                    .help("Set the preamp so the highest point of the curve lands at 0 dB")
                let headroom = m.peak + m.preamp
                if headroom > 0.1 {
                    Label(String(format: "Peaks at +%.1f dB, may clip", headroom), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if m.peak > 0.1 {
                    Label("No clipping", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            .help("""
                Turns the whole signal down before the EQ. Songs are mastered close to the digital maximum (0 dB), \
                so any boost above 0 dB can distort loud parts. Set the preamp to minus the peak (or click Auto) \
                to make room. It's applied inside the ECHO-B's DSP, so it's written along with the bands.
                """)
            .disabled(!m.connected || m.bands.isEmpty || m.busy || builtIn)
            .opacity(builtIn ? 0.35 : 1)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Frequency (Hz)").gridCellColumns(2)
                        .help("Center of the band. Bass is below 250 Hz, mids 250 Hz to 4 kHz, treble above 4 kHz.")
                    Text("Gain (dB)").gridCellColumns(2)
                        .help("How much the band is boosted (+) or cut (−), up to 12 dB. Whole dB steps.")
                    Text("Q").gridCellColumns(2)
                        .help("Width of the band. Low Q (0.5) is wide and gentle, high Q (5+) is narrow and surgical. 1.41 covers one octave.")
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach($m.bands) { $band in
                    BandRow(band: $band, active: m.dragging.map { m.bands[$0].id } == band.id)
                }
            }
            .disabled(!m.connected || m.busy || builtIn)
            .opacity(builtIn ? 0.35 : 1)

            HStack {
                Text(m.dirty ? "Unsaved changes" : "In sync with ECHO-B")
                    .font(.caption).foregroundStyle(m.dirty ? Color.orange : Color.secondary)
                Spacer()
                Button("Revert") { m.revert() }.disabled(!m.dirty || m.busy)
                    .help("Throw away edits and go back to what the ECHO-B has")
                Button("Write to ECHO-B") { m.write() }
                    .help("Save the bands to the dongle's flash and switch to Custom (⌘S). Edits aren't heard until then.")
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!m.connected || !m.dirty || m.busy)
            }
            if let e = m.error { Text(e).font(.callout).foregroundStyle(.red) }
            if let n = m.notice { Text(n).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(20)
        .frame(width: 720)
    }
}

func selfTest() {
    // frame layout must match CnxtUsbCommand.getUSBMessage(1) from the app (and echob.py)
    let m = encode(cmdGetParam, [paramEQMode])
    precondition(m.count == 62)
    precondition(Array(m[0..<14]) == [1, 0, 13, 0, 0x5A, 0x01, 0x00, 0x23, 0x2D, 0xB3, 90, 0, 0, 0])
    precondition(s24(0xFFFFFD) == -3 && s24(6) == 6)
    // coefficients read back from a real ECHO-B after writing 8 kHz / Q 179/256 / -3 dB @ 384 kHz
    let (shift, co) = deviceCoeffs(384000, 8000, 179.0 / 256, -3)
    let ref = [4071986, -7486369, 3478982, 7486369, -3356664]
    precondition(shift == 3 && zip(co, ref).allSatisfy { abs($0 - $1) <= 2 })
    precondition(deviceCoeffs(48000, 1000, 0.7, 0) == (3, [1 << 22, 0, 0, 0, 0]))
    precondition(abs(responseDB([Band(id: 1, freq: 1000, q: 1, gain: 6, type: "Peak")], at: 1000) - 6) < 0.01)
    // live coefficient decode must round-trip the encoder (negative words arrive as 24-bit)
    let (s6, c6) = deviceCoeffs(96000, 1000, 1, -6)
    precondition(abs(responseDB([biquad(Int(s6), c6.map { $0 & 0xFFFFFF })], at: 1000, fs: 96000) + 6) < 0.05)
    // squig.link export (Harman IE 2019 target): OFF filter skipped, shelves rejected, export parses back
    let squig = try! parseEQ("""
        Preamp: -2.8 dB
        Filter 1: ON PK Fc 35 Hz Gain 1.8 dB Q 0.500
        Filter 9: ON PK Fc 15000 Hz Gain -10.4 dB Q 2.000
        Filter 10: OFF PK Fc 0 Hz Gain 0.0 dB Q 0.000
        """)
    precondition(squig.preamp == -2.8 && squig.filters.count == 2 && squig.filters[0] == (35, 1.8, 0.5))
    precondition((try? parseEQ("Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70")) == nil)
    let boosted = [Band(id: 1, freq: 1000, q: 1, gain: 6, type: "Peak")]
    let back = try! parseEQ(exportEQ(boosted, preamp: -6))
    precondition(back.preamp == -6 && back.filters[0] == (1000, 6, 1))
    // preamp baked into a flat band is a pure broadband gain, and can be read back off the live curve
    let (sp, cp) = deviceCoeffs(48000, 1000, 1, 0, preamp: -12)
    let live = [biquad(Int(sp), cp.map { $0 & 0xFFFFFF })]
    precondition(abs(responseDB(live, at: 5000, fs: 48000) + 12) < 0.01)
    precondition(derivedPreamp([Band(id: 1, freq: 1000, q: 1, gain: 0, type: "Peak")], live: live, fs: 48000) == -12)
    print("selftest ok")
}

@main
struct EchoBApp: App {
    init() {
        if CommandLine.arguments.contains("--selftest") { selfTest(); exit(0) }
    }

    var body: some Scene {
        WindowGroup("ECHO-B") { ContentView() }
            .windowResizability(.contentSize)
    }
}
