# ECHO-B for Mac

A small macOS app for changing the presets and PEQ on the Moondrop ECHO-B. The official MOONDROP app is Android only, and I didn't want to grab a phone every time I wanted to tweak the EQ, so I reverse engineered the USB protocol and wrote this.

> [!WARNING]
> Use at your own risk. Saving writes to the dongle's flash, and the protocol isn't documented anywhere, so I can't promise it won't hang or break your device. There's no warranty and I'm not responsible if something goes wrong. If it stops responding, unplug it and plug it back in. The official Android app can reset the EQ if you need it.
>
> Turn the volume down before you try a new EQ. A big boost can get loud fast.

This isn't an official Moondrop project and they have nothing to do with it. The repo doesn't include any of their code or firmware.

## Install

Download `ECHO-B.zip` from the [latest release](../../releases/latest), unzip it, and drag `ECHO-B.app` into Applications.

The app isn't signed with an Apple developer account, so macOS will block it the first time. Try to open it once, then go to System Settings → Privacy & Security and click "Open Anyway". Or run this in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/ECHO-B.app
```

It needs macOS 14 or newer and works on both Apple Silicon and Intel Macs.

## Using it

Plug in the ECHO-B and open the app. You can switch between the Custom preset (0) and presets 1 to 5. To edit the custom EQ, drag the dots on the graph or use the sliders.

Nothing is sent to the dongle until you hit "Write to ECHO-B" (⌘S). "Revert" undoes your edits, and "Reset flat" sets every band back to 0 dB.

Only peak filters work right now. Shelf, low pass, and high pass aren't supported yet.

## CLI

There's also a Python script, which is where the protocol work started:

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python echob.py status      # current preset and PEQ bands
.venv/bin/python echob.py preset 2    # switch to preset 2
```

## Building

You need Xcode or the Command Line Tools (`xcode-select --install`).

```sh
./build.sh        # makes ECHO-B.app and ECHO-B.zip
./build.sh 1.1    # same, with version 1.1
```

The Command Line Tools don't include the SwiftUI macro plugin, so the code uses `ObservableObject` instead of `@State`.

To publish a release:

```sh
./build.sh 1.1
gh release create v1.1 ECHO-B.zip --title v1.1 --notes "..."
```

## Protocol notes

These are my notes from digging through the Android app, in case anyone wants to port this to Linux or Windows.

The device is VID `0x35D8`, PID `0x149B`, and commands go over HID interface 3. It uses a Conexant chip (the app calls it "Freeman3"). Report ID 1 carries commands and report ID 2 is the volume keys. There's no OUT endpoint, so everything goes through control transfers:

- send: SET_REPORT `0x21, 9, wValue 0x0201, wIndex 3`
- receive: GET_REPORT `0xA1, 1, wValue 0x0101, wIndex 3`, polled until `byte[5] & 0x80` is set. If the int16 at bytes 2–3 is negative, that's an error.

A frame is 62 bytes: `01 00`, then u32 LE `13 | cmd<<16`, then u32 LE `cafID("CTRL")` (`00 23 2D B3`), then 13 u32 LE data words. Replies start at offset 14.

| cmd | data | what it does |
|---|---|---|
| 346 | `[90]` | get active preset |
| 346 | `[62]` | get sample rate index |
| 90 | `[90, idx]` | switch preset (also makes the DSP reload coefficients) |
| 477 | `[band]` | read PEQ band 1–9: freq @18, q·256 @22, type @26, gain @30 (24-bit signed) |
| 220 | `[0, band, freq, q·256, type, gain]` | save band params |
| 220 | `[slot, band, shift, B0, B1, B2, -a1, -a2]` | save coefficients for one sample rate |
| 220 | `[255]` | commit to flash |
| 446 | `[0, band]` | read live coefficients |

Coefficient slots: 4 = 44.1k, 5 = 48k, 6 = 96k, 7 = 192k, 8 = 384k. Filter types: 0 peak, 1 low shelf, 2 high shelf, 3 low pass, 4 high pass.

Don't send 446 with a slot other than 0. The dongle locks up and you have to replug it.

The device doesn't compute filters itself. You send it RBJ peaking biquads normalized by a0, stored as `[b0, b1, b2, -a1, -a2]`. Take `n = floor(log2(max|coef|)) + 1`, store each value as `round(coef * 2^(23-n))`, and send `n + 2` as the shift byte. A band with 0 dB gain is stored as `[2^22, 0, 0, 0, 0]` with shift 3.

To save, I do what the app does:

1. Send the params for each band and wait for each reply.
2. Send the coefficients for each band in all 5 slots without waiting, except for the last one.
3. Commit with `[255]`.
4. Switch to preset 0 and commit again. Without this step the new coefficients don't actually load.

Things that didn't work: WebHID can't do an input GET_REPORT, so a web version is out. The SPV, Comture, and Jiu protocols aren't the right ones for this chip. The firmware version command (259) just returns an error.
