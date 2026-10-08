// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "macDualSenseBluetooth.h"
#include "macHidAsyncReports.h"

#include <chiaki/time.h>

#import <Foundation/Foundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <mach/mach_time.h>
#include <pthread.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <thread>
#include <vector>

namespace {

// Report 0x32: 142 bytes, one block of 32 stereo 8-bit samples at 3 kHz
// (10.67 ms), as on the Quest. Measured on macOS (06/10/2026): a blocking
// IOHIDDeviceSetReport over Bluetooth takes ~16 ms in game (127 ms with the
// link idle) and grows with the report size, so the link moves ~10 KB/s;
// report 0x39 (two blocks, 547 bytes, DS5Dongle/KytyPS5) was worse, ~50 ms
// each, because most of it is speaker space we do not use. What helps is not
// waiting: asynchronous reports, a few in flight, went ~3x faster.
constexpr size_t REPORT_SIZE_32 = 142;
// Report 0x39 (DS5Dongle): 547 bytes, two haptics blocks under a 0xD2 header,
// room for two 200-byte Opus speaker packets that we leave empty. Opt-in with
// P5M_BT_HAPTICS_REPORT=39: a dev saw fine detail (Astro Bot's glass) come
// through 0x39 that 0x32 loses, but it is ~2x the bytes on the link.
constexpr size_t REPORT_SIZE_39 = 547;
constexpr size_t MAX_REPORT_SIZE = REPORT_SIZE_39;
constexpr int MAX_BLOCKS_PER_REPORT = 2;
constexpr size_t SAMPLES_OFFSET = 13;
constexpr size_t SAMPLES_BYTES = 64;        // one block
constexpr int MAX_IN_FLIGHT = 4;            // ~43 ms of track on the way; more fails with NoMemory

// Bytes 5-9: depth of the audio queue INSIDE the controller, in frames. The
// controller only starts playing once it is full, so this is latency; 16 is
// DS5Dongle's minimum, and what the Quest settled on.
constexpr uint8_t CONTROLLER_QUEUE = 16;

// 32 samples at 3 kHz is 10,666,667 ns. Sending 0.05% slower keeps the
// controller's own queue (which cannot be read) from creeping up between two
// crystals; the shortfall lands in our queue, which the resampling absorbs.
constexpr uint64_t BLOCK_NS = 10'672'000;

// Our queue between the network and the 10.67 ms cadence (Quest dev.208).
constexpr size_t QUEUE_BYTES = 1024;
constexpr size_t READ_BYTES = 256;
constexpr size_t FILL_BEFORE = 64;          // one report before starting a burst
constexpr size_t QUEUE_CEILING = 320;       // ~53 ms: only a big burst reaches it
constexpr double QUEUE_HIGH = 160.0;        // above this, squeeze the track
constexpr double RATIO_MIN = 0.85, RATIO_MAX = 1.15;
constexpr int FRAMES_PER_REPORT = 32;
constexpr int LOOPS_UNTIL_FLUSH = 2;        // tail of an effect goes out after 2 empty blocks
constexpr int LOOPS_UNTIL_PARK = 24;        // ~250 ms of silence (in blocks): stop feeding the controller

// Ring from the takion thread: ~170 ms, and the reader skips ahead past 384 B.
constexpr size_t RING_BYTES = 1024;
constexpr size_t RING_MAX_LAG = 384;

// Full scale of the track: the console takes 16 bits straight to the coil.
// 32768 keeps the level of the USB path; 16384 (twice the level, from the
// Quest) clipped the peaks and felt stronger and rougher over Bluetooth.
constexpr float REFERENCE = 32768.0f;

constexpr uint64_t POWER_EVERY_NS = 2'000'000'000;
constexpr uint64_t DIARY_EVERY_NS = 10'000'000'000;

uint32_t crcTable[256];

void initCrc()
{
	static bool done = false;
	if(done)
		return;
	for(uint32_t i = 0; i < 256; i++)
	{
		uint32_t c = i;
		for(int k = 0; k < 8; k++)
			c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
		crcTable[i] = c;
	}
	done = true;
}

// Bluetooth output reports carry a CRC32 over 0xA2 (the HID "output" header)
// plus the report, in the last four bytes.
void sign(uint8_t *r, size_t size)
{
	uint32_t c = 0xFFFFFFFFu;
	auto feed = [&c](uint8_t b) { c = crcTable[(c ^ b) & 0xFF] ^ (c >> 8); };
	feed(0xA2);
	for(size_t i = 0; i < size - 4; i++)
		feed(r[i]);
	c ^= 0xFFFFFFFFu;
	for(int i = 0; i < 4; i++)
		r[size - 4 + i] = uint8_t(c >> (8 * i));
}

uint64_t nowNs()
{
	static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
	return mach_absolute_time() * tb.numer / tb.denom;
}

bool isBluetooth(IOHIDDeviceRef dev)
{
	CFTypeRef t = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDTransportKey));
	if(!t || CFGetTypeID(t) != CFStringGetTypeID())
		return false;
	return CFStringFind((CFStringRef)t, CFSTR("Bluetooth"), kCFCompareCaseInsensitive).location != kCFNotFound;
}

int intProperty(IOHIDDeviceRef dev, CFStringRef key)
{
	CFTypeRef t = IOHIDDeviceGetProperty(dev, key);
	int v = 0;
	if(t && CFGetTypeID(t) == CFNumberGetTypeID())
		CFNumberGetValue((CFNumberRef)t, kCFNumberIntType, &v);
	return v;
}

// Opens (shared, like SDL: triggers and light bar stay with SDL) the first
// DualSense or Edge on Bluetooth; retained, or null.
IOHIDDeviceRef findBluetoothDualSense(IOHIDManagerRef manager, ChiakiLog *log)
{
	NSArray *matching = @[
		@{ @kIOHIDVendorIDKey: @0x054C, @kIOHIDProductIDKey: @0x0CE6 }, // DualSense
		@{ @kIOHIDVendorIDKey: @0x054C, @kIOHIDProductIDKey: @0x0DF2 }, // DualSense Edge
	];
	IOHIDManagerSetDeviceMatchingMultiple(manager, (__bridge CFArrayRef)matching);
	CFSetRef set = IOHIDManagerCopyDevices(manager);
	if(!set)
	{
		// Some systems only list after the manager is opened (shared, no seize).
		IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
		set = IOHIDManagerCopyDevices(manager);
	}
	if(!set)
		return nullptr;
	const CFIndex count = CFSetGetCount(set);
	std::vector<IOHIDDeviceRef> devices(static_cast<size_t>(count));
	CFSetGetValues(set, (const void **)devices.data());
	IOHIDDeviceRef found = nullptr;
	for(IOHIDDeviceRef dev : devices)
	{
		if(!isBluetooth(dev))
			continue;
		if(IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone) != kIOReturnSuccess)
		{
			CHIAKI_LOGW(log, "[haptics-bt] found a DualSense over Bluetooth but could not open it");
			continue;
		}
		CFRetain(dev);
		found = dev;
		break;
	}
	CFRelease(set);
	return found;
}

} // namespace

struct MacDualSenseBluetooth::Impl
{
	ChiakiLog *log = nullptr;
	IOHIDManagerRef manager = nullptr;
	IOHIDDeviceRef device = nullptr;

	// Single producer (takion), single consumer (sender) ring.
	uint8_t ring[RING_BYTES] = {};
	std::atomic<size_t> ring_w { 0 }, ring_r { 0 };
	std::atomic<unsigned> ring_full { 0 }, ring_skipped { 0 };
	std::atomic<uint64_t> last_signal_ms { 0 };

	std::thread thread;
	std::atomic<bool> running { false };
	uint8_t sequence = 0;     // high nibble of byte 1
	uint8_t audio_counter = 0; // byte 10 of 0x32, byte 9 of 0x39 (+2)
	bool report39 = false;
	bool lowpass = true;
	size_t report_size = REPORT_SIZE_32;
	int blocks_per_report = 1;

	~Impl()
	{
		if(device)
		{
			IOHIDDeviceClose(device, kIOHIDOptionsTypeNone);
			CFRelease(device);
		}
		if(manager)
		{
			IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
			CFRelease(manager);
		}
	}

	bool send(uint8_t *r, size_t size)
	{
		if(!device)
			return false;
		r[1] = uint8_t((sequence & 0x0F) << 4) | (r[1] & 0x0F);
		sequence = (sequence + 1) & 0x0F;
		if(r[0] == 0x32 || r[0] == 0x39)
			stampCounter(r);
		sign(r, size);
		return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, r[0], r, CFIndex(size)) == kIOReturnSuccess;
	}

	// Full motor power, haptics filter on, nothing muted. These fields keep
	// whatever the last owner of the link left (the console, the pairing); at
	// 7 steps of reduction the coil gets 12.5% of what we send. Only the
	// valid_flag1 bits for these three fields: the rumble-emulation bits in
	// valid_flag0 would take the coil out of audio mode.
	bool fullPower()
	{
		uint8_t r[78] = {};
		r[0] = 0x31;
		r[2] = 0x10;                       // output tag
		r[3] = 0x00;                       // valid_flag0: nothing
		r[4] = 0x02 | 0x20 | 0x40;         // audio mute, haptics filter, motor power
		r[12] = 0x00;                      // no power save, no mute
		r[39] = 0x00;                      // no motor power reduction
		// Low-pass on: smooth like the console (Quest dev.208). It also takes the
		// highs out, where fine detail like Astro Bot's glass lives;
		// P5M_BT_HAPTICS_LOWPASS=0 turns it off to compare.
		r[42] = lowpass ? 0x01 : 0x00;
		return send(r, sizeof(r));
	}

	void stampCounter(uint8_t *r)
	{
		if(r[0] == 0x39)
		{
			r[9] = audio_counter;
			audio_counter = uint8_t(audio_counter + 2);
		}
		else
			r[10] = audio_counter++;
	}

	void build(uint8_t *r, const uint8_t *samples)
	{
		memset(r, 0, report_size);
		if(report39)
		{
			r[0] = 0x39;
			r[2] = 0x91;                   // packet 0x11 (audio control), sized
			r[3] = 0x06;
			r[4] = 0x7E;                   // bit 6 required; bit 0 = mic (off)
			r[5] = r[6] = r[7] = r[8] = CONTROLLER_QUEUE;
			r[10] = 0xD2;                  // packet 0x12 (haptics), sized, bit 6
			r[11] = SAMPLES_BYTES;
			memcpy(r + 12, samples, SAMPLES_BYTES * 2);
			return;
		}
		r[0] = 0x32;
		r[2] = 0x91;                       // packet 0x11 (audio control), sized
		r[3] = 0x07;
		r[4] = 0xFE;
		r[5] = r[6] = r[7] = r[8] = r[9] = CONTROLLER_QUEUE;
		r[11] = 0x92;                      // packet 0x12 (haptics), sized
		r[12] = SAMPLES_BYTES;
		memcpy(r + SAMPLES_OFFSET, samples, SAMPLES_BYTES);
	}

	// Callbacks carregam somente o slot; nunca apontam para a sessão/Impl.
	using AsyncReports = MacHidAsyncReports<MAX_IN_FLIGHT, MAX_REPORT_SIZE>;
	std::unique_ptr<AsyncReports> reports = std::make_unique<AsyncReports>();

	static void sentCallback(void *context, IOReturn result, void *, IOHIDReportType, uint32_t, uint8_t *, CFIndex)
	{
		auto *slot = static_cast<AsyncReports::Slot *>(context);
		slot->owner->complete(*slot, nowNs(), result == kIOReturnSuccess);
	}

	// False quando todos os slots ainda aguardam seus próprios callbacks.
	bool sendAsync(const uint8_t *report)
	{
		if(!device)
			return true; // waiting for reopen(); this block is lost
		auto *slot = reports->acquire(nowNs());
		if(!slot)
			return false;
		uint8_t *r = slot->report.data();
		memcpy(r, report, report_size);
		r[1] = uint8_t((sequence & 0x0F) << 4) | (r[1] & 0x0F);
		sequence = (sequence + 1) & 0x0F;
		stampCounter(r);
		sign(r, report_size);
		if(IOHIDDeviceSetReportWithCallback(device, kIOHIDReportTypeOutput, r[0], r, CFIndex(report_size),
				1.0, sentCallback, slot) != kIOReturnSuccess)
		{
			reports->submissionFailed(*slot);
			return true; // bloco perdido: não reenviar háptica velha
		}
		return true;
	}

	// Sleeps until the deadline while serving the send callbacks.
	void waitUntil(uint64_t deadline)
	{
		for(;;)
		{
			const uint64_t now = nowNs();
			if(now >= deadline)
				return;
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, double(deadline - now) / 1e9, true);
		}
	}

	size_t readRing(uint8_t *out, size_t max)
	{
		size_t w = ring_w.load(std::memory_order_acquire);
		size_t r = ring_r.load(std::memory_order_relaxed);
		if(w - r > RING_MAX_LAG)
		{
			// Late haptics is no haptics: skip to the newest RING_MAX_LAG bytes,
			// keeping the stereo pairing.
			r = w - RING_MAX_LAG;
			ring_skipped.fetch_add(1, std::memory_order_relaxed);
		}
		size_t n = std::min(max, w - r) & ~size_t(1);
		for(size_t i = 0; i < n; i++)
			out[i] = ring[(r + i) % RING_BYTES];
		ring_r.store(r + n, std::memory_order_release);
		return n;
	}

	// P5M: the controller dropped and came back (a new IOHIDDevice): every
	// send fails on the old one. Reopen it, with nothing in flight.
	bool reopen()
	{
		if(device)
		{
			IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
			IOHIDDeviceClose(device, kIOHIDOptionsTypeNone);
			CFRelease(device);
			device = nullptr;
		}
		device = findBluetoothDualSense(manager, log);
		if(!device)
			return false;
		IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
		reports->failed_in_row = 0;
		sequence = 0;
		const bool power = fullPower();
		CHIAKI_LOGI(log, "[haptics-bt] controller reconnected; reopened it (full motor power %s)", power ? "accepted" : "refused");
		return true;
	}

	void loop();
};

std::unique_ptr<MacDualSenseBluetooth> MacDualSenseBluetooth::Open(ChiakiLog *log)
{
	initCrc();
	auto impl = std::make_unique<Impl>();
	impl->log = log;
	impl->manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	if(!impl->manager)
		return nullptr;
	IOHIDDeviceRef dev = findBluetoothDualSense(impl->manager, log);
	if(!dev)
		return nullptr;
	impl->device = dev;
	if(const char *env = getenv("P5M_BT_HAPTICS_LOWPASS"); env && strcmp(env, "0") == 0)
		impl->lowpass = false;
	if(const char *env = getenv("P5M_BT_HAPTICS_REPORT"); env && strcmp(env, "39") == 0)
	{
		impl->report39 = true;
		impl->report_size = REPORT_SIZE_39;
		impl->blocks_per_report = 2;
	}
	CHIAKI_LOGI(log, "[haptics-bt] DualSense%s over Bluetooth: raw haptics through report %s, controller low-pass %s",
		intProperty(dev, CFSTR(kIOHIDProductIDKey)) == 0x0DF2 ? " Edge" : "",
		impl->report39 ? "0x39 (two blocks per report)" : "0x32", impl->lowpass ? "on" : "off");

	Impl *d = impl.get();
	d->running = true;
	d->thread = std::thread([d] {
		pthread_setname_np("chiaki-haptics-bt");
		// A report out of time is a jolt in the hand: same class as audio.
		pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
		@autoreleasepool {
			d->loop();
		}
	});
	return std::unique_ptr<MacDualSenseBluetooth>(new MacDualSenseBluetooth(std::move(impl)));
}

MacDualSenseBluetooth::MacDualSenseBluetooth(std::unique_ptr<Impl> impl)
	: d(std::move(impl))
{
}

MacDualSenseBluetooth::~MacDualSenseBluetooth()
{
	d->running = false;
	if(d->thread.joinable())
		d->thread.join();
}

uint64_t MacDualSenseBluetooth::LastSignalMs() const
{
	return d->last_signal_ms.load(std::memory_order_relaxed);
}

void MacDualSenseBluetooth::Push(const uint8_t *pcm16, size_t frames, float gain)
{
	const size_t bytes = frames * 2;
	size_t w = d->ring_w.load(std::memory_order_relaxed);
	const size_t r = d->ring_r.load(std::memory_order_acquire);
	if(RING_BYTES - (w - r) < bytes)
	{
		if(d->ring_full.fetch_add(1, std::memory_order_relaxed) == 0)
			CHIAKI_LOGW(d->log, "[haptics-bt] ring full, dropping haptics");
		return;
	}
	for(size_t i = 0; i < bytes; i++)
	{
		int16_t sample;
		memcpy(&sample, pcm16 + i * sizeof(int16_t), sizeof(sample));
		float v = float(sample) / REFERENCE;
		v = std::clamp(v, -1.0f, 1.0f) * 127.0f * gain;
		d->ring[(w + i) % RING_BYTES] = uint8_t(int8_t(std::lround(std::clamp(v, -128.0f, 127.0f))));
	}
	d->ring_w.store(w + bytes, std::memory_order_release);
}

void MacDualSenseBluetooth::Impl::loop()
{
	uint8_t incoming[READ_BYTES];
	uint8_t queue[QUEUE_BYTES];
	size_t queued = 0;
	uint8_t report[MAX_REPORT_SIZE];
	uint8_t samples[SAMPLES_BYTES * MAX_BLOCKS_PER_REPORT];
	const int BLOCKS_PER_REPORT = blocks_per_report;
	const uint64_t PERIOD_NS = BLOCK_NS * uint64_t(blocks_per_report);
	bool flowing = false, parked = false;
	int empty_loops = 0, silent_loops = 0;
	double phase = 0.0;

	// Diary.
	unsigned sent = 0, sent_silent = 0, gaps = 0, late = 0, refused = 0, parks = 0, missed = 0, resampled = 0;
	size_t queue_peak = 0, queue_sum = 0, loops = 0, dropped = 0;
	uint64_t send_peak_ns = 0, send_sum_ns = 0;

	const bool power = fullPower();
	CHIAKI_LOGI(log, "[haptics-bt] full motor power %s", power ? "accepted" : "refused");
	IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	unsigned busy = 0;

	uint64_t next = nowNs();
	uint64_t last_power = next, last_diary = next, last_reopen = 0;
	while(running.load(std::memory_order_relaxed))
	{
		next += PERIOD_NS;

		// The link still carries MAX_IN_FLIGHT reports: leave the track in the
		// queue for the next period (it squeezes or drops the oldest).
		if(reports->inFlight() >= MAX_IN_FLIGHT)
		{
			busy++;
			goto after_send;
		}
		{
		bool send_any = false, signal_any = false;
		for(int block = 0; block < BLOCKS_PER_REPORT; block++)
		{
			uint8_t *blk = samples + block * SAMPLES_BYTES;
			// The ring is read once per report (two console packets arrive in
			// 21 ms): a second read at the same instant would find nothing and
			// count as an empty block.
			size_t got = 0;
			if(block == 0)
			{
				if(QUEUE_BYTES - queued >= READ_BYTES)
					got = readRing(incoming, READ_BYTES);
				else
					late++;
			}
			if(got > 0)
			{
				empty_loops = 0;
				memcpy(queue + queued, incoming, got);
				queued += got;
				// Drop the oldest, not the newest: what matters is now.
				if(queued > QUEUE_CEILING)
				{
					const size_t over = queued - QUEUE_CEILING;
					memmove(queue, queue + over, QUEUE_CEILING);
					queued = QUEUE_CEILING;
					dropped += over;
					late++;
				}
				if(!flowing && queued >= FILL_BEFORE)
					flowing = true;
			}
			else if(block == 0)
				empty_loops += BLOCKS_PER_REPORT;
			queue_peak = std::max(queue_peak, queued);
			queue_sum += queued;
			loops++;

			// End of a burst: the tail goes out padded with silence.
			const bool flushing = queued > 0 && queued < SAMPLES_BYTES && empty_loops >= LOOPS_UNTIL_FLUSH;
			// Waking from rest needs no prebuffer: an isolated console packet
			// (60 B) is less than a report, and waiting cost ~21 ms on the first hit.
			const bool waking = parked && !flowing && queued > 0 && queued < SAMPLES_BYTES;

			// Mid-stream resampling: stretch when short, squeeze when long, instead
			// of 10 ms holes or dropping track (+-15% pitch is not felt; a hole is).
			double ratio = 1.0;
			if(queued > QUEUE_HIGH)
				ratio = std::min(RATIO_MAX, 1.0 + (queued - QUEUE_HIGH) / (2.0 * QUEUE_HIGH));
			else if(queued < SAMPLES_BYTES)
				ratio = RATIO_MIN;
			if(ratio == 1.0)
				phase = 0.0;
			const int frames_queued = int(queued / 2);
			const int needs = int(std::ceil(phase + (FRAMES_PER_REPORT - 1) * ratio)) + 2;
			const bool resample = flowing && !flushing && ratio != 1.0 && frames_queued >= needs;

			long take;
			if(resample)
				take = -1;
			else if(flowing && queued >= SAMPLES_BYTES)
				take = SAMPLES_BYTES;
			else if(waking || flushing)
				take = long(queued);
			else
				take = 0;

			if(resample)
			{
				for(int i = 0; i < FRAMES_PER_REPORT; i++)
				{
					const double pos = phase + i * ratio;
					const int k = int(pos);
					const double t = pos - k;
					for(int c = 0; c < 2; c++)
					{
						const int a = int8_t(queue[k * 2 + c]);
						const int b = int8_t(queue[(k + 1) * 2 + c]);
						blk[i * 2 + c] = uint8_t(int8_t(std::lround(a + (b - a) * t)));
					}
				}
				const double advance = phase + FRAMES_PER_REPORT * ratio;
				const int used = std::min(int(advance), frames_queued);
				phase = advance - used;
				queued -= size_t(used) * 2;
				if(queued > 0)
					memmove(queue, queue + used * 2, queued);
				resampled++;
			}
			if(waking)
				flowing = true;
			if(take > 0)
			{
				memcpy(blk, queue, size_t(take));
				if(take < long(SAMPLES_BYTES))
					memset(blk + take, 0, SAMPLES_BYTES - size_t(take));
				queued -= size_t(take);
				if(queued > 0)
					memmove(queue, queue + take, queued);
			}
			else if(take == 0)
			{
				memset(blk, 0, SAMPLES_BYTES);
				if(flowing)
					gaps++; // the queue ran dry in the middle of a vibration
			}
			if(queued == 0 && empty_loops >= LOOPS_UNTIL_FLUSH)
				flowing = false;

			// Park after sustained silence (zero samples, no threshold: faint
			// detail is detail); the cadence and the reads go on.
			bool signal = false;
			for(size_t i = 0; i < SAMPLES_BYTES; i++)
				if(blk[i]) { signal = true; break; }
			if(signal)
			{
				silent_loops = 0;
				parked = false;
				last_signal_ms.store(chiaki_time_now_monotonic_ms(), std::memory_order_relaxed);
			}
			else if(!parked && ++silent_loops >= LOOPS_UNTIL_PARK)
			{
				parked = true;
				parks++;
			}

			send_any |= !parked;
			signal_any |= signal;
		}

		if(send_any)
		{
			build(report, samples);
			const uint64_t t0 = nowNs();
			sendAsync(report);
			const uint64_t took = nowNs() - t0;
			send_peak_ns = std::max(send_peak_ns, took);
			send_sum_ns += took;
			sent++;
			if(!signal_any)
				sent_silent++;
		}
		}
after_send:

		const uint64_t now = nowNs();
		constexpr unsigned FAILED_BEFORE_REOPEN = 20;
		if(reports->failed_in_row >= FAILED_BEFORE_REOPEN && reports->inFlight() == 0 && now - last_reopen >= POWER_EVERY_NS)
		{
			last_reopen = now;
			if(!reopen())
				CHIAKI_LOGW(log, "[haptics-bt] sends keep failing and no DualSense on Bluetooth to reopen yet");
		}
		// The power report is a blocking send (16 ms or far more): only while
		// parked, never in the middle of a vibration.
		if(parked && reports->inFlight() == 0 && now - last_power >= POWER_EVERY_NS)
		{
			// The console talks to the same controller and may lower the power
			// mid-session without anyone here knowing.
			last_power = now;
			fullPower();
		}
		if(now - last_diary >= DIARY_EVERY_NS)
		{
			last_diary = now;
			CHIAKI_LOGI(log, "[haptics-bt] 10s: sent %u (%u silent), gaps %u, late %u, refused %u, parked %u, "
				"queue avg %zu peak %zu B, dropped %zu B, ring skipped %u full %u, resampled %u, "
				"missed deadlines %u, busy %u, submit avg %.2f peak %.2f ms, delivered avg %.1f peak %.1f ms, failed %u",
				sent, sent_silent, gaps, late, refused, parks, loops ? queue_sum / loops : 0, queue_peak, dropped,
				ring_skipped.exchange(0), ring_full.exchange(0), resampled, missed,
				busy, sent ? send_sum_ns / 1e6 / sent : 0.0, send_peak_ns / 1e6,
				reports->done ? reports->sum_ns / 1e6 / reports->done : 0.0, reports->peak_ns / 1e6, reports->failed);
			busy = reports->done = reports->failed = 0;
			reports->sum_ns = reports->peak_ns = 0;
			sent = sent_silent = gaps = late = refused = parks = missed = resampled = 0;
			queue_peak = queued;
			queue_sum = loops = dropped = 0;
			send_peak_ns = send_sum_ns = 0;
		}

		if(next > nowNs())
			waitUntil(next);
		else
		{
			// Too far behind to catch up: sending a burst would only fill the
			// controller's queue with the past.
			next = nowNs();
			missed++;
		}
	}

	// Silence on the way out: the coil holds the last vibration otherwise.
	memset(samples, 0, sizeof(samples));
	build(report, samples);
	// O prazo cobre o timeout de 1 s dos relatórios e o silêncio final.
	// A espera é limitada; Close/Unschedule não prometem cancelar callbacks.
	const uint64_t stop_started = nowNs();
	const uint64_t silence_deadline = stop_started + 200'000'000;
	const uint64_t give_up = stop_started + 1'200'000'000;
	while(reports->inFlight() >= MAX_IN_FLIGHT && nowNs() < silence_deadline)
		waitUntil(nowNs() + 5'000'000);
	sendAsync(report);
	// Drene enquanto a run loop ainda consegue entregar conclusões.
	while(reports->inFlight() > 0 && nowNs() < give_up)
		waitUntil(nowNs() + 5'000'000);
	IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	if(AsyncReports::retainIfPending(reports))
		CHIAKI_LOGW(log, "[haptics-bt] shutdown: callback deadline exceeded; retaining report buffers for safety");
}
