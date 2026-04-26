# mikrotik-power-detect-wifi

A MikroTik RouterOS script that detects grid power restoration by counting visible WiFi networks, then fires a webhook so downstream automation (Home Assistant, Telegram, etc.) can react.

## How it works

When grid power is out, most of your neighbours' routers go dark and only battery-backed APs remain visible (typically 1-2 networks). When power returns, neighbour APs reboot and the visible count climbs back to 4+. The script:

1. Wakes `wlan1` if it is currently disabled (saves power between checks).
2. Runs a 5-second scan and counts the SSIDs returned.
3. Restores `wlan1` to its prior disabled/enabled state.
4. If the count crosses the threshold and the latch is clear, POSTs a JSON payload to your webhook and sets the latch.
5. Once the count drops back below the threshold, the latch resets so the next restoration event will fire again.

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

| Variable         | Default                 | Purpose                                                                    |
| ---------------- | ----------------------- | -------------------------------------------------------------------------- |
| `wifiInterface`  | `wlan1`                 | Name of the wireless interface used for scanning.                          |
| `powerThreshold` | `4`                     | Minimum SSID count that indicates power is back. Tune to your environment. |
| `webhookUrl`     | example.com placeholder | Your webhook URL, including any auth query params.                         |

Pick the threshold by running a manual scan during normal conditions and again (if you can) during an outage:

```terminal
/interface/wireless/scan wlan1 duration=5
```

Set the threshold roughly halfway between the two counts.

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
{ "event": "power_restored", "networks": 7 }
```

If your endpoint expects query-string parameters instead (the example in the script targets a Telegram-style relay), the URL is sent verbatim, so encode auth and routing there.

## Files

- `mikrotik-power-detect-wifi.rsc` - the RouterOS script. `.rsc` is the standard extension for RouterOS export/import files and is recognised by `/import`.

## Troubleshooting

- **No log output**: confirm the scheduler is enabled with `/system/scheduler/print` and the script name matches.
- **Webhook never fires**: check `/log/print where message~"Webhook"`. Common causes are an unreachable URL, TLS issues (RouterOS needs the CA imported for HTTPS unless `check-certificate=no` is used), or the latch already being set.
- **Webhook fires repeatedly**: the latch is per-runtime global; if you run multiple instances of the script with different names, give each its own latch variable.
- **Scan returns 0 networks**: the interface may have failed to enable in time. Increase the `:delay 5` value at the top of the script.
- **Wireless package missing on RouterOS v7**: install via `/system/package/update` or use the `wifi` (wifiwave2) package and adjust paths to `/interface/wifi/...`.
