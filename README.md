# P5M for macOS

P5M is an Apple Silicon Remote Play app based on chiaki-ng. It adds a Metal renderer, controller navigation, HDR interface fixes and macOS Shortcuts integrations.

## What's new in P5M

P5M grew out of chiaki-ng, the open-source project that brings the PS5 to other screens. Starting from that base, we rebuilt everything you see, hear and feel for the Mac — and went further than open-source players had gone.

**Speaks the PS5's newest language.** The console and Sony's official app stream over version 20 of the PlayStation streaming protocol. Open-source players stopped at version 12. By studying how the official app behaves, we mapped version 20 end to end: a stronger key exchange, new protection that keeps sound clean when the network drops packets, and the new adaptive trigger format. As far as we know, P5M is the first open-source app to play on it.

**Picture built for the Mac.** Video goes from the Apple chip's decoder straight to the screen, with no copies along the way, and in HDR on displays that can show it.

**Even better on 120 Hz displays.** The PS5 streams 60 frames per second, but your screen decides when each one appears. A 120 Hz display — like the ProMotion screen on MacBook Pro or a high-refresh monitor — refreshes twice as often, so frames reach your eyes sooner. Frames that arrive a little late wait less, so motion stays smoother. On variable-refresh displays, P5M follows the screen's own rhythm and shows each frame as it arrives. And because the synced picture is already fast, you get a clean image with no tearing and low delay at the same time.

**At home in macOS.** Sound follows you when you switch headphones or speakers. Shortcuts and Siri can wake your console and connect without opening the app.

**Measured, not guessed.** Every session keeps a diary with each frame's time to the screen, network packets and bandwidth. Every improvement is measured before it ships.

**Something wrong?** Use *Report a problem* in the app. It saves your last session diary — with addresses, accounts and keys removed — to your Desktop and opens a short form here on GitHub.

P5M for macOS is created by [beecrepaldi-afk](https://github.com/beecrepaldi-afk). See [AUTHORS.md](AUTHORS.md).

See [release preview and hardware checks](mac/RELEASE.md), [build notes](mac/LEIAME.md), and [packaging/signing requirements](mac/DISTRIBUTION.md). The current local package requires macOS 27; its ad-hoc signature is for local testing. Developer ID, notarization, exact source publication and hardware validation remain release prerequisites.

The upstream project and attribution follow below.

---

![chiaki-ng Logo](gui/res/chiaking-logo.svg)

# [chiaki-ng](https://streetpea.github.io/chiaki-ng/)

An open source PlayStation remote play project serving as the next-generation of Chiaki with improvements and ongoing support now that the original Chiaki project is in maintenance mode only. [Click here to see the accompanying site for documentation, updates and more](https://streetpea.github.io/chiaki-ng/).

## Discord
[chiaki-ng community Discord](https://discord.gg/tAMbRuwXDH)

## Disclaimer
This project is not endorsed or certified by Sony Interactive Entertainment LLC.

Chiaki is a Free and Open Source Software Client for PlayStation 4 and PlayStation 5 Remote Play
for Linux, FreeBSD, OpenBSD, Android, macOS, Windows, Nintendo Switch and potentially even more platforms.
