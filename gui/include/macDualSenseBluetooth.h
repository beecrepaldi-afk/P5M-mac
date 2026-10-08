// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_MAC_DUALSENSE_BLUETOOTH_H
#define CHIAKI_MAC_DUALSENSE_BLUETOOTH_H

#include <chiaki/log.h>

#include <cstddef>
#include <cstdint>
#include <memory>

// P5M: the console's haptics on a DualSense over Bluetooth, where there is no
// USB sound card. Two ways, picked in the settings:
//  - MacDualSenseBluetooth: the raw track through HID report 0x32 (below).
//  - MacDualSenseCoreHaptics: Apple's GameController/Core Haptics; only an
//    envelope (intensity and sharpness), but Apple's own path to the device.
class MacBluetoothHaptics
{
	public:
		virtual ~MacBluetoothHaptics() = default;

		// Takion thread: stereo 16-bit samples at 3 kHz (as the console sends
		// them, possibly unaligned), gain 0..1 (the PS5 vibration intensity
		// times the user's haptics setting).
		virtual void Push(const uint8_t *pcm16, size_t frames, float gain) = 0;

		// When the controller last got a non-silent signal (monotonic ms).
		// While it plays, SDL rumble must stay off: a non-zero rumble sets
		// "disable audio haptics" on the controller and fights the envelope.
		virtual uint64_t LastSignalMs() const = 0;
};

// The raw track.
//
// Over USB the controller shows up as a sound card and the haptics play
// through it. Over Bluetooth there is no sound card: the samples go inside HID
// output report 0x32, 32 stereo 8-bit samples at 3 kHz every 10.67 ms. The
// console already sends the track at 3 kHz stereo, so only 16 -> 8 bits is
// left to do. Ported from the Quest app (DualSenseHaptics.kt and the native
// ring of patch 0021), where every constant below was tuned on hardware.
//
// The device is opened shared next to SDL (SDL's hidapi opens it
// non-exclusive), so triggers, light bar and rumble stay with SDL.
class MacDualSenseBluetooth : public MacBluetoothHaptics
{
	public:
		// The first DualSense connected over Bluetooth, or null if there is none.
		static std::unique_ptr<MacDualSenseBluetooth> Open(ChiakiLog *log);
		~MacDualSenseBluetooth() override;

		void Push(const uint8_t *pcm16, size_t frames, float gain) override;
		uint64_t LastSignalMs() const override;

		MacDualSenseBluetooth(const MacDualSenseBluetooth &) = delete;
		MacDualSenseBluetooth &operator=(const MacDualSenseBluetooth &) = delete;

		struct Impl;
	private:
		explicit MacDualSenseBluetooth(std::unique_ptr<Impl> impl);
		std::unique_ptr<Impl> d;
};

// Apple's path: GCController.haptics -> one Core Haptics engine per handle,
// one long continuous event whose intensity and sharpness follow the track
// (RMS and zero crossings of each channel, every ~10 ms).
class MacDualSenseCoreHaptics : public MacBluetoothHaptics
{
	public:
		// The first DualSense the GameController framework knows, or null.
		// GUI thread.
		static std::unique_ptr<MacDualSenseCoreHaptics> Open(ChiakiLog *log);
		~MacDualSenseCoreHaptics() override;

		void Push(const uint8_t *pcm16, size_t frames, float gain) override;
		uint64_t LastSignalMs() const override;

		MacDualSenseCoreHaptics(const MacDualSenseCoreHaptics &) = delete;
		MacDualSenseCoreHaptics &operator=(const MacDualSenseCoreHaptics &) = delete;

		struct Impl;
	private:
		explicit MacDualSenseCoreHaptics(std::unique_ptr<Impl> impl);
		std::unique_ptr<Impl> d;
};

#endif // CHIAKI_MAC_DUALSENSE_BLUETOOTH_H
