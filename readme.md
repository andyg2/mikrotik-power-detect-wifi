# mikrotik-power-detect-wifi

A MikroTik RouterOS script that detects grid power restoration by counting visible WiFi networks, then fires a webhook so downstream automation (Home Assistant, Telegram, etc.) can react.

## How it works

When grid power is out, most of your neighbours' routers go dark and only battery-backed APs remain visible. Your own equipment will also show up - usually with very strong signal (better than -65 dBm) - so the script ignores those and only counts the weak, distant APs that come back when neighbour routers power up. The script:

1. Wakes `wlan1` if it is currently disabled (saves power between checks).
2. Runs a 10-second scan and counts SSIDs whose signal is at or below `signalCutoff` (default -65 dBm).
3. Restores `wlan1` to its prior disabled/enabled state.
4. If the weak-AP count crosses `fireThreshold` and the latch is clear, POSTs a JSON payload to your webhook and sets the latch.
5. Once the weak-AP count falls back to `resetThreshold` or below, the latch resets so the next restoration event will fire again. The gap between the two thresholds gives hysteresis so scan-to-scan jitter cannot re-fire.
6. Scan failures are ignored (they neither fire nor reset the latch).

The latch (`powerRestoredFired`) is a global variable so it survives between scheduled runs but resets on router reboot.

## Requirements

- MikroTik device running RouterOS v6 or v7 with a wireless interface (`wireless` package on v7).
- A webhook endpoint that accepts `POST` with `Content-Type: application/json`.
- The router itself on backup power (UPS or battery), otherwise it cannot detect when grid returns.

## Setup

### 1. Upload the script

Either drag `mikrotik-power-detect-wifi.rsc` onto the router via WinBox/WebFig Files, then import:

```terminal
/import file-name=mikrotik-power-detect-wifi.rsc
```

Or open the file, copy its contents, and paste into a new script:

```terminal
/system/script/add name=mikrotik-power-detect-wifi source=[paste here]
```

### 2. Edit the configuration variables

Open `/system/script/edit mikrotik-power-detect-wifi` (or edit before upload) and set:

| Variable         | Default                 | Purpose                                                                                             |
| ---------------- | ----------------------- | --------------------------------------------------------------------------------------------------- |
| `wifiInterface`  | `wlan1`                 | Name of the wireless interface used for scanning.                                                   |
| `signalCutoff`   | `-65`                   | Signal strength (dBm) at or below which an AP counts as a "weak" neighbour. Stronger APs are yours. |
| `fireThreshold`  | `3`                     | Number of weak APs needed to declare power restored.                                                |
| `resetThreshold` | `0`                     | Weak-AP count at or below which the latch clears, allowing the next restoration to fire.            |
| `webhookUrl`     | example.com placeholder | Your webhook URL, including any auth query params.                                                  |

Pick the cutoff and thresholds by running a manual scan during normal conditions and again (if you can) during an outage:

```terminal
/interface/wireless/scan wlan1 duration=10
```

`signalCutoff` should sit between your strongest neighbour and your weakest own AP. `fireThreshold` should be comfortably below the weak-AP count you see when power is on.

#### Worked example

Two real 10-second scans from the same site, before and after the grid came back, show why the defaults work.

**Power off** (`10s-power-off.txt`) - 6 SSIDs, all your own equipment:

| SSID              | Signal (dBm) | Counted? |
| ----------------- | -----------: | :------: |
| GeeFam            |          -58 |    no    |
| GeeGuest2         |          -57 |    no    |
| STARLINK          |          -17 |    no    |
| (hidden Starlink) |          -17 |    no    |
| (hidden Starlink) |          -18 |    no    |
| (hidden GeeFam)   |          -58 |    no    |

Every signal is stronger than the `-65` cutoff, so weak count = **0**. That is below `fireThreshold = 3`, so no webhook fires. It is also at or below `resetThreshold = 0`, so the latch stays clear and ready.

**Power on** (`10s-power-on.txt`) - 16 SSIDs, 6 yours plus 10 neighbours:

| SSID                 | Signal (dBm) | Counted? |
| -------------------- | -----------: | :------: |
| STARLINK + 3 hidden  |   -17 to -18 |    no    |
| GeeFam, GeeGuest2 +1 |   -57 to -58 |    no    |
| Purong Family 2.4G   |          -68 |   yes    |
| Rubio 2.4G           |          -75 |   yes    |
| ROSALESFAMILY-2G     |          -76 |   yes    |
| HUAWEI Y7a           |          -76 |   yes    |
| bheby30              |          -78 |   yes    |
| Mac&GraceMonticalvo  |          -79 |   yes    |
| AMIHAN               |          -82 |   yes    |
| DrageInn2.4G         |          -82 |   yes    |
| HABAGAT              |          -83 |   yes    |
| ClarknClaire 2.4G    |          -90 |   yes    |

Weak count = **10**, well above `fireThreshold = 3`, so the webhook fires and the latch sets. It would take 10 neighbours simultaneously dropping below `resetThreshold = 0` to re-arm - effectively, another full outage.

The webhook payload for this scan would be:

```json
{ "event": "power_restored", "weak": 10, "total": 16 }
```

### 3. Add the schedulers

Two schedulers are needed: one to run the check periodically, and one to clear the latch on boot.

```terminal
/system/scheduler/add name=wifi-power-check interval=3m on-event="/system/script/run mikrotik-power-detect-wifi"

/system/scheduler/add name=wifi-power-reset start-time=startup on-event=":global powerRestoredFired \"no\""
```

Adjust `interval` to taste. Every 3 minutes balances responsiveness against scan overhead.

### 4. Test it

Force a fire by lowering the threshold temporarily, then run the script manually:

```
/system/script/run mikrotik-power-detect-wifi
/log/print where topics~"script"
```

You should see log lines for the scan, the webhook fire, and any errors. Reset the threshold afterwards.

## Webhook payload

The script POSTs the following JSON body:

```json
{ "event": "power_restored", "weak": 7, "total": 13 }
```

`weak` is the number of APs at or below `signalCutoff`. `total` is the full SSID count returned by the scan, included for diagnostics.

If your endpoint expects query-string parameters instead (the example in the script targets a Telegram-style relay), the URL is sent verbatim, so encode auth and routing there.

## Files

- `mikrotik-power-detect-wifi.rsc` - the RouterOS script. `.rsc` is the standard extension for RouterOS export/import files and is recognised by `/import`.

## Troubleshooting

- **No log output**: confirm the scheduler is enabled with `/system/scheduler/print` and the script name matches.
- **Webhook never fires**: check `/log/print where message~"Webhook"`. Common causes are an unreachable URL, TLS issues (RouterOS needs the CA imported for HTTPS unless `check-certificate=no` is used), or the latch already being set.
- **Webhook fires repeatedly**: usually means `fireThreshold` is set so low that scan jitter keeps crossing it. Check the log lines for the weak count over a few runs and raise `fireThreshold`, or widen the gap between `fireThreshold` and `resetThreshold` for more hysteresis. The latch is also per-runtime global; if you run multiple instances of the script with different names, give each its own latch variable.
- **Scan returns 0 networks**: the interface may have failed to enable in time. Increase the `:delay 5` value at the top of the script.
- **Wireless package missing on RouterOS v7**: install via `/system/package/update` or use the `wifi` (wifiwave2) package and adjust paths to `/interface/wifi/...`.
