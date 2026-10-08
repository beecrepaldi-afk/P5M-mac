// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
#pragma once
#include <QString>
#include <QRegularExpression>

// Heap-allocated regexes that intentionally outlive static destruction,
// preventing use-after-free when background threads (e.g. takion) log
// while the process is shutting down.
static const QRegularExpression &sanitize_ipv4_re()
{
	static const auto *re = new QRegularExpression(
		R"(\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b)");
	return *re;
}
static const QRegularExpression &sanitize_ipv6_re()
{
	static const auto *re = new QRegularExpression(
		R"((?<![0-9A-Za-z])\[?(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?)\]?(?![0-9A-Za-z]))");
	return *re;
}
static const QRegularExpression &sanitize_labeled_secret_re()
{
	static const auto *re = new QRegularExpression(
		R"((((?:console|host|server|session|account|psn|public|remote)\s+(?:id|ip|address)|duid)\s*:\s*)([^\s,;]+))",
		QRegularExpression::CaseInsensitiveOption);
	return *re;
}
static const QRegularExpression &sanitize_session_id_token_re()
{
	static const auto *re = new QRegularExpression(
		R"((session\s+id\s+)([A-Za-z0-9+/=_-]{8,}))",
		QRegularExpression::CaseInsensitiveOption);
	return *re;
}
static const QRegularExpression &sanitize_uuid_re()
{
	static const auto *re = new QRegularExpression(
		R"(\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b)");
	return *re;
}
static const QRegularExpression &sanitize_long_hex_re()
{
	static const auto *re = new QRegularExpression(
		R"(\b[a-fA-F0-9]{16,}\b)");
	return *re;
}
static const QRegularExpression &sanitize_account_id_re()
{
	static const auto *re = new QRegularExpression(
		R"((account(?:_id)?\s*=\s*)([^\s,;]+))", QRegularExpression::CaseInsensitiveOption);
	return *re;
}
static const QRegularExpression &sanitize_duid_re()
{
	static const auto *re = new QRegularExpression(
		R"((duid\s*=\s*)([^\s,;]+))", QRegularExpression::CaseInsensitiveOption);
	return *re;
}
static const QRegularExpression &sanitize_session_id_eq_re()
{
	static const auto *re = new QRegularExpression(
		R"((session\s+id\s*=\s*)([^\s,;]+))", QRegularExpression::CaseInsensitiveOption);
	return *re;
}

inline QString SanitizeLogMessage(const QString &msg)
{
	QString sanitized = msg;

	// Padrões vivem até o fim do processo: threads de rede podem registrar na saída.
	static const auto *url = new QRegularExpression(R"(\b(?:https?|chiaki|p5m)://[^\s<>\"]+)", QRegularExpression::CaseInsensitiveOption);
	static const auto *authorization = new QRegularExpression(R"(((?<!["\w])(?:authorization|proxy-authorization)\s*:\s*)[^\r\n]+)", QRegularExpression::CaseInsensitiveOption);
	static const auto *bearer = new QRegularExpression(R"((\bBearer\s+)[A-Za-z0-9._~+/=-]+)", QRegularExpression::CaseInsensitiveOption);
	static const auto *json_secret = new QRegularExpression(R"re(("(?:access[_-]?token|refresh[_-]?token|id[_-]?token|(?:auth|psn)[_-]?token|token|authorization|password|secret|client[_-]?secret|rp[_-]?(?:regist[_-]?)?key|skey|account(?:[_-]?id)?|online[_-]?id|duid|session[_-]?id|localHashedId|defaultRouteMacAddr|(?:console|host|server)[_-]?name|email|user(?:[_-]?name)?)"\s*:\s*)("(?:\\.|[^"\\])*"|[^\s,}\]]+))re", QRegularExpression::CaseInsensitiveOption);
	static const auto *secret = new QRegularExpression(R"re((\b(?:access[_ -]?token|refresh[_ -]?token|id[_ -]?token|(?:auth|psn)[_ -]?token|token|password|secret|client[_ -]?secret|rp[_ -]?(?:regist[_ -]?)?key|skey)\b\s*(?:=|:)\s*)("(?:\\.|[^"\\])*"|'[^']*'|[^\s,;]+))re", QRegularExpression::CaseInsensitiveOption);
	static const auto *mac = new QRegularExpression(R"(\b[0-9a-f]{2}(?:[:-][0-9a-f]{2}){5}\b)", QRegularExpression::CaseInsensitiveOption);
	static const auto *email = new QRegularExpression(R"(\b[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b)");
	static const auto *home = new QRegularExpression(R"((?:/Users/|/home/)[^/\s]+)");
	static const auto *name = new QRegularExpression(R"re((\b(?:console|host|server|user)\s+name\s*(?:=|:)\s*)("(?:\\.|[^"\\])*"|'[^']*'|[^\r\n]+))re", QRegularExpression::CaseInsensitiveOption);
	sanitized.replace(*url, QStringLiteral("<redacted-url>"));
	sanitized.replace(*authorization, QStringLiteral("\\1<redacted>"));
	sanitized.replace(*bearer, QStringLiteral("\\1<redacted>"));
	sanitized.replace(*json_secret, QStringLiteral("\\1\"<redacted>\""));
	sanitized.replace(*secret, QStringLiteral("\\1<redacted>"));
	sanitized.replace(*mac, QStringLiteral("<redacted-mac>"));
	sanitized.replace(*email, QStringLiteral("<redacted-email>"));
	sanitized.replace(*home, QStringLiteral("/Users/<redacted-user>"));
	sanitized.replace(*name, QStringLiteral("\\1<redacted>"));

	sanitized.replace(sanitize_ipv4_re(), QStringLiteral("<redacted-ipv4>"));
	sanitized.replace(sanitize_ipv6_re(), QStringLiteral("<redacted-ipv6>"));
	sanitized.replace(sanitize_labeled_secret_re(), QStringLiteral("\\1<redacted>"));
	sanitized.replace(sanitize_account_id_re(), QStringLiteral("\\1<redacted>"));
	sanitized.replace(sanitize_duid_re(), QStringLiteral("\\1<redacted>"));
	sanitized.replace(sanitize_session_id_eq_re(), QStringLiteral("\\1<redacted>"));
	sanitized.replace(sanitize_session_id_token_re(), QStringLiteral("\\1<redacted>"));
	sanitized.replace(sanitize_uuid_re(), QStringLiteral("<redacted-uuid>"));

	// Catch unlabeled long hex identifiers, which commonly occur in console IDs and device UIDs.
	sanitized.replace(sanitize_long_hex_re(), QStringLiteral("<redacted-hex>"));

	return sanitized;
}

