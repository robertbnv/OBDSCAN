# OBD Scan

An OBD-II scanner app for iPhone (Android later), built with Flutter. It reads the car's
ECUs through a Bluetooth LE or WiFi ELM327-compatible adapter, shows a live gauge dashboard,
records every drive, and runs an on-device monitor that notifies you when something looks wrong.
The selected live values also appear on the CarPlay screen through an iOS Live Activity.

Everything here uses free tools and free accounts.

## What works today

| Area | Status |
| --- | --- |
| Adapter driver (ELM327 commands, CAN 11/29-bit, ISO 9141, KWP, multi-frame, multiple ECUs) | Tested against a simulated adapter (`flutter test`) |
| Automatic vehicle identification (VIN read from the car, decoded offline) | Tested |
| Fault codes: confirmed, pending, permanent, clear, freeze frame, readiness monitors | Tested |
| 9,533 generic fault codes with description, causes, symptoms and repair notes, offline | Tested |
| Live data: 80 decodable parameters, gauges, trend lines, min/max, metric and imperial | Tested, runs in the browser demo |
| Monitor: 17 safety rules plus learning each car's normal values | Tested |
| Drive recording to CSV | Written; file saving only runs on a phone |
| Bluetooth LE and WiFi links | Written, not yet tried with a real adapter |
| iPhone build, notifications, Live Activity on CarPlay | Written, **not yet compiled** (needs the cloud Mac build below) |
| Android | Not configured yet |

## Try it now on this PC

The demo car is a simulated vehicle with live data, stored fault codes and faults you can switch on.

```powershell
E:\tools\flutter\bin\flutter.bat test
```

```powershell
E:\tools\flutter\bin\flutter.bat run -d edge
```

Choose **Start demo**, then open **Assistant** and switch on a fault to watch the monitor react.

## What you need

| Item | Cost | Why |
| --- | --- | --- |
| Bluetooth LE OBD adapter | one-off purchase | See "Choosing an adapter" |
| Apple ID | free | Signs the app for your own iPhone |
| GitHub account | free | Its hosted Macs compile the iPhone app |
| Sideloadly, plus Apple's iTunes for Windows | free | Installs the compiled app from this PC over USB |
| iPhone on iOS 18 or later | | Needed for the Live Activity; iOS 26 or later shows it on CarPlay |

### Choosing an adapter

Buy a **Bluetooth LE** adapter that says it supports iOS.

- iPhones cannot talk to the cheap "classic Bluetooth" ELM327 dongles at all. They pair on Android only.
- WiFi adapters work, but the phone must join the adapter's WiFi network. Wireless CarPlay also uses
  the phone's WiFi, so a WiFi adapter and wireless CarPlay cannot be used together.
- iOS only keeps the app running in the background for Bluetooth LE, which the CarPlay view needs
  while the phone is locked.

Adapters known for iOS support include OBDLink CX, Vgate iCar Pro BLE 4.0 and Veepeak OBDCheck BLE+.
The app looks for the serial profiles these use, but none has been tried with it yet. If one does
not connect, **Settings › Adapter log** shows the raw conversation.

## Putting it on your iPhone (free route)

1. Create a GitHub repository and push this folder to its `main` branch.
2. On GitHub open **Actions › iOS build**. It runs on every push; when it finishes, download the
   `obdscan-unsigned-ipa` artifact and unzip it to get `obdscan-unsigned.ipa`.
3. On the iPhone enable **Settings › Privacy & Security › Developer Mode**.
4. Connect the iPhone by USB, open Sideloadly, drop the `.ipa` in, enter your Apple ID and install.
5. On the iPhone trust the certificate under **Settings › General › VPN & Device Management**.

Limits of a free Apple ID: the app stops opening after 7 days until Sideloadly re-signs it
(it can do this automatically over WiFi), and at most three such apps can be installed at once.
Private GitHub repositories get about 200 free Mac minutes a month, roughly a dozen builds;
public repositories are unlimited.

Sideloadly is a third-party tool that receives your Apple ID password. Many people use a separate
Apple ID for it.

## CarPlay

Apple only lets approved apps put their own screens on CarPlay. That approval (the "driving task"
entitlement) needs the paid Apple Developer Program at 99 USD a year plus a review by Apple, and even
then apps may only show Apple's text templates, not gauges.

This app therefore uses a **Live Activity**: while connected it shows the first four dashboard values
and any active alert on the Lock Screen and in the Dynamic Island, and from iOS 26 the system shows
Live Activities on the CarPlay Dashboard without any entitlement. Monitor alerts also arrive as
normal notifications, which CarPlay displays.

If you later join the paid program, a full CarPlay app with a value list can be added on top.

## The monitor

`lib/monitor/` runs entirely on the phone and costs nothing to run.

- **Fixed rules** fire when a reading stays out of range: overheating, engine not warming up, battery
  not charging, overcharging, lean or rich mixture, unstable idle, implausible sensor readings,
  catalyst and oil overheating, low fuel, and new fault codes appearing during a drive.
- **Learned normal values**: after three drives it knows this car's usual idle speed, intake vacuum,
  idle air flow, fuel trims, charging voltage and running temperature, and reports drift from them.

Thresholds are deliberately conservative to avoid false alarms and live in `MonitorThresholds`.

## What it does not do

A professional tool such as a Topdon scanner also reads manufacturer-specific systems (ABS, airbag,
transmission, body modules) and can run service functions and actuator tests. Those use licensed,
per-manufacturer data that is not publicly available. This app covers the full standardised OBD-II
feature set that every car since about 2001 (petrol, EU) / 1996 (US) supports.

## Project layout

| Path | Contents |
| --- | --- |
| `lib/obd/` | Adapter driver, frame parser, parameter table, fault codes, VIN, client, live poller |
| `lib/obd/sim/` | Simulated car and adapter used by the demo and the tests |
| `lib/connect/` | Bluetooth LE and WiFi links |
| `lib/monitor/` | Monitoring rules and baseline learning |
| `lib/record/` | CSV drive recorder |
| `lib/app/` | App state, units, notifications, Live Activity bridge |
| `lib/ui/` | Screens |
| `assets/dtc/` | Fault-code database, generated by `tool/build_dtc_assets.py` |
| `ios/ObdLiveActivity/` | The Live Activity (SwiftUI) |
| `ios/tool/add_live_activity_target.rb` | Adds the Live Activity to the Xcode project during the cloud build |
| `.github/workflows/ios.yml` | Cloud build of the iPhone app |

Fault-code descriptions come from the [OBDex](https://github.com/foerbsnavi/OBDex) dataset (CC0-1.0).
