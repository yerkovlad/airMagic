# AirMagic

Point your Mac's cursor with the **AirPods charging case**. Move the closed case to
move the cursor, knock on it (or hold still) to click.

AirMagic is a small macOS menu bar app written in Swift. It talks to the AirPods
over Bluetooth, reads the accelerometer and gyroscope that keep streaming while
the earbuds sit in the closed case, and turns that motion into pointer movement.

> **Unofficial and experimental.** AirMagic is not affiliated with or endorsed by
> Apple. It uses an undocumented Bluetooth protocol and private macOS APIs. Read
> [Side effects](#side-effects) before you use it.

## Status

Tested on one Mac (macOS 26, Apple Silicon) with one pair of AirPods 4. Other
AirPods models that have a charging case (AirPods Pro 2/3, AirPods 4 with ANC) are
accepted by the code but untested. Expect rough edges.

## Requirements

- macOS 14 or later (built and tested on Apple Silicon only)
- Xcode command line tools (`xcode-select --install`) to build
- AirPods paired with the Mac (AirPods Max are not supported: no case)

## Install

```sh
git clone git@github.com:yerkovlad/airMagic.git
cd airMagic
zsh ./install.sh
```

`install.sh` builds the app, runs the offline self-test, copies `AirMagic.app` to
`/Applications` and opens it. To only build, run `zsh ./build.sh` and open
`AirMagic.app` from the project folder.

On first launch macOS asks for two permissions:

| Permission | Why |
|---|---|
| **Bluetooth** | to talk to the AirPods |
| **Accessibility** | to move the cursor and click (System Settings → Privacy & Security → Accessibility) |

The app is signed ad hoc with a fixed designated requirement
(`identifier "local.airmagic"`), so both permissions survive rebuilds.

## Use

1. Put both AirPods in the case, **open the lid** near the Mac, and make sure the
   AirPods are connected to this Mac (not to your iPhone).
2. Click the 🧲 icon in the menu bar → **Connect** (or just open AirMagic again
   from Launchpad/Spotlight while it runs). Audio drops for a moment while the
   link is re-established.
3. **Close the lid** and put the case down, upright, light facing you. Hold it
   still until the prompt changes.
4. **Calibrate.** Three red dots appear in turn: the middle, the right edge and
   the top edge. Point the case at each dot and **hold it steady**: the step
   confirms itself after about a second (a tap or `⌃⌥Space` also works).
5. Move the case to move the cursor. Knock on the front of the case to click.

Saved calibration is reused next time; you only re-confirm the middle point.

### Emergency stop

| Keys | Action |
|---|---|
| `⌃⌥Esc` | Stop everything now and give the cursor back (works in any app) |
| `⌃⌥P` | Pause / resume |
| `⌃⌥Space` | Confirm a calibration step |

### Menu

| Item | What it does |
|---|---|
| Connect / Disconnect | Starts or stops the session |
| Confirm step | Confirms the current calibration step |
| Recenter | Sets the middle point again, keeping the edges |
| Recalibrate | Forgets the saved calibration and aims all three dots again |
| Pause | Stops moving the cursor without disconnecting |
| AirPods | Chooses which paired AirPods to use (connected ones are listed first) |
| Tap to click | Cycles the knock sensitivity (0.25 / 0.40 / 0.15 g / off) |
| Test taps… | Knock three times; sets the threshold from your knocks and the sensor noise |
| Click by holding still | Clicks when the cursor rests in place (off, 0.7 s, 1.0 s, 1.5 s) |
| Accessibility | Shows whether the permission is granted |

The first line of the menu shows live status (for example the pointer position
and the sample rate while pointing).

## Side effects

AirMagic reaches the case the same way other tools of this kind do, and that has
consequences:

- **Audio drops.** Each connect drops the AirPods' Bluetooth link for a moment.
  Do not connect during a call.
- **Case diagnostics are used up.** To keep the sensor stream alive while the lid
  is closed, AirMagic accepts the diagnostic asset the case offers and releases it
  on exit. Releasing it can consume the diagnostic records staged on the case.
- **Private APIs.** It uses private IOBluetooth selectors. Any macOS update may
  break it, and it checks each selector before use so it fails with a message
  instead of crashing.
- **No guarantees.** Nothing here is tested against sleep/wake, Bluetooth loss
  during a session, or calls. Use it at your own risk.

## Troubleshooting

Every session writes a log to
`~/Library/Application Support/AirMagic/link.log` (replaced on each connect).

| Message | Meaning |
|---|---|
| code 20 | Bluetooth permission not granted |
| code 22 / 23 | The AirPods are not paired / not connected to this Mac |
| code 24 | macOS changed its private Bluetooth internals |
| code 25 | Another app (for example another pointer tool) owns the AirPods channel |
| code 27 / 28 | No control channel, or the AirPods did not answer: reopen the lid and retry |
| code 30 | No motion data: the AirPods may also be connected to an iPhone |
| code 43 / 44 | The stream stopped or the link dropped |
| "Lost the AirPods" | No data for 3 seconds; the connection is reported as lost |

If the cursor races around after calibration, press `⌃⌥Esc`, then connect again
and hold the case still on each dot. If it drifts over time, use **Recenter**.

## How it works

One executable, three modes:

```
AirMagic                  the menu bar app
AirMagic --link ADDRESS   the Bluetooth child process the app starts
AirMagic --self-test      offline checks (no AirPods needed)
```

| File | What it does |
|---|---|
| `Sources/Wire.swift` | Packet framing, protobuf helpers, message builders |
| `Sources/Session.swift` | The earbud / case conversation, free of I/O so it can be tested |
| `Sources/Link.swift` | Child process: opens the AirPods control channel (L2CAP PSM 0x1001), starts the sensors, streams samples |
| `Sources/Pointing.swift` | Pose from gyro + accelerometer, aiming, smoothing, tap detection |
| `Sources/Overlay.swift` | On-screen prompts and the calibration dot |
| `Sources/App.swift` | Menu bar app: link control, calibration, cursor, clicks |
| `Sources/SelfTest.swift` | Offline checks |

In short: the app opens the AirPods control channel right after a fresh
reconnect, starts the accelerometer and gyroscope, and keeps the stream alive with
a once-a-second conversation with the earbud and the case (the case would
otherwise close the stream a few seconds after the lid shuts). The pose is
integrated from the gyroscope and pulled toward gravity by the accelerometer; a
three-point calibration maps it to the screen; a One Euro filter smooths it.

## Development

```sh
zsh ./build.sh        # build + sign + run the self-test
./AirMagic.app/Contents/MacOS/AirMagic --self-test
```

The self-test covers the wire format byte for byte, the case conversation against
simulated replies, the pose maths, the aiming and the tap detector. It does not
cover real AirPods.

To see the link talking, run the app from a terminal:

```sh
./AirMagic.app/Contents/MacOS/AirMagic
```

## Credits

The knowledge of how the AirPods control channel behaves (the channel and its
handshake, the sensor-start message, the case keep-alive) comes from reading
[oscarcreatess/airpointer](https://github.com/oscarcreatess/airpointer) (MIT),
whose author reverse-engineered it. AirMagic contains no code from that project;
`Wire.swift` and `Session.swift` are an independent implementation.

## License

[MIT](LICENSE)
