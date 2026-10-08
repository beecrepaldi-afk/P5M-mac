// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_STREAMSESSION_H
#define CHIAKI_STREAMSESSION_H

#include <chiaki/session.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/opusencoder.h>
#include <chiaki/ffmpegdecoder.h>

#if CHIAKI_LIB_ENABLE_PI_DECODER
#include <chiaki/pidecoder.h>
#endif

#if CHIAKI_GUI_ENABLE_SETSU
#include <setsu.h>
#include <chiaki/orientation.h>
#endif

#if CHIAKI_GUI_ENABLE_STEAMDECK_NATIVE
#include <sdeck.h>
#include <chiaki/orientation.h>
#endif

// Using Q_OS_MACOS instead of __APPLE__ doesn't work for the necessary enums to be included
#ifdef __APPLE__
#include <macMicPermission.h>
#endif

#include "exception.h"
#include "sessionlog.h"
#include "controllermanager.h"
#include "settings.h"

#include <QObject>
#include <QImage>
#include <QMouseEvent>
#include <QMutex>
#include <QTimer>
#include <QQueue>
#include <QElapsedTimer>
#include <QThread>
#include <QPointer>
#include <QWaitCondition>
#include <QAtomicInteger>
#include <atomic>
#include <memory>
#ifdef Q_OS_MACOS
#include "macDualSenseBluetooth.h"
#include "macAudioOutput.h"
#endif
#if CHIAKI_GUI_ENABLE_SPEEX
#include <QQueue>
#include <speex/speex_echo.h>
#include <speex/speex_preprocess.h>
#endif

class QKeyEvent;
class Settings;

class ChiakiException: public Exception
{
	public:
		explicit ChiakiException(const QString &msg) : Exception(msg) {};
};

#if CHIAKI_GUI_ENABLE_STEAMDECK_NATIVE
typedef struct haptic_packet_t
{
   	int16_t haptic_packet[30];
    uint64_t timestamp;
} haptic_packet_t;

class SdeckHapticsWorker;
#endif

	struct StreamSessionConnectInfo
	{
		Settings *settings;
		QMap<Qt::Key, int> key_map;
		Decoder decoder;
		QString hw_decoder;
		AVBufferRef *hw_device_ctx;
		QString audio_out_device;
		QString audio_in_device;
		uint32_t log_level_mask;
		bool log_sanitize = true;
		QString log_file;
		ChiakiTarget target;
		QString host;
		QString nickname;
		QByteArray regist_key;
		QByteArray morning;
		QString initial_login_pin;
		ChiakiConnectVideoProfile video_profile;
		double packet_loss_max;
		unsigned int audio_buffer_size;
		int audio_volume;
		bool mac_spatial_audio = true;
		bool mac_head_tracking = false;
		bool fullscreen;
		bool zoom;
		bool stretch;
		bool enable_keyboard;
		bool keyboard_controller_enabled;
		bool mouse_touch_enabled;
		bool enable_dualsense;
		bool auto_regist;
		float haptic_override;
		int mac_bt_haptics;
		ChiakiDisableAudioVideo audio_video_disabled;
		RumbleHapticsIntensity rumble_haptics_intensity;
		bool buttons_by_pos;
		bool enable_idr_on_fec_failure;
		bool start_mic_unmuted;
		bool port_guessing_enabled;
		int port_guess_count;
		int port_guess_socket_count;
#if CHIAKI_GUI_ENABLE_STEAMDECK_NATIVE
		bool vertical_sdeck;
		bool enable_steamdeck_haptics;
#endif
#if CHIAKI_GUI_ENABLE_SPEEX
		bool speech_processing_enabled;
		int32_t noise_suppress_level;
		int32_t echo_suppress_level;
#endif
		QString duid;
		QString psn_token;
		QString psn_account_id;
		uint16_t dpad_touch_increment;
		uint dpad_touch_shortcut1;
		uint dpad_touch_shortcut2;
		uint dpad_touch_shortcut3;
		uint dpad_touch_shortcut4;

	StreamSessionConnectInfo() {}
	StreamSessionConnectInfo(
			Settings *settings,
			ChiakiTarget target,
			QString host,
			QString nickname,
			QByteArray regist_key,
			QByteArray morning,
			QString initial_login_pin,
			QString duid,
			bool auto_regist,
			bool fullscreen,
			bool zoom,
			bool stretch);
};

struct MicBuf
{
	int16_t *buf;
	uint32_t size_bytes;
	uint32_t current_byte;
};

class StreamSession : public QObject
{
	friend class StreamSessionPrivate;

	Q_OBJECT
	Q_PROPERTY(QString host READ GetHost CONSTANT)
	Q_PROPERTY(bool connected READ GetConnected NOTIFY ConnectedChanged)
	Q_PROPERTY(double measuredBitrate READ GetMeasuredBitrate NOTIFY MeasuredBitrateChanged)
	Q_PROPERTY(double averagePacketLoss READ GetAveragePacketLoss NOTIFY AveragePacketLossChanged)
	Q_PROPERTY(bool muted READ GetMuted WRITE SetMuted NOTIFY MutedChanged)
	Q_PROPERTY(bool cantDisplay READ GetCantDisplay NOTIFY CantDisplayChanged)
	Q_PROPERTY(int framesLost READ GetFramesLost NOTIFY FramesLostChanged)
	Q_PROPERTY(QString audioOutputStatus READ GetAudioOutputStatus NOTIFY AudioOutputChanged)

	private:
		SessionLog log;
		ChiakiSession session;
		ChiakiOpusDecoder opus_decoder;
		ChiakiOpusEncoder opus_encoder;
		bool connected;
		bool muted;
		bool mic_connected;
		bool port_guessing_enabled;
		int port_guess_count;
		int port_guess_socket_count;
#ifdef Q_OS_MACOS
		bool mic_authorization;
#endif
		bool allow_unmute;
		int input_block;
		QString host;
		std::atomic<int> audio_volume { SDL_MIX_MAXVOLUME };
		double measured_bitrate = 0;
		double average_packet_loss = 0;
		int32_t frames_lost = 0;
		int32_t pending_frames_lost = 0;
		double packet_loss_max = 0;
		QList<double> packet_loss_history;
		QAtomicInteger<quint64> decoder_flush_generation{0};
		bool cant_display = false;
		int haptics_handheld;
		float rumble_multiplier;
		int ps5_rumble_intensity;
		int ps5_trigger_intensity;
		uint8_t led_color[3];
		uint8_t led_brightness; // P5M: do console, 0 = 100%, 1 = 50%, 2 = 25%
		void ScaledLedColor(uint8_t out[3]) const;
		uint8_t player_index;
		QHash<int, Controller *> controllers;
#if CHIAKI_GUI_ENABLE_SETSU
		Setsu *setsu;
		QMap<QPair<QString, SetsuTrackingId>, uint8_t> setsu_ids;
		ChiakiControllerState setsu_state;
		SetsuDevice *setsu_motion_device;
		ChiakiOrientationTracker orient_tracker;
		ChiakiAccelNewZero setsu_accel_zero, setsu_real_accel;
		bool orient_dirty;
#endif

#if CHIAKI_GUI_ENABLE_STEAMDECK_NATIVE
		SDeck *sdeck;
		QMutex sdeck_mutex;
		QThread *sdeck_haptics_thread = nullptr;
		SdeckHapticsWorker *sdeck_haptics_worker = nullptr;
		ChiakiControllerState sdeck_state;
		bool enable_steamdeck_haptics;
		ChiakiOrientationTracker sdeck_orient_tracker;
		ChiakiAccelNewZero sdeck_accel_zero, sdeck_real_accel;
		bool sdeck_orient_dirty;
		bool vertical_sdeck;
#endif
		QQueue<uint16_t> rumble_haptics;
		bool rumble_haptics_connected;
		bool rumble_haptics_on;
		float PS_TOUCHPAD_MAX_X, PS_TOUCHPAD_MAX_Y;
		ChiakiControllerState keyboard_state;
		ChiakiControllerState touch_state;
		QMap<int, uint8_t> touch_tracker;
		int8_t mouse_touch_id;
		ChiakiControllerState dpad_touch_state;
		uint16_t dpad_touch_increment;
		float trigger_override;
		float haptic_override;
		bool keyboard_controller_enabled;
		bool mouse_touch_enabled;
		bool dpad_regular;
		bool dpad_regular_touch_switched;
		uint dpad_touch_shortcut1;
		uint dpad_touch_shortcut2;
		uint dpad_touch_shortcut3;
		uint dpad_touch_shortcut4;
		int8_t dpad_touch_id;
		QPair<uint16_t, uint16_t> dpad_touch_value;
		QTimer *dpad_touch_timer, *dpad_touch_stop_timer;
		QElapsedTimer double_tap_timer;
		RumbleHapticsIntensity rumble_haptics_intensity;
		bool start_mic_unmuted;
		bool session_started;

		ChiakiFfmpegDecoder *ffmpeg_decoder;
		void TriggerFfmpegFrameAvailable();
#if CHIAKI_LIB_ENABLE_PI_DECODER
		ChiakiPiDecoder *pi_decoder;
#endif

		QString audio_out_device_name;
		QString audio_in_device_name;
		SDL_AudioDeviceID audio_out;
		SDL_AudioDeviceID audio_in;
		size_t audio_out_sample_size = 0;
		unsigned int audio_out_rate = 48000;
		unsigned int audio_out_channels = 2;
		QString audio_output_status = QStringLiteral("Waiting for the stream's audio format");
		void SetAudioOutputStatus(const QString &status);
#ifdef Q_OS_MACOS
		std::unique_ptr<MacAudioOutput> mac_audio_output;
		bool mac_spatial_audio = true;
		bool mac_head_tracking = false;
		uint64_t mac_audio_reopen_us = 0;
		uint64_t mac_audio_last_underruns = 0;
#endif
		QMutex audio_out_ring_mutex;
		QByteArray audio_out_ring_buf;
		size_t audio_out_ring_read_pos = 0;
		size_t audio_out_ring_write_pos = 0;
		size_t audio_out_ring_fill = 0;
		bool audio_out_overflow_logged = false;
		QMutex audio_out_drain_mutex;
		QWaitCondition audio_out_drain_wait;
		QThread *audio_out_drain_thread = nullptr;
		bool audio_out_drain_thread_running = false;
		bool audio_out_drain_requested = false;
		size_t haptics_buffer_size;
		unsigned int audio_buffer_size;
		ChiakiHolepunchSession holepunch_session;
	public:
		// Over the internet (PSN hole punching) rather than the home network.
		bool IsRemote() const { return holepunch_session != nullptr; }
	private:
#if CHIAKI_GUI_ENABLE_SPEEX
		SpeexEchoState *echo_state;
		SpeexPreprocessState *preprocess_state;
		bool speech_processing_enabled;
		SDL_AudioCVT mic_speex_cvt;
		SDL_AudioCVT echo_speex_cvt;
		uint8_t *echo_resampler_buf, *mic_resampler_buf;
		QMutex echo_to_cancel_mutex;
		QQueue<QByteArray> echo_to_cancel;
#endif
		SDL_AudioDeviceID haptics_output;
		bool haptics_connecting = false;
		QPointer<QThread> haptics_opener_thread;
		QMutex haptics_opener_mutex;
		SDL_AudioDeviceID haptics_opener_result = 0;
		std::atomic<bool> shutting_down { false };
#ifdef Q_OS_MACOS
		// P5M: raw haptics to a DualSense over Bluetooth (no USB sound card).
		// Set once on the GUI thread, read by the takion thread, destroyed
		// only after the session threads are joined.
		std::unique_ptr<MacBluetoothHaptics> bt_haptics;
		std::atomic<MacBluetoothHaptics *> bt_haptics_live { nullptr };
		int mac_bt_haptics = 0;
		void StartBluetoothHaptics();
#endif
		SDL_AudioCVT haptics_cvt;
		uint8_t *haptics_resampler_buf;
		MicBuf mic_buf;
		QMutex mic_ring_mutex;
		QByteArray mic_ring_buf;
		size_t mic_ring_read_pos = 0;
		size_t mic_ring_write_pos = 0;
		size_t mic_ring_fill = 0;
		bool mic_ring_drain_queued = false;
		bool mic_ring_overflow_logged = false;
		QAtomicInteger<bool> mic_active = true;
		QMap<Qt::Key, int> key_map;
		QElapsedTimer connect_timer;
		// P5M learning per network (see LearnFromSession): the sound queue
		// adapts live, the bitrate between sessions.
		std::atomic<double> audio_target_ms { 20 };
		uint64_t audio_window_start_us = 0;
		uint64_t audio_queued_sum_us = 0;
		uint64_t audio_queued_max_us = 0;
		uint64_t audio_queued_min_us = ~uint64_t(0);
		uint64_t audio_last_raise_us = 0;
		uint64_t audio_first_frame_us = 0;
		uint64_t audio_last_frame_us = 0;
		unsigned audio_window_frames = 0;
		unsigned audio_window_dry = 0;
		unsigned audio_clean_windows = 0;
		unsigned audio_pcm_peak = 0;
		uint64_t audio_full_scale_samples = 0, audio_measured_samples = 0;
		QString learn_key;
		unsigned learn_cap_kbps = 0, learn_used_kbps = 0;
		QElapsedTimer learn_timer;
		bool learn_saved = false;
		void LearnFromSession();

		void StartAudioOutDrainThread();
		void StopAudioOutDrainThread();
		void AudioOutDrainThreadMain();
		void QueueAudioOutData(const QByteArray &audio_data);
		void DrainAudioOutRingBuffer();
		void PushAudioFrame(int16_t *buf, size_t samples_count);
		void PushHapticsFrame(uint8_t *buf, size_t buf_size);
		void CantDisplayMessage(bool cant_display);
		ChiakiErrorCode InitiatePsnConnection(QString psn_token);
#ifdef Q_OS_MACOS
		void SetMicAuthorization(Authorization authorization);
#endif
#if CHIAKI_GUI_ENABLE_SETSU
		void HandleSetsuEvent(SetsuEvent *event);
#endif
#if CHIAKI_GUI_ENABLE_STEAMDECK_NATIVE
		void HandleSDeckEvent(SDeckEvent *event);
#endif
		void AdjustAdaptiveTriggerPacket(uint8_t *buf, uint8_t type);
		void WaitHaptics();

	private slots:
		void InitAudio(unsigned int channels, unsigned int rate);
		void OpenSessionMic();
		void InitMic(unsigned int channels, unsigned int rate);
		void InitHaptics();
		void Event(ChiakiEvent *event);
		void DisconnectHaptics();
		void ConnectHaptics();
#if CHIAKI_GUI_ENABLE_STEAMDECK_NATIVE
		void ConnectSdeckHaptics();
		void StopSdeckHaptics();
#endif
		void QueueRumbleHaptics(uint16_t strength);
		void ConnectRumbleHaptics();

	public:
		explicit StreamSession(const StreamSessionConnectInfo &connect_info, QObject *parent = nullptr);
		~StreamSession();

		bool IsConnected()	{ return connected; }
		bool IsConnecting()	{ return connect_timer.isValid(); }

		void Start();
		void Stop();
		void GoToBed();
	Q_INVOKABLE bool RequestIDR();
		void ToggleMute();
		void SetLoginPIN(const QString &pin);
		void GoHome();
		QString GetHost() { return host; }
		bool GetConnected() { return connected; }
		double GetMeasuredBitrate()	{ return measured_bitrate; }
		double GetAveragePacketLoss()	{ return average_packet_loss; }
		quint64 DecoderFlushGeneration() const { return decoder_flush_generation.loadRelaxed(); }
		int GetFramesLost()		{ return frames_lost; }
		bool GetMuted()	{ return muted; }
		void SetMuted(bool enable)	{ if (enable != muted) ToggleMute(); }
		QString GetAudioOutputStatus() const { return audio_output_status; }
		void SetAudioVolume(int volume) { audio_volume.store(qBound(0, volume, SDL_MIX_MAXVOLUME), std::memory_order_relaxed); }
		bool GetCantDisplay()	{ return cant_display; }
		ChiakiErrorCode ConnectPsnConnection(QString duid, bool ps5);
		void CancelPsnConnection(bool stop_thread);

		ChiakiLog *GetChiakiLog()				{ return log.GetChiakiLog(); }
		QList<Controller *> GetControllers()	{ return controllers.values(); }
		ChiakiFfmpegDecoder *GetFfmpegDecoder()	{ return ffmpeg_decoder; }
#if CHIAKI_LIB_ENABLE_PI_DECODER
		ChiakiPiDecoder *GetPiDecoder()	{ return pi_decoder; }
#endif
		void HandleKeyboardEvent(QKeyEvent *event);
		void HandleTouchEvent(QTouchEvent *event, qreal width, qreal height);
		void HandleDpadTouchEvent(ChiakiControllerState *state, bool placeholder = false);
		void HandleMouseReleaseEvent(QMouseEvent *event);
		void HandleMousePressEvent(QMouseEvent *event);
		void HandleMouseMoveEvent(QMouseEvent *event, qreal width, qreal height);
#if CHIAKI_GUI_ENABLE_SPEEX
		bool ProcessMicFrame(int16_t *echo_buf);
#endif
		void QueueMicData(const uint8_t *micdata, size_t micdata_size);
		void DrainMicRingBuffer();
		void ReadMic(const QByteArray &micdata);

		void BlockInput(bool block) { input_block = block ? 1 : 2; SendFeedbackState(); }

	signals:
		void FfmpegFrameAvailable();
		void RumbleHapticPushed(uint16_t strength);
#if CHIAKI_GUI_ENABLE_STEAMDECK_NATIVE
		void SdeckHapticPushed(haptic_packet_t packetl, haptic_packet_t packetr);
#endif
		void DualSenseIntensityChanged(uint8_t intensity);
		void SessionQuit(ChiakiQuitReason reason, const QString &reason_str);
		void LoginPINRequested(bool incorrect);
		void DataHolepunchProgress(bool finished);
		void AutoRegistSucceeded(const ChiakiRegisteredHost &host);
		void NicknameReceived(QString nickname);
		void ConnectedChanged();
		void MeasuredBitrateChanged();
		void AveragePacketLossChanged();
		void FramesLostChanged();
		void AudioOutputChanged();
		void MutedChanged();
		void CantDisplayChanged(bool cant_display);
		void FecFailure();

	private slots:
		void UpdateGamepads();
		void DpadSendFeedbackState();
		void SendFeedbackState();
		// TEMP diagnostic: buttons that went to the console, by source.
};

Q_DECLARE_METATYPE(ChiakiQuitReason)
#if CHIAKI_GUI_ENABLE_STEAMDECK_NATIVE
Q_DECLARE_METATYPE(haptic_packet_t)
#endif

#endif // CHIAKI_STREAMSESSION_H
