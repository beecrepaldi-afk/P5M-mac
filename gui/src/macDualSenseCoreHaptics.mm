// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

// P5M: DualSense haptics through Apple's GameController framework.
//
// The raw-track path (macDualSenseBluetooth.mm) is limited by how slowly macOS
// writes HID reports over Bluetooth. This one hands the job to Apple: a Core
// Haptics engine per handle, one long continuous event, and every ~10 ms its
// intensity and sharpness are steered from the console's track. It cannot
// play the waveform itself, only its envelope, so it sits between plain rumble
// and true haptics.
//
// The advanced (looping) player is broken on macOS 27: gamecontrollerd refuses
// to decode the AVHapticEvent its pattern carries and drops the connection
// (seen in its log). The plain player built from an AHAP dictionary works, so
// one long event is used and restarted before it ends.

#include "macDualSenseBluetooth.h"

#include <chiaki/time.h>

#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <thread>

namespace
{

constexpr auto TICK = std::chrono::microseconds(10'000);
// A frame window older than this without new samples counts as silence.
constexpr auto HOLD_WITHOUT_DATA = std::chrono::milliseconds(40);
// Stop the players after this much silence, so the motors rest.
constexpr auto STOP_AFTER_SILENCE = std::chrono::milliseconds(300);
constexpr auto RETRY_EVERY = std::chrono::seconds(1);
constexpr auto DIARY_EVERY = std::chrono::seconds(10);
// Full intensity at the RMS of a sine peaking at half scale (the reference of
// the raw path, 16384), and a gate under the noise of a silent track.
constexpr float FULL_RMS = 11585.f;
constexpr float GATE_RMS = 160.f;
// Motors barely move at low input: lift the low end.
constexpr float INTENSITY_CURVE = 0.6f;
// Zero crossings to sharpness: the coil's useful band, ~50..300 Hz.
constexpr float SHARP_LOW_HZ = 50.f;
constexpr float SHARP_HIGH_HZ = 300.f;
constexpr float SAMPLE_RATE = 3000.f;
constexpr float SEND_STEP_INTENSITY = 0.02f;
constexpr float SEND_STEP_SHARPNESS = 0.05f;
constexpr float SILENT = 0.01f;
constexpr NSTimeInterval EVENT_SECONDS = 30.0;
constexpr auto RESTART_AFTER = std::chrono::seconds(28);

struct Channel
{
	double sum_sq = 0;
	uint32_t crossings = 0;
	uint32_t frames = 0;
	int16_t last = 0;
};

struct Hand
{
	CHHapticEngine *engine = nil;
	id<CHHapticPatternPlayer> player = nil;
	std::atomic<bool> broken { false };
	bool playing = false;
	std::chrono::steady_clock::time_point started {};
	float sent_intensity = -1;
	float sent_sharpness = -1;
	// Which channels feed it: 0 left, 1 right, 2 both (one engine for the pad).
	int source = 2;
};

}

struct MacDualSenseCoreHaptics::Impl
{
	ChiakiLog *log = nullptr;
	GCController *controller = nil;
	Hand hands[2];
	int hand_count = 0;

	std::mutex window_mutex;
	Channel window[2];
	float window_gain = 1.f;
	std::chrono::steady_clock::time_point window_fed {};

	std::atomic<uint64_t> last_signal_ms { 0 };
	std::atomic<bool> running { true };
	std::thread thread;

	// Diary.
	uint32_t ticks = 0, sends = 0, send_errors = 0, restarts = 0, starts = 0, start_failures = 0;
	double intensity_sum[2] = {}, sharpness_sum[2] = {};
	float intensity_peak[2] = {};
	uint32_t active_ticks[2] = {};
	double send_us_sum = 0, send_us_peak = 0;

	bool acquire();
	void release();
	bool startHand(Hand &hand);
	void stopHand(Hand &hand);
	void loop();
};

// The first DualSense the GameController framework knows, with fresh engines.
// When the controller drops off Bluetooth and comes back it is a new
// GCController, and the old engines never start again (-4810).
bool MacDualSenseCoreHaptics::Impl::acquire()
{
	release();
	GCController *found = nil;
	for(GCController *candidate in GCController.controllers)
	{
		if([candidate.extendedGamepad isKindOfClass:GCDualSenseGamepad.class] && candidate.haptics)
		{
			found = candidate;
			break;
		}
	}
	if(!found)
		return false;

	GCDeviceHaptics *haptics = found.haptics;
	NSSet<GCHapticsLocality> *localities = haptics.supportedLocalities;
	const char *layout;
	if([localities containsObject:GCHapticsLocalityLeftHandle] && [localities containsObject:GCHapticsLocalityRightHandle])
	{
		hands[0].engine = [haptics createEngineWithLocality:GCHapticsLocalityLeftHandle];
		hands[0].source = 0;
		hands[1].engine = [haptics createEngineWithLocality:GCHapticsLocalityRightHandle];
		hands[1].source = 1;
		hand_count = 2;
		layout = "left and right handles";
	}
	else
	{
		GCHapticsLocality whole = [localities containsObject:GCHapticsLocalityHandles]
			? GCHapticsLocalityHandles : GCHapticsLocalityDefault;
		hands[0].engine = [haptics createEngineWithLocality:whole];
		hands[0].source = 2;
		hand_count = 1;
		layout = "one engine for both handles";
	}
	for(int h = 0; h < hand_count; h++)
	{
		CHHapticEngine *engine = hands[h].engine;
		if(!engine)
		{
			CHIAKI_LOGW(log, "[haptics-gc] the DualSense gave no haptics engine");
			release();
			return false;
		}
		engine.playsHapticsOnly = YES;
		engine.autoShutdownEnabled = NO;
		Hand *hand = &hands[h];
		hand->broken = true;
		engine.stoppedHandler = ^(CHHapticEngineStoppedReason) { hand->broken = true; };
		engine.resetHandler = ^{ hand->broken = true; };
	}
	controller = found;
	start_failures = 0;
	CHIAKI_LOGI(log, "[haptics-gc] DualSense \"%s\" through Core Haptics (%s)",
		found.vendorName.UTF8String ?: "?", layout);
	return true;
}

void MacDualSenseCoreHaptics::Impl::release()
{
	for(int h = 0; h < hand_count; h++)
	{
		Hand &hand = hands[h];
		// The handlers point into this Impl; the stop below finishes later.
		hand.engine.stoppedHandler = ^(CHHapticEngineStoppedReason) {};
		hand.engine.resetHandler = ^{};
		stopHand(hand);
		[hand.engine stopWithCompletionHandler:nil];
		hand.engine = nil;
		hand.player = nil;
	}
	hand_count = 0;
	controller = nil;
}

bool MacDualSenseCoreHaptics::Impl::startHand(Hand &hand)
{
	NSError *error = nil;
	hand.player = nil;
	hand.playing = false;
	hand.sent_intensity = -1;
	hand.sent_sharpness = -1;
	hand.broken = false;
	if(![hand.engine startAndReturnError:&error])
	{
		if(start_failures++ == 0)
			CHIAKI_LOGW(log, "[haptics-gc] engine start failed: %s", error.localizedDescription.UTF8String);
		return false;
	}
	NSDictionary *ahap = @{
		CHHapticPatternKeyVersion: @1.0,
		CHHapticPatternKeyPattern: @[ @{ CHHapticPatternKeyEvent: @{
			CHHapticPatternKeyEventType: CHHapticEventTypeHapticContinuous,
			CHHapticPatternKeyTime: @0.0,
			CHHapticPatternKeyEventDuration: @(EVENT_SECONDS),
			CHHapticPatternKeyEventParameters: @[
				@{ CHHapticPatternKeyParameterID: CHHapticEventParameterIDHapticIntensity, CHHapticPatternKeyParameterValue: @1.0 },
				@{ CHHapticPatternKeyParameterID: CHHapticEventParameterIDHapticSharpness, CHHapticPatternKeyParameterValue: @0.5 },
			],
		} } ],
	};
	CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithDictionary:ahap error:&error];
	if(!pattern)
	{
		CHIAKI_LOGW(log, "[haptics-gc] pattern failed: %s", error.localizedDescription.UTF8String);
		return false;
	}
	id<CHHapticPatternPlayer> player = [hand.engine createPlayerWithPattern:pattern error:&error];
	if(!player)
	{
		CHIAKI_LOGW(log, "[haptics-gc] player failed: %s", error.localizedDescription.UTF8String);
		return false;
	}
	hand.player = player;
	return true;
}

void MacDualSenseCoreHaptics::Impl::stopHand(Hand &hand)
{
	if(hand.player && hand.playing)
		[hand.player stopAtTime:CHHapticTimeImmediate error:nil];
	hand.playing = false;
	hand.sent_intensity = -1;
	hand.sent_sharpness = -1;
}

void MacDualSenseCoreHaptics::Impl::loop()
{
	using clock = std::chrono::steady_clock;
	pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

	float intensity[2] = {}, sharpness[2] = { 0.5f, 0.5f };
	auto next = clock::now();
	auto last_signal = clock::time_point {};
	auto retry_at = clock::time_point {};
	auto diary_at = next + DIARY_EVERY;
	bool engines_up = false;

	while(running.load(std::memory_order_relaxed))
	{
		@autoreleasepool
		{
			const auto now = clock::now();

			bool broken = !engines_up;
			for(int h = 0; h < hand_count; h++)
				broken = broken || hands[h].broken.load();
			if(broken && now >= retry_at)
			{
				// Two failed restarts in a row: the controller probably
				// reconnected; look it up again.
				if(start_failures >= 2 || hand_count == 0)
					acquire();
				engines_up = hand_count > 0;
				for(int h = 0; h < hand_count; h++)
					engines_up = startHand(hands[h]) && engines_up;
				if(!engines_up)
					retry_at = now + RETRY_EVERY;
				else
					start_failures = 0;
				if(engines_up && restarts++ > 0)
					CHIAKI_LOGI(log, "[haptics-gc] engines restarted");
			}

			// The samples since the last tick, per channel.
			Channel taken[2];
			float gain;
			bool fresh;
			{
				std::lock_guard<std::mutex> lock(window_mutex);
				for(int c = 0; c < 2; c++)
				{
					taken[c] = window[c];
					window[c].sum_sq = 0;
					window[c].crossings = 0;
					window[c].frames = 0;
				}
				gain = window_gain;
				fresh = now - window_fed < HOLD_WITHOUT_DATA;
			}
			for(int c = 0; c < 2; c++)
			{
				if(taken[c].frames == 0)
				{
					// Packets come in bursts: hold the level between them,
					// fall to zero only when the track really stopped.
					if(!fresh)
						intensity[c] = 0;
					continue;
				}
				const float rms = std::sqrt(static_cast<float>(taken[c].sum_sq / taken[c].frames)) * gain;
				intensity[c] = rms < GATE_RMS ? 0.f
					: std::pow(std::min(1.f, rms / FULL_RMS), INTENSITY_CURVE);
				const float hz = taken[c].crossings * SAMPLE_RATE / (2.f * taken[c].frames);
				const float target = std::clamp((hz - SHARP_LOW_HZ) / (SHARP_HIGH_HZ - SHARP_LOW_HZ), 0.f, 1.f);
				sharpness[c] += (target - sharpness[c]) * 0.5f;
			}

			const bool signal = std::max(intensity[0], intensity[1]) > SILENT;
			if(signal)
			{
				last_signal = now;
				last_signal_ms.store(chiaki_time_now_monotonic_ms(), std::memory_order_relaxed);
			}

			if(engines_up)
			{
				for(int h = 0; h < hand_count; h++)
				{
					Hand &hand = hands[h];
					if(hand.broken.load() || !hand.player)
						continue;
					const float level = hand.source == 2 ? std::max(intensity[0], intensity[1]) : intensity[hand.source];
					const float sharp = hand.source == 2
						? (intensity[0] >= intensity[1] ? sharpness[0] : sharpness[1])
						: sharpness[hand.source];

					if(hand.playing && now - hand.started > RESTART_AFTER)
					{
						// The event is about to end: play it again from the start.
						stopHand(hand);
						if(level <= SILENT)
							continue;
					}
					if(!hand.playing)
					{
						if(level <= SILENT)
							continue;
						NSError *error = nil;
						if(![hand.player startAtTime:CHHapticTimeImmediate error:&error])
						{
							send_errors++;
							hand.broken = true;
							continue;
						}
						hand.playing = true;
						hand.started = now;
						starts++;
					}
					else if(!signal && now - last_signal > STOP_AFTER_SILENCE)
					{
						stopHand(hand);
						continue;
					}

					if(std::fabs(level - hand.sent_intensity) < SEND_STEP_INTENSITY
						&& std::fabs(sharp - hand.sent_sharpness) < SEND_STEP_SHARPNESS)
						continue;
					const auto t0 = clock::now();
					NSError *error = nil;
					BOOL ok = [hand.player sendParameters:@[
							[[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
								value:level relativeTime:0],
							[[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl
								value:sharp - 0.5f relativeTime:0],
						]
						atTime:CHHapticTimeImmediate error:&error];
					const double us = std::chrono::duration<double, std::micro>(clock::now() - t0).count();
					send_us_sum += us;
					send_us_peak = std::max(send_us_peak, us);
					if(!ok)
					{
						send_errors++;
						continue;
					}
					sends++;
					hand.sent_intensity = level;
					hand.sent_sharpness = sharp;
				}
			}

			ticks++;
			for(int c = 0; c < 2; c++)
			{
				if(intensity[c] > SILENT)
				{
					active_ticks[c]++;
					intensity_sum[c] += intensity[c];
					sharpness_sum[c] += sharpness[c];
				}
				intensity_peak[c] = std::max(intensity_peak[c], intensity[c]);
			}
			if(now >= diary_at)
			{
				auto avg = [](double sum, uint32_t n) { return n ? sum / n : 0.0; };
				CHIAKI_LOGI(log, "[haptics-gc] 10s: sends %u (call avg %.0f us, peak %.0f us), errors %u, starts %u, "
					"active L %u R %u of %u ticks, intensity avg L %.2f R %.2f peak L %.2f R %.2f, sharpness avg L %.2f R %.2f",
					sends, avg(send_us_sum, sends + send_errors), send_us_peak, send_errors, starts,
					active_ticks[0], active_ticks[1], ticks,
					avg(intensity_sum[0], active_ticks[0]), avg(intensity_sum[1], active_ticks[1]),
					intensity_peak[0], intensity_peak[1],
					avg(sharpness_sum[0], active_ticks[0]), avg(sharpness_sum[1], active_ticks[1]));
				ticks = sends = send_errors = starts = 0;
				send_us_sum = send_us_peak = 0;
				for(int c = 0; c < 2; c++)
				{
					intensity_sum[c] = sharpness_sum[c] = 0;
					intensity_peak[c] = 0;
					active_ticks[c] = 0;
				}
				diary_at = now + DIARY_EVERY;
			}
		}

		next += TICK;
		const auto now = clock::now();
		if(next < now)
			next = now;
		std::this_thread::sleep_until(next);
	}

	release();
}

std::unique_ptr<MacDualSenseCoreHaptics> MacDualSenseCoreHaptics::Open(ChiakiLog *log)
{
	auto impl = std::make_unique<Impl>();
	impl->log = log;
	if(!impl->acquire())
		return nullptr;
	Impl *raw = impl.get();
	impl->thread = std::thread([raw]() { raw->loop(); });
	return std::unique_ptr<MacDualSenseCoreHaptics>(new MacDualSenseCoreHaptics(std::move(impl)));
}

MacDualSenseCoreHaptics::MacDualSenseCoreHaptics(std::unique_ptr<Impl> impl)
	: d(std::move(impl))
{
}

MacDualSenseCoreHaptics::~MacDualSenseCoreHaptics()
{
	d->running = false;
	if(d->thread.joinable())
		d->thread.join();
}

uint64_t MacDualSenseCoreHaptics::LastSignalMs() const
{
	return d->last_signal_ms.load(std::memory_order_relaxed);
}

void MacDualSenseCoreHaptics::Push(const uint8_t *pcm16, size_t frames, float gain)
{
	std::lock_guard<std::mutex> lock(d->window_mutex);
	for(size_t i = 0; i < frames; i++)
	{
		int16_t s[2];
		memcpy(s, pcm16 + i * 4, 4);
		for(int c = 0; c < 2; c++)
		{
			Channel &ch = d->window[c];
			ch.sum_sq += static_cast<double>(s[c]) * s[c];
			if((s[c] >= 0) != (ch.last >= 0))
				ch.crossings++;
			ch.last = s[c];
			ch.frames++;
		}
	}
	d->window_gain = gain;
	d->window_fed = std::chrono::steady_clock::now();
}
