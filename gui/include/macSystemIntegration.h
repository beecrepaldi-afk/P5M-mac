#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* action: wake, connect, diagnostics, mute. Return 0 when accepted.
 * Called on the main thread; strings are valid only for the call.
 * Registration and console snapshots must be refreshed before exposing shortcuts. */
typedef int (*P5MMacActionHandler)(const char *action, const char *console_id, void *context);
typedef void (*P5MMacTextCallback)(int status, const char *text, void *context);
void p5m_mac_system_register_actions(P5MMacActionHandler handler, void *context);
/* JSON array of {"id":"opaque-local-id","name":"display name"}; never keys or addresses. */
void p5m_mac_system_set_consoles(const char *json);
/* Call after registration to refresh the system's App Shortcuts parameters. */
void p5m_mac_system_refresh_shortcuts(void);
/* status: 0 available, 1 unavailable. Completion always on the main thread. */
void p5m_mac_system_model_status(P5MMacTextCallback callback, void *context);
/* Numeric-only JSON metrics. status: 0 generated, 1 unavailable, 2 invalid,
 * 3 failed, 4 already running. Call only on explicit request after streaming.
 * Callback/context must remain alive until completion; string is borrowed.
 * No raw diary, credential, address, console name or identifier is accepted. */
void p5m_mac_system_explain_session(const char *metrics_json, P5MMacTextCallback callback, void *context);

/* Screen context: diagnostics only; fixed title, opaque ID, numeric metrics JSON.
 * No Handoff or persistent search indexing. Clear when diagnostics closes. */
void p5m_mac_system_set_context(const char *kind, const char *id, const char *title, const char *metrics_json);
void p5m_mac_system_clear_context(void);

#ifdef __cplusplus
}
#endif
