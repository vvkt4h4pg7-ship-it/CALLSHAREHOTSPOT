# CALLSHARE Wi-Fi R1 — Build Status

## Verified in the provided container

- Swift syntax parsing passed for the modified Swift sources.
- `Info.plist` validation passed.
- The Xcode project file contains `WiFiTransport.swift` and `WiFiVoiceEngine.swift` in the target Sources build phase.
- The iOS project cannot be fully compiled here because the container does not contain Xcode or the iOS SDK.

## Hardware prerequisite already verified on the J7

The separate native J7 Wi-Fi core is already running on the phone as root and has been observed capturing live GSM call PCM from `pcmC0D0c` and transmitting `J7WV` UDP packets to the iPhone IP on port 50005.

## R1 scope

This iOS revision:

1. keeps the existing CallKit application;
2. removes BLE from the runtime AppModel path while keeping the BLE source files for rollback;
3. adds UDP audio and control transport;
4. adds a 48 kHz / stereo / S16_LE Wi-Fi voice engine;
5. maps Wi-Fi `CALL_INCOMING`, `CALL_ACTIVE`, `CALL_END`, `CALL_ANSWER`, `MAKE_CALL`, and `HANGUP` events into the existing CallKit/session flow.

## Still required on the J7 side

The already-verified native audio core does not yet generate/consume the new `J7WC` call-control messages. The next Android-side change is a small telephony bridge that reuses the existing GSM ring/offhook/idle hooks and `acceptRingingCall()` path to send `CALL_INCOMING`, `CALL_ACTIVE`, `CALL_END` and execute `CALL_ANSWER`, `MAKE_CALL`, `HANGUP`, and DTMF over Wi-Fi.
