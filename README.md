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

Plug in the ECHO-B and open the app. Most buttons and column headers have a tooltip if you hover over them.

### Presets

The row at the top picks what the dongle plays:

- **Custom** is your own 9-band EQ. It's the only one you can edit.
- **1 to 5** are Moondrop's built-in tunings. Clicking one switches the dongle right away. The graph shows the real curve the dongle is running (read from the DSP), but you can't edit it. All five only cut, they never boost: 1 is a light treble trim, 2 and 3 pull down the mids and treble so the bass stands out, 4 scoops the mids, and 5 takes out bass and low mids so it sounds brighter.

### Editing the Custom EQ

Pick Custom, then either drag the dots on the graph (left/right is frequency, up/down is gain) or type values into the table. Each band has three settings:

| Setting | What it does |
|---|---|
| Frequency (Hz) | The center of the band. Bass is below 250 Hz, mids are 250 Hz to 4 kHz, treble is above 4 kHz. |
| Gain (dB) | How much that band is boosted (+) or cut (−), up to 12 dB, in whole dB steps. |
| Q | How wide the band is. A low Q (0.5) is wide and gentle, a high Q (5 or more) is narrow and only touches a small range. 1.41 is exactly one octave. |

Nothing is sent to the dongle until you hit **Write to ECHO-B** (⌘S), so you won't hear your edits until then. **Revert** throws away your edits. **Reset** puts every band back on a standard 9-band layout: 63, 125, 250, 500 Hz, 1, 2, 4, 8, 16 kHz, Q 1.41, all at 0 dB.

Only peak filters work right now. Shelf, low pass, and high pass aren't supported yet.

### Importing an EQ from squig.link or AutoEQ

Sites like [squig.link](https://squig.link) (graph.hangout.audio, for example) and [AutoEQ](https://autoeq.app) can work out an EQ that makes your headphones or IEMs match a target such as Harman. To use one:

1. On squig.link, pick your IEM and a target, open the Equalizer panel, run AutoEQ, and copy the Parametric EQ text. It looks like this:
   ```
   Preamp: -2.8 dB
   Filter 1: ON PK Fc 35 Hz Gain 1.8 dB Q 0.500
   Filter 2: ON PK Fc 100 Hz Gain -1.2 dB Q 2.000
   ...
   ```
2. In the app, pick Custom and click **Paste EQ**.
3. Check the curve, then **Write to ECHO-B**.

The app takes up to 9 filters (the ECHO-B has 9 bands), skips filters marked OFF, and rounds gains to whole dB. It refuses EQs that use shelf filters (LSC/HSC) for now. squig.link's AutoEQ gives you peak filters, but AutoEQ's own files often start or end with a shelf.

**Copy EQ** does the reverse: it copies your bands in the same format, so you can paste them into squig.link or Equalizer APO.

### Preamp and clipping

Songs are mastered close to the digital maximum (0 dB). If your EQ boosts anything above 0 dB, loud parts can clip and sound harsh or crackly. The preamp turns the whole signal down before the EQ to make room. It's −2.8 dB rather than −4.3 dB in the example above because neighbouring filters partly cancel each other out, so the summed curve only peaks at +2.8 dB.

The **Preamp** field sits under the graph. Type a value (0 to −12 dB) or click **Auto** to set it to just enough that the highest point of the curve lands at 0 dB. Next to it, an orange "Peaks at +X dB, may clip" warning shows up if there still isn't enough room. Paste EQ takes the preamp from the file, but since gains get rounded to whole dB, it's worth clicking Auto afterwards.

The ECHO-B doesn't have a preamp setting of its own, so the app builds it into band 1's filter coefficients, which means it runs inside the DSP and gets written along with the bands. When the app reads the EQ back, it works the preamp out from the coefficients the dongle is running. The official Android app doesn't know about this, so if you save from there, the preamp is gone.

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
| 446 | `[0, band]` | read live coefficients: band @14, shift @18, `[B0, B1, B2, -a1, -a2]` @22 (24-bit) |

Coefficient slots: 4 = 44.1k, 5 = 48k, 6 = 96k, 7 = 192k, 8 = 384k. Filter types: 0 peak, 1 low shelf, 2 high shelf, 3 low pass, 4 high pass.

Don't send 446 with a slot other than 0. The dongle locks up and you have to replug it.

446 returns whatever the DSP is running, so it's the only way to see what presets 1 to 5 actually do (477 only returns the Custom params). After switching presets, wait about half a second: reads made right away still return the old preset's coefficients. They're for the current sample rate, and param 62 returns its index using the same numbering as the slots.

The device doesn't compute filters itself. You send it RBJ peaking biquads normalized by a0, stored as `[b0, b1, b2, -a1, -a2]`. Take `n = floor(log2(max|coef|)) + 1`, store each value as `round(coef * 2^(23-n))`, and send `n + 2` as the shift byte. A band with 0 dB gain is stored as `[2^22, 0, 0, 0, 0]` with shift 3. Shift 2 (n = 0) works too. The app uses it for the preamp, which scales band 1's `b0, b1, b2` by `10^(preamp/20)`.

To save, I do what the app does:

1. Send the params for each band and wait for each reply.
2. Send the coefficients for each band in all 5 slots without waiting, except for the last one.
3. Commit with `[255]`.
4. Switch to another preset, then to preset 0 and commit again. The DSP only reloads coefficients when the mode actually changes, so switching to 0 while already on 0 doesn't load the new ones.

Things that didn't work: WebHID can't do an input GET_REPORT, so a web version is out. The SPV, Comture, and Jiu protocols aren't the right ones for this chip. The firmware version command (259) just returns an error.
