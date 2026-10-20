#!/usr/bin/env python3
"""Moondrop ECHO-B control from macOS (no Android needed).

Protocol: Conexant "CAF" commands over HID report ID 1 on interface 3,
reverse engineered from the MOONDROP Android app (device family "Freeman3").

  python echob.py status        # active preset + custom PEQ bands
  python echob.py preset N      # switch to preset N and save it to flash
"""
import math
import struct
import sys
import time

import hid

VID, PID = 0x35D8, 0x149B
REPORT_ID = 1
WORDS = 13                      # every app command pads data to 13 words -> 62-byte report

CMD_SET_PARAM = 90              # switchEQMode: data [90, index]
CMD_GET_PARAM = 346             # CONTROL_MGR_GET_PARAMETER_VALUE: data [param]
CMD_GET_PEQ_BAND = 477          # data [band 1..9]
CMD_SAVE = 220                  # data [255] commits current state to flash
PARAM_EQ_MODE = 90
FILTER_TYPES = {0: "peak", 1: "lowshelf", 2: "highshelf", 3: "lowpass", 4: "highpass"}


def caf_id(name):
    b = name.encode()
    return ((b[0] - 32) << 8) | ((b[1] - 32) << 14) | ((b[2] - 32) << 20) | ((b[3] - 32) << 26)


CTRL = caf_id("CTRL")


def encode(cmd, data):
    data = list(data) + [0] * (WORDS - len(data))
    head = struct.pack("<BBII", REPORT_ID, 0, WORDS | (cmd << 16), CTRL)
    return head + b"".join(struct.pack("<I", w & 0xFFFFFFFF) for w in data)


def i32(buf, off):
    return struct.unpack_from("<i", buf, off)[0]


def s24(v):
    # device stores PEQ gain as a 24-bit signed value
    v &= 0xFFFFFF
    return v - (1 << 24) if v & 0x800000 else v


SLOT_RATES = {4: 44100, 5: 48000, 6: 96000, 7: 192000, 8: 384000}   # flash coefficient slots


def design_peak(fs, freq, q, gain):
    """RBJ peaking biquad in the device's fixed point (matches the app's native EqDesignFx).
    Returns (shift byte, [B0, B1, B2, -a1, -a2])."""
    if gain == 0:
        return 3, [1 << 22, 0, 0, 0, 0]               # device stores flat bands as identity
    A = 10 ** (gain / 40)
    w = 2 * math.pi * freq / fs
    alpha, c = math.sin(w) / (2 * q), math.cos(w)
    a0 = 1 + alpha / A
    co = [(1 + alpha * A) / a0, -2 * c / a0, (1 - alpha * A) / a0, 2 * c / a0, -(1 - alpha / A) / a0]
    n = math.floor(math.log2(max(abs(x) for x in co))) + 1
    return n + 2, [round(x * 2 ** (23 - n)) for x in co]


class EchoB:
    def __init__(self):
        self.h = hid.device()
        try:
            self.h.open(VID, PID)
        except OSError:
            sys.exit("ECHO-B not found. Plug it in (and close other apps using it).")

    def xfer(self, cmd, data=()):
        out = encode(cmd, data)
        self.h.write(out)
        deadline = time.time() + 1
        while time.time() < deadline:
            try:
                r = bytes(self.h.get_input_report(REPORT_ID, len(out)))
            except OSError:                          # device busy; the app also just keeps polling
                r = b""
            if len(r) > 5 and r[5] & 0x80:          # reply bit set
                if struct.unpack_from("<h", r, 2)[0] < 0:
                    raise RuntimeError(f"device rejected cmd {cmd}: {r[:10].hex()}")
                return r
            time.sleep(0.005)
        raise RuntimeError(f"no reply for cmd {cmd}")

    def eq_mode(self):
        return i32(self.xfer(CMD_GET_PARAM, [PARAM_EQ_MODE]), 14)

    def peq_bands(self):
        for band in range(1, 10):
            r = self.xfer(CMD_GET_PEQ_BAND, [band])
            yield {
                "band": i32(r, 14), "freq": i32(r, 18), "q": round(i32(r, 22) / 256, 2),
                "type": FILTER_TYPES.get(i32(r, 26), i32(r, 26)), "gain": s24(i32(r, 30)),
            }

    def send(self, cmd, data):
        # fire-and-forget like the app's coefficient writes: one read, reply not awaited
        self.h.write(encode(cmd, data))
        try:
            self.h.get_input_report(REPORT_ID, 62)
        except OSError:
            pass

    def save_peq(self, bands):
        """bands: [{band, freq, q, gain}] peaking filters; writes params + coefficients to flash."""
        for b in bands:
            self.xfer(CMD_SAVE, [0, b["band"], b["freq"], int(b["q"] * 256), 0, int(b["gain"])])
        writes = [(b, idx, fs) for b in bands for idx, fs in SLOT_RATES.items()]
        for i, (b, idx, fs) in enumerate(writes):
            gb, co = design_peak(fs, b["freq"], int(b["q"] * 256) / 256, b["gain"])
            (self.xfer if i == len(writes) - 1 else self.send)(CMD_SAVE, [idx, b["band"], gb] + co)
        self.xfer(CMD_SAVE, [255])

    def set_preset(self, index):
        self.xfer(CMD_SET_PARAM, [PARAM_EQ_MODE, index])
        self.xfer(CMD_SAVE, [255])


def main(argv):
    if len(argv) < 2 or argv[1] not in ("status", "preset"):
        sys.exit(__doc__)
    dev = EchoB()
    if argv[1] == "preset":
        if len(argv) != 3 or not argv[2].isdigit():
            sys.exit("usage: echob.py preset N   (0 = custom PEQ)")
        dev.set_preset(int(argv[2]))
    print("active preset:", dev.eq_mode(), "(0 = custom PEQ)")
    if argv[1] == "status":
        for b in dev.peq_bands():
            print("  band {band}: {type:9} {freq:>5} Hz  Q {q:<5} gain {gain:+d} dB".format(**b))


def _selftest():
    # frame layout must match CnxtUsbCommand.getUSBMessage(1) from the app
    m = encode(CMD_GET_PARAM, [PARAM_EQ_MODE])
    assert len(m) == 62
    assert m[:6] == bytes([1, 0, 13, 0, 0x5A, 0x01])
    assert m[6:10] == struct.pack("<I", CTRL) == bytes.fromhex("00232db3")
    assert m[10:14] == bytes([90, 0, 0, 0])
    assert s24(0xFFFFFD) == -3 and s24(6) == 6
    # reference: coefficients read back from a real ECHO-B (8 kHz, Q 0.7, -3.5 dB @ 384 kHz)
    gb, co = design_peak(384000, 8000, 0.7, -3.5)
    ref = [4052212, -7466537, 3478754, 7466537, -3336662]
    assert gb == 3 and all(abs(x - y) < 2500 for x, y in zip(co, ref))


if __name__ == "__main__":
    _selftest()
    main(sys.argv)
