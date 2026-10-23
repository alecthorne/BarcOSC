# Barco Projector OSC Controller

A macOS app that receives OSC messages (for example from QLab or an ETC Eos console) and controls Barco projectors through the Barco Pulse JSON-RPC API. You can fade laser power, set intensity, open and close shutters, power projectors on and off, and query their status.

---

## OSC Command Reference

### Where to send

| Setting | Value |
| --- | --- |
| Host | Set under **OSC Input → Listen on interface**. The default, **This Mac only (Loopback)**, accepts OSC only from apps on this Mac at `127.0.0.1`. Choose a network interface, or **All interfaces**, to accept OSC from other machines. |
| Port | `9090` by default; set under **OSC Input → Listen on port**. |
| Transport | **TCP only** by default. TCP accepts SLIP framing (OSC 1.1, which QLab uses) and size-prefixed framing (OSC 1.0); the app detects which one each connection uses. Choose **UDP and TCP** under **OSC Input → Accept OSC over** to accept UDP as well. |

The line under the OSC Input controls shows exactly where and how to send, for example `Send OSC to this Mac at 10.10.3.11:9090 (TCP).`

The app only listens for OSC while **Open Connections** is active.

### Address format

```
/projector/{target}/{command} {arguments...}
```

- **`{target}`** is the projector's **OSC target number** from the projector list. It can be:
  - One projector: `/projector/3/...`
  - Several projectors, as a comma-separated list in braces: `/projector/{1,2,5}/...`
  - An OSC address pattern, matched against the projector list:

    | Pattern | Matches |
    | --- | --- |
    | `*` | every projector in the list |
    | `?` | any single character, so `?` matches 0–9 |
    | `1?` | 10–19 |
    | `[1-3]` | 1, 2 and 3 |
    | `[!4]` | any single digit except 4 |
    | `{1*,3}` | 1, 3, 10, 11, … |

    A pattern must match at least one projector. Patterns are supported only in the `{target}` part of the address.
- **`{command}`** is one of `fade`, `intensity`, `shutter` or `power`.
- The address and the action words (`up`, `open`, `status`, and so on) are not case-sensitive.
- You can send arguments as OSC numbers (`i`, `f`, `h`, `d`) or as strings. A string that contains spaces is split into separate arguments, so the single string `"up 3"` works the same as `up` followed by `3`. That means you can type a QLab Network cue as `/projector/1/fade up 3`.

### Summary

| Command | Arguments | Example |
| --- | --- | --- |
| Fade | `up` \| `down` \| `0`–`100`, then an optional time in seconds | `/projector/1/fade up 3` |
| Intensity | `0`–`100` \| `status` | `/projector/1/intensity 50` |
| Shutter | `open` \| `close` \| `status` | `/projector/1/shutter close` |
| Power | `on` \| `off` \| `status` | `/projector/1/power on` |

---

### `fade`: fade the laser power over time

```
/projector/{target}/fade {direction} [time]
```

| Argument | Required | Meaning |
| --- | --- | --- |
| `direction` | Yes | `up` (fade to 100), `down` (fade to 0), or a target intensity from `0` to `100` (decimals allowed) |
| `time` | No | Fade time in seconds, from `0` to `10800` (3 hours). `0` jumps straight to the target. If you leave it out, the app uses the **Default Fade Time** (4.9 seconds unless you change it). |

Examples:

```
/projector/1/fade up              # fade projector 1 to 100% over the Default Fade Time
/projector/1/fade down 2.5        # fade projector 1 to 0% over 2.5 seconds
/projector/4/fade 42.5 10         # fade projector 4 to 42.5% (sent as 43) over 10 seconds
/projector/{1,2,5}/fade down 0    # jump projectors 1, 2 and 5 to 0% immediately
/projector/*/fade down 3          # fade every projector to 0% over 3 seconds
/projector/2/fade 75              # fade projector 2 to 75% over the Default Fade Time
```

How it behaves:

- The fade starts from the projector's current laser power, which the app reads first, and moves in 1% steps spread evenly across the fade time. The projector receives whole-number values only.
- A new `fade` or `intensity` command for a projector replaces any fade already running on that projector.
- If `time` is invalid (negative, more than 3 hours, or not a number), the app uses the Default Fade Time and logs a warning.
- With **Log Received OSC Messages** on, the Log shows each fade as it starts, e.g. `Fading Projector 1 "FOH SL" (10.10.3.5) to 100% over 4.9 seconds (Default Fade Time).` The "(Default Fade Time)" note appears only when the message didn't include a time.

---

### `intensity`: set the laser power immediately, or read it

```
/projector/{target}/intensity {value | status}
```

| Argument | Meaning |
| --- | --- |
| `0`–`100` | Sets the laser power right away. The app rounds the value to a whole number and limits it to 0–100, logging a warning when it changes the value. |
| `status` | Asks for the current laser power (see [Status replies](#status-replies)). |

Examples:

```
/projector/3/intensity 50           # set projector 3 to 50%
/projector/{1,2}/intensity 72.6     # set projectors 1 and 2 to 73%
/projector/3/intensity 140          # limited to 100%
/projector/3/intensity status       # reply: /projector/3/intensity/status 72.0
```

Setting the intensity cancels any fade running on that projector.

---

### `shutter`: open, close, or read the shutter

```
/projector/{target}/shutter {open | close | status}
```

Examples:

```
/projector/3/shutter open
/projector/{1,2}/shutter close
/projector/3/shutter status         # reply: /projector/3/shutter/status "open"   (or "closed", …)
```

---

### `power`: power on, power off, or read the power state

```
/projector/{target}/power {on | off | status}
```

Examples:

```
/projector/3/power on
/projector/{1,2}/power off
/projector/3/power status           # reply: /projector/3/power/status "on"   (or "standby", "conditioning", "deconditioning", "ready", "eco", …)
```

How it behaves:

- **`off` waits 10 seconds before powering off.** The Log shows a countdown for each projector. Sending `power on` to that projector during the countdown cancels the power off.
- Sending `off` again during a countdown doesn't restart it.
- Once the countdown ends and the power off command goes out, you can no longer cancel it. A later `on` just powers the projector back on.
- Closing connections cancels every pending power off.
- `on` does no harm if the projector is already on.

---

### Status replies

A `status` request gets a reply on the same connection and transport it came in on, sent back to the sender's address and port. Over TCP, the reply uses the same framing (SLIP or size-prefixed) as the request. When the request targets several projectors, each one sends its own reply.

| Request | Reply address | Reply argument |
| --- | --- | --- |
| `/projector/N/intensity status` | `/projector/N/intensity/status` | float, e.g. `72.0` |
| `/projector/N/shutter status` | `/projector/N/shutter/status` | lowercase string, e.g. `"open"`, `"closed"` |
| `/projector/N/power status` | `/projector/N/power/status` | lowercase string, e.g. `"on"`, `"standby"` |

If the value can't be read (for example, the projector isn't connected, doesn't reply within 3 seconds, or isn't in the list), the reply contains two strings:

```
/projector/3/power/status "error" "the projector is not connected"
```

---

### Errors and troubleshooting

Turn on **Log Received OSC Messages** to see each incoming message in the Log, along with the reason for any message the app ignores. For example:

- The address doesn't match `/projector/{target}/fade|intensity|shutter|power`.
- The target isn't a whole number (`/projector/one/fade up`), isn't in the projector list, or is a pattern that matches no projector or isn't valid (`/projector/[1-3/fade up`).
- An argument is missing or invalid (`/projector/1/shutter halfway`).
- There are extra arguments. The app ignores them and logs a warning, but still runs the command.
- The sender isn't in the **Only from** list.

**Nothing happens when a sender uses UDP?** With **Accept OSC over** set to **TCP only** (the default), UDP messages are ignored. The Log always says so, even with Log Received OSC Messages off, e.g. `Ignored OSC message /projector/1/fade over UDP from 10.10.3.20 because OSC Input is set to TCP only.` To keep the Log readable, it notes each sender at most once every 10 seconds and counts the others. Set the sender to TCP, or choose **UDP and TCP**.

The app also accepts OSC bundles. It handles each message in a bundle right away and ignores the bundle's time tag.

---

## Using the App

### Projectors

Each projector has:

| Field | Notes |
| --- | --- |
| OSC target number | A whole number (0 or greater) that must be unique. This is the `{target}` in OSC addresses. |
| Name | Optional, used only for display. |
| IP address | A unique IPv4 address with no leading zeros, e.g. `192.168.1.50`. |

You can only add, edit or delete projectors while connections are closed.

### Connections

**Open Connections** connects to every projector in the list over TCP port 9090 (the Barco Pulse JSON-RPC API) and starts listening for OSC. It's the window's default button, so pressing Return opens connections (except while you're typing in a text field). If a connection drops, the app keeps trying to reconnect every 3 seconds. **Close Connections** cancels running fades and pending power offs, closes every projector connection and stops listening for OSC.

While connections are open, the app keeps running reliably in the background:

- It stops macOS from slowing it down when the window is hidden (App Nap) and stops the Mac from idle-sleeping, which would drop every connection. The display can still sleep.
- If an OSC listener fails, for example after a network change, the app retries every 5 seconds and notes "Recovered" in the Log when it's listening again.
- If the chosen network interface goes away (e.g. an adapter is unplugged), the app stops listening and starts again when it comes back or its address changes.
- OSC senders that disappear are cleaned up: TCP connections use keepalive, and a UDP sender is forgotten after 10 minutes of silence.

### OSC Input

These settings choose where the app accepts OSC from. You can only change them while connections are closed.

| Setting | Notes |
| --- | --- |
| Listen on interface | **All interfaces**, **This Mac only (Loopback)** (the default), or one network interface such as `Wi-Fi – en0 (192.168.1.214)`. The menu updates as interfaces come and go. A saved interface that isn't connected shows as `en5 (not connected)`, and connections won't open until you connect it or choose another. |
| Listen on port | 1–65535. The default is 9090. |
| Accept OSC over | **TCP only** (the default) or **UDP and TCP**. |
| Accept OSC from | **Any address**, or **Only from:** one or more IPv4 addresses separated by commas or spaces, e.g. `10.10.3.20, 10.10.3.21`. Messages from other addresses are ignored. With Loopback selected, this shows *This Mac only*. |

### Fades

**Default Fade Time** is the fade time `fade` commands use when they don't include a time. The default is 4.9 seconds, and the value can be any number of seconds from 0 to 10800 (3 hours). You can change it while connections are open.

### Logs

- **Log** shows connection events, errors and, when enabled, every received OSC message and status reply.
- **Log Sent Projector Commands** opens a separate window that shows every JSON-RPC message sent to and received from the projectors.

You can clear either log or save it as a text file. To keep a long run from slowing the app down, the Log keeps the most recent 2,000 lines and the command log the most recent 1,000; older lines are dropped, and **Save...** saves the lines still shown.

### Settings files

**Save Settings** writes the projector list, the Default Fade Time, both log checkboxes and the OSC Input settings to a JSON file. **Open Settings** loads one of these files back in, but only while connections are closed. The app checks the file with the same rules as the Add Projector form and the OSC Input fields, so if anything in it is invalid, nothing changes.

```json
{
  "defaultFadeTime" : 4.9,
  "formatVersion" : 1,
  "logProjectorCommands" : false,
  "logReceivedOSC" : false,
  "oscAllowedSenders" : [ "10.10.3.20", "10.10.3.21" ],
  "oscInterface" : "en0",
  "oscOnlyFromAllowedSenders" : true,
  "oscPort" : 9090,
  "oscTCPOnly" : true,
  "projectors" : [
    { "index" : 1, "ipAddress" : "10.10.3.5", "name" : "FOH SL - BARCO-1" }
  ]
}
```

`oscInterface` is `"all"`, `"lo0"` (this Mac only), or an interface name such as `"en0"`.

`name`, `logReceivedOSC`, `logProjectorCommands` and all the `osc…` keys are optional in files you write by hand. Any setting a file leaves out keeps its current value, so files saved by earlier versions still open.

---

## QLab Setup

1. In the app, set up **OSC Input**: choose **This Mac only (Loopback)** if QLab runs on this Mac, or the network interface QLab's machine is on.
2. In QLab, go to **Workspace Settings → Network** and create a network patch. Use the address and port from the app's *Send OSC to…* line, for example `127.0.0.1` port `9090`, and set it to **TCP**. If the patch must use UDP, choose **UDP and TCP** in the app instead.
3. Add a Network cue that uses that patch, set its type to an OSC message, and enter a command such as:
   ```
   /projector/{1,2}/fade up 3
   ```
4. In the app, click **Open Connections** (or press Return) before running the cue.

## Other OSC senders (e.g. ETC Eos)

Send to the address and port shown on the app's *Send OSC to…* line. Over TCP, either SLIP framing (OSC 1.1) or size-prefixed framing (OSC 1.0) works. If the sender can only use UDP, choose **UDP and TCP** under **Accept OSC over**.

---

## Requirements

- macOS 13 or later
- Barco projectors that support the Pulse JSON-RPC API on TCP port 9090, reachable from this Mac
