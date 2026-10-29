# Arctis Nova 5: can a macOS app mute the mic over the vendor HID interface?

Research date: 2026-10-28. Research only. Nothing was opened, written or sent to the headset or any HID/USB
device. Only `ioreg` / `system_profiler`-style read-only inspection was run on this Mac, plus web and `gh`
reads of public repos. No source code from GPL projects is reproduced here; only byte layouts and protocol facts.

Confidence labels: HIGH = several independent sources and/or verified on this Mac. MEDIUM = one good source or
a sound inference. LOW = single weak source or speculation. UNKNOWN = nobody has published an answer.

## 0. Verdict

| Question | Answer | Confidence |
|---|---|---|
| Is there a known HID command that mutes (and unmutes) the Nova 5 mic? | **No known command.** None in HeadsetControl, Linux Arctis Manager, Arctis Sound Manager, arctis-companion, NovaConnect, or the Linux kernel driver. The vendor device spec that these projects transcribe for the Nova 5 transmitter contains no mic-mute command either. | HIGH that none is *published*. MEDIUM that none *exists*. |
| Is there a related command that might get to silence? | Mic volume `0x37` (0..15, 16 steps) is a real, documented, official-app-exposed host write. Whether level 0 is true digital silence is **UNKNOWN**; nobody has measured it. | UNKNOWN |
| Can an app read the Nova 5 mute state over HID? | **Nothing documented, and the evidence leans no.** The consumer-control HID interface has no mute usage (verified on this Mac). The Nova 5 status frame has no mute field in the vendor spec. No mute-button event is documented. A live idle listen found no unsolicited reports, but nobody has captured one with the button pressed. | MEDIUM (lean no); the button-press capture is the open experiment |
| Does a sibling model do this? | Yes, read-only: Nova 7 Gen 2 and Nova Pro report the *button's* state (see 4.2). Their kernel developer exposes it as a **read-only** control and found no write path. | HIGH for the siblings |

Net: host-initiated mute: **no (no known command)**; mute-state read: **unknown, probably not available on Nova 5**.
The mic-volume-0 workaround is the only candidate left, and it needs one measurement on the real headset.

## 1. Identity and interfaces

### 1.1 Verified on this Mac (read-only ioreg, 2026-10-28)

The raw dumps (`ioreg-usb.txt`, `ioreg-hid.txt`) stayed in the session's temporary folder and are not in the repo; rerun the commands in section 7 to get them again.

- Device: `SteelSeries Arctis Nova 5`, **VID 0x1038 (4152), PID 0x2232 (8754)**, bcdDevice 0x0110, full speed,
  one configuration, composite device. (HIGH, direct observation; matches the Nova 5 base-station PID in
  HeadsetControl.)
- Interfaces (all `bInterfaceNumber` read from ioreg):

| USB iface | Class | Endpoints | HID usage page / usage | Report sizes (from the descriptor) | Role |
|---|---|---|---|---|---|
| 0 | Audio Control | **0** | - | - | UAC control (no interrupt endpoint, so no UAC control-change notifications) |
| 1, 2 | Audio Streaming | 1 each | - | - | mic and speaker streams (`usbaudiod` owns them) |
| 3 | HID | 1 (interrupt IN only) | **0xFFC0 / 0x01** | Input 64, Output 64, Feature 514, **no Report IDs** | **vendor command + status channel** |
| 4 | HID | 1 | 0x000C (Consumer) / 0x01 | Input 4 | volume up/down, prev, play/pause, next. **No Mute / telephony usage.** |
| 5 | HID | 1 | **0xFF00 / 0x01** | Input 64, Output 64, **no Report IDs** | secondary vendor channel (unsolicited events on sibling models) |

- Raw report descriptors observed (hex, from ioreg):
  - iface 3: `06c0ff 0901 a101 06c1ff 1500 26ff00 7508 09f0 9540 8102 09f1 9540 9102 09f2 960202 b102 c0`
    = usage page 0xFFC0, Input 64 B (usage 0xF0), Output 64 B (usage 0xF1), Feature 514 B (usage 0xF2).
  - iface 4: `050c 0901 a101 09e9 09ea 7501 9502 1500 2501 8102 7506 9501 8103 9503 7501 09b6 09cd 09b5 8102 7515 9501 8103 c0`
    = Volume Up/Down, Scan Previous, Play/Pause, Scan Next, padding. Nothing else.
  - iface 5: `0600ff 0901 a101 0601ff 1500 26ff00 7508 09f0 9540 8102 09f1 9540 9102 c0`
    = 64 B in, 64 B out.
- Because the descriptors declare no Report ID, an output report is simply the 64 payload bytes; use report ID 0
  with a 64-byte buffer **without** a leading 0x00 in `IOHIDDeviceSetReport` (hidapi-style "00 B0" examples in the
  literature include a dummy ID byte that the stack strips). There is no interrupt OUT endpoint, so output reports
  travel as HID SET_REPORT control transfers (same conclusion as arctis-companion and Linux Arctis Manager).
  (HIGH)
- Who holds what right now: `UsbExclusiveOwner = AppleUserUSBHostHIDDevice` on each HID interface (Apple's own
  DriverKit HID driver, not an app seize). WindowServer holds an event-service client on the consumer interface
  (iface 4) only. No user-space client holds iface 3 or 5. `usbaudiod` holds the audio interfaces. Google Chrome
  (pid 37555) holds a device-level `AppleUSBHostDeviceUserClient` (probably WebUSB/WebHID enumeration; it did not
  take the HID interfaces). **SteelSeries GG is not installed and not running on this Mac** (no app, no process,
  no launchd job). (HIGH for the snapshot)

### 1.2 PIDs of the family (from public sources)

| PID | Model | Source | Confidence |
|---|---|---|---|
| **0x2232** | Arctis Nova 5 base station (this one) | HeadsetControl, LAM, ASM, arctis-companion (hardware-tested), NovaConnect (hardware-tested), kernel patch v3 | HIGH |
| 0x2253 | Arctis Nova 5X | HeadsetControl, LAM, ASM, arctis-companion (tested), mainline kernel `hid-steelseries-arctis.c` | HIGH |
| 0x2255 | Nova 5X variant | ASM `nova_5.yaml` and arctis-companion table only; arctis-companion marks it untested | LOW |
| 0x2264 | Nova 5X (white / rev2) | LAM, ASM; untested | LOW |
| 0x2233, 0x2254, 0x2265 | **bootloader** PIDs of 0x2232 / 0x2253 / 0x2264 | LAM `nova_5.yaml` only. Never open these. | LOW-MEDIUM |
| Nova 5P (PlayStation) | **No PID found in any source.** Retail listings say it is the same hardware as the 5X with a different console license. | LOW |

All of them use the same vendor protocol family: opcode byte first, 64-byte zero-padded output reports to iface 3,
vendor usage page 0xFFC0 usage 1. (HIGH for 0x2232 and 0x2253; LOW for the rest.)

## 2. What commands exist (Nova 5 / 5X, iface 3)

Everything below is wire-level: output report = 64 bytes, byte 0 = opcode. Replies are 64-byte input reports whose
byte 0 echoes the opcode. Replies are not zero-cleared: bytes past the documented length are stale leftovers of
earlier replies, so parse fixed lengths only. (arctis-companion live capture; HIGH)

| Opcode | Dir | Payload | Notes | Confidence |
|---|---|---|---|---|
| 0xB0 | query | none | Status. `[1]` link: 2 = headset off, 3 = on (0/1 = unpaired states). `[2]` spec says "unused". `[3]` battery 0..100. `[4]` charging (1 charging, 2 plugged not charging, 3 discharging). `[5]` chatmix game 0..100, `[6]` chat 0..100. No mute field. | HIGH |
| 0x10 | query | none | firmware version strings | MEDIUM |
| 0x20 | query | none | Audio settings: 10 EQ bands x 6 bytes at `[1..60]`, `[61]` mic volume 0..15, `[62]` sidetone 0..10, `[63]` volume limiter. Read-back confirmed on a 0x2232 by ASM and arctis-companion. | HIGH |
| 0x36 | query | none | wireless mode (0 = range, 1 = speed) | MEDIUM |
| 0xA0 | query | none | UX settings: `[1]` auto-off minutes, `[2]` mute-LED brightness raw | MEDIUM |
| **0x37** | write | `n` 0..15 | **Mic volume** (16 steps). Official app slider ~15 steps. | HIGH (documented), silence at 0 UNKNOWN |
| 0x39 | write | `n` 0..10 | sidetone | HIGH |
| **0xAE** | write | raw 0 / 1 / 4 / 10 | **Mic-mute LED brightness** (off/low/med/high). It controls how bright the mute LED is, not whether the mic is muted. | HIGH |
| 0x27 | write | 0 / 1 | volume limiter | HIGH |
| 0xA3 | write | minutes | auto power-off | HIGH |
| 0x35 | write | 0 / 1 | wireless mode (extended range). | MEDIUM |
| 0x33 | write | 10 x 6 B | custom EQ | HIGH |
| 0x09 | write | none | meaning unknown. HeadsetControl sends it as part of a "save" pair. | UNKNOWN |

**Warning (from arctis-companion's analysis):** HeadsetControl follows most setting writes with `09` and then
`35 01`. `35 01` is the wireless-mode write (speed mode), not a flash commit; LAM and ASM both state the device has
no save-to-flash command. So copying HeadsetControl's save sequence would silently flip extended-range mode.
(MEDIUM-HIGH: three projects agree on opcode 0x35 meaning; the side effect is unproven.)

Mic mute LED, mic volume, sidetone, limiter, auto-off, EQ and wireless mode are the *entire* official-app feature
set for this headset ("mic volume, sidetone, mute light, volume limiter, wireless mode, automatic power off, EQ
presets"). There is no mic mute toggle in the official app. (arctis-companion `official-app-features.md`, built
from user screenshots and store listings; MEDIUM)

### 2.1 Is there a mute command? Evidence chain

1. **HeadsetControl** (the largest open-source headset reverse-engineering project): the Nova 5 file lists exactly
   sidetone, battery, chatmix, mic-mute-LED brightness, mic volume, inactive time, volume limiter, EQ preset, EQ and
   parametric EQ. The library API has `hsc_get_mic_mute_status` (read-only, used by a few other vendors), and
   `hsc_set_mic_volume`, `hsc_set_mic_mute_led_brightness`, `hsc_set_rotate_to_mute`; **there is no "set mic mute"
   function for any headset in the whole library.** (HIGH)
   - https://github.com/Sapd/HeadsetControl/blob/master/lib/devices/steelseries_arctis_nova_5.hpp
   - https://github.com/Sapd/HeadsetControl/blob/master/lib/headsetcontrol_c.h
2. **Linux Arctis Manager** `base_arctis_nova_5.yaml`: its header says the structs come from SteelSeries' own
   device spec. The structs are mic_volume, sidetone, volume_limiter, power_inactivity_timer,
   muted_mic_brightness, wireless_mode, wireless_mode_status, headset_status, parametric_eq(+bt), audio_settings(+bt),
   ux_settings. No mic mute struct, and no mute event in the unsolicited-event table. (HIGH that the transcription
   has none; MEDIUM that the transcription is complete.)
   - https://github.com/elegos/Linux-Arctis-Manager (daemon/device-configs/base_arctis_nova_5.yaml, nova_5.yaml)
3. **Arctis Sound Manager** cross-checks Nova 5 offsets against the same GG spec (`base_arctis_nova_5_tx.device`,
   tracked in a `gg-watch` file) and found the byte after the link state is declared "unused".
   - https://github.com/loteran/Arctis-Sound-Manager (devices/nova_5.yaml, tests/test_status_offsets_vs_spec.py)
4. **arctis-companion** (Linux app, hardware-tested on 0x2232, 2026-10): lists mute LED as the only mute-related
   setting; its prior-art survey states "live events (dial, mute, connect/disconnect)" are not exposed for Nova 5
   by anyone; its open-questions list asks whether the mute button produces an event at all.
   - https://github.com/marcelogm/arctis-companion/blob/main/docs/research/hid-protocol.md
   - https://github.com/marcelogm/arctis-companion/blob/main/docs/research/prior-art.md
5. **Linux kernel** (Sriman Achanta's `hid-steelseries-arctis` series; he reverse-engineered the Nova 7 Gen 2 and
   Nova Pro and added "sidetone, mic volume, mic mute LED brightness, volume limiter, Bluetooth" controls): the
   mic-mute control he added is explicitly "the hardware microphone mute button state as a **read-only** volatile
   ALSA boolean". No write path, though he built write paths for everything else. The Nova 5 / 5X entries in that
   series carry battery capability only.
   - https://lkml.iu.edu/2602.3/08371.html (patch 08/18, mic mute)
   - https://lkml.iu.edu/2602.3/08370.html (patch 04/18, per-device info including Nova 5)
   - https://lkml.iu.edu/2607.3/05110.html (v6 cover, 9 patches, Nova 5X support merged for the 7.3 cycle)
6. **SteelSeries' own description**: Arctis headsets have "an on-ear mute button"; the blog mentions the LED and,
   for Engine, only LED colour/brightness, no software mute. Product guide says Engine in GG lets you "set custom
   equalizer settings and control your mic" (search-summary only; the PDF returned 403). MEDIUM-LOW.
   - https://steelseries.com/blog/how-mute-your-arctis-mic-and-other-handy-tricks-242
   - https://igorslab.de/wp-content/uploads/2024/08/Nova-5-Product-Information-Guide.pdf
7. **Does GG offer a software mic mute for the Nova 5 on macOS?** Nothing found that says so. The Mac GG feature
   set is Engine (EQ, mic settings). Sonar (Windows only) has a mic channel mute, but that is a software virtual
   device on Windows, not the headset. I could not open GG's UI (not installed here), so the Engine mic page should be
   eyeballed once if GG is ever installed. (LOW-MEDIUM)

Taken together: the headset's mute is a hardware button acting inside the headset firmware; the dongle's UAC
mute/volume controls are stubs (consistent with what you saw, and with a Linux kernel quirk flagging the 1038:2232
UAC mixer's GET_CUR as broken, cited via NovaConnect's research notes). MEDIUM.

### 2.2 Could mic volume 0 be silence?

- `0x37` accepts 0..15. LAM and ASM label the minimum end of that slider `mic_muted`, but this is a label
  copied across several models, not a measurement.
- The default observed on hardware is 15 (max) (arctis-companion live read of `0x20[61]`).
- Unknown: whether level 0 is exactly zero gain or a very low residual (16-step ladder), whether it persists across
  headset power cycles (arctis-companion lists persistence as an open question), and whether firmware echoes a
  `0x37` "mic volume changed" event after a host write.
- Failure-mode concern for a *mute feature*: if the value persists in the headset and Orbit dies or the Mac sleeps
  while "muted", the user is left silently muted. Orbit would have to save/restore the original value and verify on
  launch. (Inference; MEDIUM)

## 3. Reading mute state over HID

| Channel | What is known | Confidence |
|---|---|---|
| Consumer-control iface 4 | Descriptor has no Mute/telephony usage (verified on this Mac). Mute button is not reported here. | HIGH |
| `0xB0` status poll on iface 3 | Nova 5 spec struct has link, an "unused" byte, battery, charging, chatmix; no mute field. **Curiosity:** byte `[2]` ("unused") was `0x02` in NovaConnect captures (headset on and off) and `0x03` in arctis-companion's capture. Unexplained; worth diffing against the physical mute state. | HIGH (spec); byte [2] UNKNOWN |
| Unsolicited events (iface 5 or 3) | Spec lists events for limiter, mic volume, sidetone, chatmix, auto-off, mute-LED brightness, battery, connection, charging. **No mute event.** arctis-companion listened 45 s on ifaces 3/4/5 with the headset idle and saw nothing; nobody has recorded a button press. | MEDIUM that no event exists; UNKNOWN until captured |
| UAC mute control | Dongle accepts and reads back mute, but audio is unaffected (your finding). Interface 0 has zero endpoints, so there are no UAC status-change notifications either. | HIGH |

Sibling-model layouts (for context only; NOT verified for Nova 5):
- Nova 7 Gen 2 `0xB0` status frame: mic-mute flag is on-wire byte 9 (1 = muted); the async event opcode `0x52`
  carries it in byte 2 (1 = muted); async events arrive on iface 5. Source: kernel patch v3 08/18,
  https://lkml.iu.edu/2602.3/08371.html. Nova Pro: status frame byte 9 as well. (HIGH for those models)
- Arctis Sound Manager uses these to drive an "alternate mic when the headset mic is muted" feature on supported
  models. The Nova 5 profile has no such mapping. https://github.com/loteran/Arctis-Sound-Manager

If HID gives no event, a fallback for *display only* (inference, LOW): watch the Core Audio input level for
sustained exact digital silence; a hardware-muted headset presumably sends zeros. Unverified.

## 4. macOS practicalities

1. **Sandbox and entitlements.** A non-sandboxed, non-App-Store, Developer-ID app needs no HID entitlement for
   IOHIDManager (the `com.apple.security.device.usb` entitlement is a sandbox thing). (MEDIUM, general knowledge)
2. **Input Monitoring (TCC).** Apple DTS (Kevin Elliott) on the Apple Developer Forums: "We require 'Input
   Monitoring' for anything that the system itself 'directly' understands (keyboard, mice, etc) but I think you
   could avoid that requirement with the right device type." In the same thread a vendor-specific HID device could
   be enumerated, opened and sent feature reports, while input-report callbacks never fired, which DTS suspected
   was missing Input Monitoring (unconfirmed; the thread had sandbox/Catalyst complications).
   https://developer.apple.com/forums/thread/804793
   - SDL commit message: "Touching HID devices with keyboard usages will trigger a keyboard capture permission
     prompt on macOS 11+." They fixed it by filtering which devices are enumerated.
     https://discourse.libsdl.org/t/sdl-hidapi-mac-only-enumerate-iohiddevices-that-are-likely-to-be-joysticks/43964
   - Counter-signal: hidapi discussion #489 reports `IOHIDDeviceOpen` returning `kIOReturnNotPermitted` (0xe00002e2)
     for an app that already had Input Monitoring (Electron universal build; unresolved).
     https://github.com/libusb/hidapi/discussions/489
   - Conclusion: **probably no prompt for usage pages 0xFFC0 and 0xFF00, but not proven for this device; and
     input reports (the part Orbit needs for events) are the piece most likely to be gated.** The dongle's iface 4
     is a Consumer-control device that the system handles itself (WindowServer holds it); do not match it. Match by
     VID/PID **and** usage page (0xFFC0 / 0xFF00) so no keyboard-class device is ever touched. Test with
     `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` before and after, and watch whether TCC prompts. Apple DTS
     also recommends the newer CoreHID framework over IOHIDManager. MEDIUM-LOW (needs a hands-on check)
3. **Exclusivity.** Opening with `kIOHIDOptionsTypeNone` is shared; do **not** pass `kIOHIDOptionsTypeSeizeDevice`.
   NovaConnect advises opening with sharing on Windows so GG can coexist. On macOS, GG is not installed here, so there
   is nothing contending right now; if GG's Engine is later running, both clients can open the vendor interfaces,
   but a query reply may be delivered to both, and Orbit must tolerate unrelated reports (marker-relative parsing:
   check byte 0 for the opcode). I found no report of GG seizing the Nova 5 interfaces. (MEDIUM-LOW)
4. **Glitching risk.** HeadsetControl issue #452: Windows users hear audio glitches on a 32 Hz tone while HID
   status polling is running (maintainer thinks it is a hardware defect). arctis-companion's checklist plans a
   soak test for it. Keep any polling rare (events instead of polling once those are verified).
   https://github.com/Sapd/HeadsetControl/issues/452 (LOW-MEDIUM)
5. **Timing rules observed by GG-derived tools:** wait about 3 s after enumeration before the first command, about
   50 ms between commands, 600 ms between EQ name and band frames. (ASM `nova_5.yaml`; MEDIUM)
6. **fwupd rebinding** (20 s iface 3 re-bind) is a Linux/fwupd artefact, irrelevant on macOS.

## 5. Licensing

- HeadsetControl (GPL-3.0), Linux Arctis Manager (GPL-3.0), arctis-companion (GPL-3.0), Linux kernel driver
  (GPL-2.0-or-later): facts only (opcodes, offsets, ranges) are recorded above; nothing here is copied code.
- Arctis Sound Manager: license "NOASSERTION" on GitHub. Treat as unlicensed: facts only.
- NovaConnect (MIT) has a clean `docs/protocol-research.md` and `docs/REVERSE_ENGINEERING.md` (a static analysis of
  GG's installer) that are safe to read for protocol facts. https://github.com/royalaid/NovaConnect
- Orbit must write its own HID code from the facts in section 2; in particular do not port HeadsetControl's
  `saveStateNova5` helper or its `00 B0` request framing.

## 6. Recommended first experiment (run only with Kevo watching)

Scope each step so that nothing irreversible is ever sent. The helper tool lives in the scratchpad or a throwaway
SwiftPM package outside the repo until Kevo agrees to move it.

**Step A: passive listen, zero bytes sent.**
- IOHIDManager, match VID 0x1038 + PID 0x2232 + usage page 0xFFC0 and, separately, 0xFF00. Do not match 0x000C.
- `IOHIDDeviceOpen` with `kIOHIDOptionsTypeNone`; register an input-report callback; print timestamp, interface and hex
  for every report. Record `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` and whether macOS prompts.
- Kevo presses the headset mute button on/off 5 times, turns the volume wheel and ChatMix dial, powers the headset
  off and on. Expected: ChatMix and power events on iface 5 per the spec, and the real question: does the mute
  button produce *anything*? This answers "can Orbit read mute state" with no write at all.

**Step B: three read-only queries (needs Kevo's explicit go).**
- One 64-byte output report on iface 3 each: `B0`, `20`, `A0`, spaced 50 ms, at least 3 s after enumeration.
  These are the same read commands arctis-companion ran against a real 0x2232 (it sent only B0, 10, 20, 36, A0).
- Capture the full 64-byte replies once with the mic unmuted and once muted (button); diff them. Specifically look at
  `B0[2]` and any tail bytes. Write nothing else.

**Step C: only if A and B show no mute signal, and only with Kevo's okay: one reversible write.**
- First read and record `0x20` (note `[61]` mic volume, `[62]` sidetone, `[63]` limiter) and `A0`.
- Send `37 00` once (no `09`, no `35 01`, no other opcodes). Check, in this order: System Settings input meter,
  a QuickTime/`afrecord` test recording, Discord's input test. Then restore with `37 <original>` and re-read `0x20`
  to confirm the original value is back. Also power-cycle the headset once to see whether the value persisted.
- Do **not** send `09`, `35 01`, `A7`, any opcode not in section 2, anything to PIDs 0x2233 / 0x2254 / 0x2265, or fuzz
  opcodes. Unknown opcodes on this firmware family can touch EQ, wireless mode or firmware-update paths.

If Step A shows a button event, Orbit can mirror the headset mute state. If Step C gives true silence at level 0,
Orbit can offer "mute = mic volume 0 with remembered restore"; otherwise there is no host-side way to silence this
headset and the honest answer is "Orbit can't mute the Nova 5 mic; use the button".

## 7. Source list

HeadsetControl (GPL-3.0)
- https://github.com/Sapd/HeadsetControl/blob/master/lib/devices/steelseries_arctis_nova_5.hpp
- https://github.com/Sapd/HeadsetControl/blob/master/lib/devices/protocols/steelseries_protocol.hpp
- https://github.com/Sapd/HeadsetControl/blob/master/lib/headsetcontrol_c.h
- https://github.com/Sapd/HeadsetControl/issues/359 (Nova 5 sidetone discovery, closed by PR 361)
- https://github.com/Sapd/HeadsetControl/issues/389 (Windows enumeration of 1038:2232)
- https://github.com/Sapd/HeadsetControl/issues/452 (audio glitching)
- https://github.com/Sapd/HeadsetControl/issues/613 (0x20 read-back; two identical replies queued per 0xB0 query)

Other projects
- https://github.com/elegos/Linux-Arctis-Manager (GPL-3.0)
- https://github.com/loteran/Arctis-Sound-Manager (no declared license)
- https://github.com/marcelogm/arctis-companion (GPL-3.0; hardware-tested on 0x2232)
- https://github.com/royalaid/NovaConnect (MIT; hardware-tested on 0x2232)
- https://github.com/Mason23Johnson/SteelSeries-Arctis-7-USB-HID-Protocol-Reverse-Engineering (cited by NovaConnect; other model)

Linux kernel
- https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/hid/hid-steelseries-arctis.c
- https://lkml.iu.edu/2602.3/08373.html (v3 cover), 08370 (04/18), 08371 (08/18 mic mute), 08384 (17/18 mute LED)
- https://lkml.iu.edu/2607.3/05110.html (v6 cover)

Apple / macOS
- https://developer.apple.com/forums/thread/804793
- https://discourse.libsdl.org/t/sdl-hidapi-mac-only-enumerate-iohiddevices-that-are-likely-to-be-joysticks/43964
- https://github.com/libusb/hidapi/discussions/489

SteelSeries
- https://steelseries.com/blog/how-mute-your-arctis-mic-and-other-handy-tricks-242
- https://igorslab.de/wp-content/uploads/2024/08/Nova-5-Product-Information-Guide.pdf (403 on fetch; search summary only)

Local, this Mac (read-only): `ioreg -r -c IOUSBHostDevice` and `ioreg -r -c IOHIDDevice -l`.

## 8. Gaps I could not close

- Whether the Nova 5 mute button emits any HID report (nobody has captured it).
- Whether `37 00` is true silence, and whether it persists across power cycles.
- Nova 5P PID.
- Whether SteelSeries GG's Engine UI exposes any mic mute for the Nova 5 (GG not installed here; not checked).
- GG's USB traffic itself has not been captured by anyone publicly for a mic mute; all protocol knowledge comes from
  third-party transcriptions of GG's device spec plus Wireshark captures from sibling models.
