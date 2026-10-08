# CALLSHARE Wi-Fi R1

This revision keeps the existing CallKit application structure but changes the live transport from BLE to local Wi-Fi UDP.

## iPhone side

- `WiFiTransport.swift`: UDP 50005 listener + J7 uplink + project-level call signaling.
- `WiFiVoiceEngine.swift`: CallKit-compatible 48 kHz / stereo / S16_LE raw PCM audio engine.
- Existing `CallKitManager`, contacts, history and UI remain in place.

## J7 side already verified

`j7_wifi_voice_core` opens `pcmC0D0c` / `pcmC0D0p` at 48 kHz stereo and sends 960-frame (20 ms) packets to UDP port 50005. The packet is 20-byte `J7WV` header + 3840-byte PCM.

## New Wi-Fi control protocol

Control datagrams start with `J7WC` and contain:

`magic(4) version(1) type(1) seqLE(4) payloadLengthLE(2) payload`

Types:
- `0x01` HELLO
- `0x10` CALL_INCOMING (UTF-8 number)
- `0x11` CALL_ANSWER
- `0x12` CALL_ACTIVE
- `0x13` CALL_END
- `0x14` VOICE_OPEN
- `0x15` VOICE_CLOSE
- `0x20` MAKE_CALL (UTF-8 number)
- `0x21` HANGUP
- `0x22` DTMF

## Important scope

The current J7 R5 binary proves the audio path, but it does not yet generate `CALL_INCOMING/CALL_ACTIVE/CALL_END` or execute `CALL_ANSWER/MAKE_CALL/HANGUP` over Wi-Fi. A small J7 telephony bridge is the next Android-side task. The existing Android source already has the required TelephonyBridge hooks: GSM ring/offhook/idle, `acceptRingingCall()`, and the 250 ms audio-open path.

True lock-screen/background incoming-call wake is a separate iOS concern. Apple documents PushKit as the mechanism that wakes an iOS VoIP app for incoming calls; local UDP alone should not be treated as a guaranteed background wake path. Therefore R1 is designed first for a foreground/active listener test, then the background strategy can be addressed without disturbing the audio core.

## First lab test

1. J7 starts its hotspot; the iPhone joins it.
2. In CALLSHARE Settings, set `J7 IP` to the J7 Wi-Fi address (current lab value: `192.168.104.12`).
3. Build/install and open CALLSHARE. The app immediately starts the UDP listener on port 50005.
4. Tap `Wi-Fi audio test` in Settings.
5. Run the already verified J7 core with the iPhone address as `--peer`, for example `192.168.104.18`.
6. Place a real GSM call to the J7 from another phone and speak.
7. CALLSHARE should log `[WIFI_AUDIO] RX PCM #... 3840B` and reproduce the audio on the speaker.

## CallKit path

The iOS CallKit manager remains the system call UI/answer layer. Wi-Fi control datagrams are translated to the existing call state machine. On Answer, CALLSHARE prepares the audio session first, sends `CALL_ANSWER`, and waits for J7 `CALL_ACTIVE` before fulfilling the CallKit answer action.

## Current boundary

The J7 R5 native core has already proven GSM D0 capture and UDP audio, but it only implements the audio bridge today. The Android companion still needs to translate Android telephony ring/offhook/idle into the `J7WC` control messages and execute Answer/Hangup/MakeCall commands. Existing Android source from this project already has `TelephonyBridge`, `acceptRingingCall()`, and GSM offhook/idle audio hooks, so that is the next J7-side conversion rather than a redesign of the iPhone app.

## Background note

For a foreground/active iPhone this local UDP design is straightforward. A guaranteed incoming CallKit UI while the app is suspended/terminated is a separate problem: Apple documents PushKit as the mechanism that wakes an iOS VoIP app for incoming calls. Local UDP by itself should not be treated as a guaranteed background wake mechanism.
