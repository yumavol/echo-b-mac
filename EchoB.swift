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
let paramEQMode: UInt32 = 90
let slotRates: [(UInt32, Double)] = [(4, 44100), (5, 48000), (6, 96000), (7, 192000), (8, 384000)]
let filterNames = [0: "Peak", 1: "Low shelf", 2: "High shelf", 3: "Low pass", 4: "High pass"]
let gainRange = -12.0...12.0, freqRange = 20.0...20000.0, qRange = 0.2...10.0

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
func deviceCoeffs(_ fs: Double, _ freq: Double, _ q: Double, _ gain: Double) -> (UInt32, [Int]) {
    if gain == 0 { return (3, [1 << 22, 0, 0, 0, 0]) }      // device stores flat bands as identity
    let c = peakCoeffs(fs, freq, q, gain)
    let co = [c[0], c[1], c[2], -c[3], -c[4]]
    let n = Int(floor(log2(co.map(abs).max()!))) + 1
    let scale = pow(2.0, Double(23 - n))
    return (UInt32(n + 2), co.map { Int(($0 * scale).rounded()) })
}

/// Summed magnitude response of all bands in dB (display only, 48 kHz).
func responseDB(_ bands: [Band], at f: Double) -> Double {
    let fs = 48000.0, w = 2 * Double.pi * f / fs
    let cw = cos(w), sw = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
    return bands.reduce(0) { sum, b in
        let c = peakCoeffs(fs, Double(b.freq), b.q, Double(b.gain))
        let nr = c[0] + c[1] * cw + c[2] * c2, ni = -(c[1] * sw + c[2] * s2)
        let dr = 1 + c[3] * cw + c[4] * c2, di = -(c[3] * sw + c[4] * s2)
        return sum + 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}

struct HIDError: Error, CustomStringConvertible { let description: String }

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
    }

    /// Same sequence as the app's saveEQParamsToFlash(custom): params, coefficients per rate slot, commit.
    func savePEQ(_ bands: [Band]) throws {
        for b in bands {
            _ = try xfer(cmdSave, [0, UInt32(b.id), UInt32(b.freq), UInt32(Int(b.q * 256)), 0,
                                   UInt32(bitPattern: Int32(b.gain))])
        }
        var writes: [[UInt32]] = []
        for b in bands {
            for (slot, fs) in slotRates {
                let (shift, co) = deviceCoeffs(fs, Double(b.freq), Double(Int(b.q * 256)) / 256, Double(b.gain))
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
    @Published var busy = false
    @Published var error: String?
    @Published var dragging: Int?               // band dot being dragged in the graph

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let queue = DispatchQueue(label: "echob.hid")
    private var timer: Timer?

    var dirty: Bool { bands != savedBands }

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
        if present { refresh() } else { preset = nil; bands = []; savedBands = []; error = nil }
    }

    func refresh() { run { _ in } }

    func select(_ index: Int) { run { try $0.setPreset(index) } }

    /// Writes the edited Custom PEQ to flash and switches to it.
    func write() {
        guard connected, dirty else { return }
        let snapshot = bands
        run {
            try $0.savePEQ(snapshot)
            try $0.setPreset(0)
        }
    }

    func revert() { bands = savedBands }

    func resetFlat() {
        for i in bands.indices { bands[i].gain = 0 }
    }

    // Runs a device action off the main thread, then re-reads state.
    private func run(_ action: @escaping (EchoB) throws -> Void) {
        guard let dev = device(), !busy else { return }
        busy = true
        queue.async {
            let result = Result { () -> (Int, [Band]) in
                try action(dev)
                return (try dev.eqMode(), try dev.peqBands())
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let (mode, bands)):
                    self.preset = mode
                    self.bands = bands
                    self.savedBands = bands
                    self.error = nil
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

    private func px(_ f: Double, _ w: Double) -> Double { log10(f / freqRange.lowerBound) / 3 * w }
    private func fx(_ x: Double, _ w: Double) -> Double {
        min(max(freqRange.lowerBound * pow(1000, x / w), freqRange.lowerBound), freqRange.upperBound)
    }
    private func py(_ db: Double, _ h: Double) -> Double { (gainRange.upperBound - db) / 24 * h }

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
                    ctx.draw(Text("\(Int(db))").font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: 10, y: py(db, h) - 7))
                }
                var curve = Path()
                for sx in stride(from: 0.0, through: w, by: 2) {
                    let db = min(max(responseDB(bands, at: fx(sx, w)), -13), 13)
                    let pt = CGPoint(x: sx, y: py(db, h))
                    if sx == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                }
                ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2)
                for (i, b) in bands.enumerated() {
                    let c = CGPoint(x: px(Double(b.freq), w), y: py(Double(b.gain), h))
                    let r: Double = dragging == i ? 9 : 7
                    let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    ctx.fill(dot, with: .color(b.gain == 0 ? .gray : .accentColor))
                    ctx.draw(Text("\(b.id)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white), at: c)
                }
            }
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
                    bands[i].gain = Int((gainRange.upperBound - g.location.y / h * 24).rounded()).clamped(to: -12...12)
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

    private var logFreq: Binding<Double> {
        Binding(get: { log10(Double(band.freq)) }, set: { band.freq = Int(pow(10, $0).rounded()) })
    }
    private var logQ: Binding<Double> {
        Binding(get: { log10(band.q) }, set: { band.q = (pow(10, $0) * 256).rounded() / 256 })
    }
    private var gain: Binding<Double> {
        Binding(get: { Double(band.gain) }, set: { band.gain = Int($0.rounded()) })
    }
    var body: some View {
        GridRow {
            Text("\(band.id)").font(.callout.bold()).foregroundStyle(.secondary)
            Slider(value: logFreq, in: log10(freqRange.lowerBound)...log10(freqRange.upperBound))
            Text(band.freq >= 1000 ? String(format: "%.2fk", Double(band.freq) / 1000) : "\(band.freq)")
                .frame(width: 48, alignment: .trailing)
            Slider(value: gain, in: gainRange, step: 1)
            Text("\(band.gain > 0 ? "+" : "")\(band.gain) dB")
                .foregroundStyle(band.gain == 0 ? Color.secondary : Color.primary)
                .frame(width: 48, alignment: .trailing)
            Slider(value: logQ, in: log10(qRange.lowerBound)...log10(qRange.upperBound))
            Text(String(format: "%.2f", band.q)).frame(width: 36, alignment: .trailing)
        }
        .monospacedDigit()
        .font(.callout)
    }
}

struct ContentView: View {
    @StateObject private var m = Model()
    // ponytail: preset count unknown (names live on Moondrop's cloud); 0...5 shown, device rejects invalid ones
    private let presets = 0...5

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

            HStack(spacing: 8) {
                Text("Preset").font(.subheadline).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                ForEach(Array(presets), id: \.self) { i in
                    Button { m.select(i) } label: { Text(i == 0 ? "Custom" : "\(i)").frame(minWidth: 40) }
                        .buttonStyle(.borderedProminent)
                        .tint(i == m.preset ? .accentColor : .gray.opacity(0.35))
                        .disabled(!m.connected || m.busy)
                }
            }

            HStack {
                Text("Custom PEQ").font(.subheadline).foregroundStyle(.secondary)
                if let p = m.preset, p != 0 {
                    Text("· preset \(p) active, editing switches to Custom").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset flat") { m.resetFlat() }.disabled(!m.connected || m.bands.isEmpty || m.busy)
            }

            ResponseGraph(bands: $m.bands, dragging: $m.dragging)
                .frame(height: 200)
                .disabled(!m.connected || m.bands.isEmpty || m.busy)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Frequency").gridCellColumns(2)
                    Text("Gain").gridCellColumns(2)
                    Text("Q").gridCellColumns(2)
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach($m.bands) { $band in BandRow(band: $band) }
            }
            .disabled(!m.connected || m.busy)

            HStack {
                Text(m.dirty ? "Unsaved changes" : "In sync with ECHO-B")
                    .font(.caption).foregroundStyle(m.dirty ? Color.orange : Color.secondary)
                Spacer()
                Button("Revert") { m.revert() }.disabled(!m.dirty || m.busy)
                Button("Write to ECHO-B") { m.write() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!m.connected || !m.dirty || m.busy)
            }
            if let e = m.error { Text(e).font(.callout).foregroundStyle(.red) }
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
