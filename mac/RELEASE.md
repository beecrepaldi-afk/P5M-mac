# P5M for macOS: release preview

This preview adds macOS system integration and improves how the interface behaves during HDR playback. Publication and notarization are separate release steps; this document does not confirm either.

## What changed

- **Dynamic outputs:** the renderer follows the current display and its available EDR headroom. Default audio output follows system route changes; temporarily unavailable outputs are retried without reconnecting the console. Explicit audio-device selection remains pinned. Volume updates are synchronized between the interface and audio producer. Physical display/device transitions still require manual validation.
- **HDR lifecycle:** extended output is used only while displaying PQ video. Returning to the menu restores SDR. The renderer checks the actual Metal layer format, color space and EDR state after window transitions rather than trusting a cached mode flag.
- **HDR and interface colors:** the renderer uses extended linear light, with `1.0` representing SDR white. P5M applies its tone curve to HDR video while keeping interface colors and brightness consistent with SDR playback.
- **Shortcuts:** four App Intents are available: **Wake Console**, **Connect to Console**, **Open Session Diagnostics**, and **Mute Microphone**. Choose a registered console where required. These actions can be used in Shortcuts and invoked through named Siri shortcuts. They do not provide a general Remote Play assistant schema or guarantee arbitrary natural-language commands.
- **Session diagnostics:** after a session, request an explanation of its measured metrics using Apple's on-device Foundation Models. Only validated numeric measurements are supplied to the model. No raw log, console identifier, account credential, address, or game frame is included. Lost frames are cumulative; bitrate and packet-loss percentage describe the final samples, not whole-session averages.
- **Siri screen context:** while the diagnostics view is open, its numeric summary is represented as an app entity. The context is cleared when the view closes. It is not indexed for search or handed off to another device. Siri behavior still depends on the system's language, availability, and capabilities.

- **Audio continuity:** normal packet bursts no longer trigger immediate queue cuts. Exceptional backlog cuts and rebuffer transitions use a brief fade with identical timing across channels; stereo imaging is preserved. Buffer reductions require sustained stability. Aggregate input-level and discard metrics help distinguish starvation from possible saturation.
- **Native audio output:** CoreAudio replaces the SDL playback queue on macOS, with a bounded pull-driven PCM ring, output-device change recovery, and SDL fallback when native output cannot be opened. Mono and stereo bypass the spatial mixer; an already binaural source is preserved.
- **Spatial audio controls:** Spatial audio is enabled by default and head tracking is opt-in. Verified multichannel PCM can use Apple's SpatialMixer for recognized headphones or built-in speakers, and direct PCM output on a capable HDMI device. Head tracking and personalized HRTF depend on system and device support.

**Current Remote Play limitation:** the Sony audio header does not negotiate the Opus multistream mapping or channel order. The decoder currently accepts mono/stereo and explicitly reports unsupported multichannel input. These controls do not establish PS5 surround or enable Tempest. A 5.1 request alone does not prove a surround stream was received.

## Requirements and fallback

The current locally packaged build requires Apple Silicon and macOS 27 because of its bundled dependency versions. App Intents and the Swift bridge themselves target macOS 13 or later. Local explanations require macOS 26 or later, a Mac eligible for Apple Intelligence, Apple Intelligence enabled, and a ready local model. The app reports why the model is unavailable and keeps the measured diagnostics usable. The same integration runs on macOS 27; newer system features do not require cloud inference or account keys.

Explanations are requested explicitly after streaming. No model inference runs during Remote Play. AI output is an interpretation of measurements, not a confirmed diagnosis; retain the measured values when assessing a suggestion.

## Validation status

Automated tests compile the Swift integration against the Apple SDK and exercise numeric sanitization, console filtering, cold-launch queries, a mock action handler, removed console identifiers, diagnostic context cleanup, and exactly one completion on the main thread. Metadata extraction includes all four actions and the diagnostic entity. These tests use no account, console connection, network request, or model inference.

Visual display behavior, actual Siri invocation, and real model output still require manual validation. Synthetic and compilation checks do not establish behavior on every Mac or display.

## Before release: manual checks

1. Compare the same menus and translucent controls with SDR and HDR playback. Check white, saturated colors, shadows, and highlight detail in both windowed and full-screen modes.
2. Repeat on an external display. Move the window between displays with different HDR capabilities, then toggle HDR and return to the original display. Check controls over bright video and over dark video.
3. Create named shortcuts for the four actions. Invoke them with P5M already open and after quitting it. Confirm that a console selected before launch resolves after the backend starts.
4. Test a console that is offline, removed, or no longer reachable. Check that the app gives a useful error and does not connect to another console. Confirm **Mute Microphone** silences microphone input rather than playback sound.
5. Open and close session diagnostics, including the case where no usable session metrics exist. With supported Siri enabled, inspect whether the visible diagnostic context is available; do not assume arbitrary commands are supported.
6. Test local explanations with Apple Intelligence available, disabled, and not ready. Confirm the unavailable state leaves numeric diagnostics readable. Compare an explanation with the measurements and check that final samples are not described as session averages.
7. On a clean installation, allow Local Network access and verify discovery, wake and streaming. Repeat with permission denied, then restore it in System Settings → Privacy & Security → Local Network. The bundle supplies a purpose string as required by [Apple local network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
8. Start a stream and confirm that explanations cannot begin during playback. Verify that streaming and reconnecting remain responsive, then request an explanation only after the session ends.

9. During a stream, check the reported audio route and input channel count. Test built-in speakers, headphones, and HDMI, then change the default output and disconnect the selected device. Confirm audio recovers and the app stays responsive. Test mute/volume, microphone echo reference, pause/resume, and repeated session shutdown.
10. Confirm stereo bypasses the spatial mixer even when Spatial audio is enabled. Head tracking must not be reported as active merely because it was requested. Actual multichannel rendering awaits a verified Remote Play decoder mapping and hardware testing.

Run the isolated integration checks from the repository root:

```sh
python3 test/test_p5m_system_integration.py
```


Automatic display pacing keeps arrival-driven presentation on fixed refresh
displays and selects CAMetalDisplayLink for variable refresh displays with
VSync enabled. The preferred rate follows the configured stream FPS within
the screen's reported range. Monitor changes and VSync changes are handled
automatically; idle display-link callbacks pause until new content arrives.
The CHIAKI_METAL_DISPLAYLINK override remains available. Sixteen local tests
passed. External VRR behavior and frame-to-screen latency still require
hardware validation. The local test bundle requires macOS 27 due to its
dependencies and uses an ad-hoc signature; public distribution remains pending.


Startup fix: create CAMetalDisplayLink only when selected. Before returning
to direct presentation, wait for invalidation to release the layer. A paused
display link still forbids nextDrawable; the regression is now covered by a
real Metal-layer test without a window. All 17 local tests passed.


With VSync disabled, frames now present as soon as GPU work completes, without
the application's vblank steering wait. Experimental steering is available
with CHIAKI_TEAR_STEER=1. The display-sync preference is revalidated during
rendering. New presentation diagnostics distinguish unique video frames from
UI redraws and report intervals between confirmed video presentations. All
18 local tests passed; actual latency and smoothness need session validation.
