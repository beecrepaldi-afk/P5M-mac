// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
#include <logsanitizer.h>
#include <cstdio>
#include <utility>
#include <vector>

int main()
{
    // Somente dados sintéticos. Nunca abrir preferências ou sessões reais.
    const std::vector<std::pair<QString, QStringList>> cases = {
        {R"({"access_token":"synthetic_access","refreshToken":"synthetic_refresh","rp_regist_key":"synthetic_registration"})", {"synthetic_access", "synthetic_refresh", "synthetic_registration"}},
        {R"({"skey":"synthetic_key","accountId":1234567,"email":"tester@example.invalid","hostName":"Synthetic Console"})", {"synthetic_key", "1234567", "tester@example.invalid", "Synthetic Console"}},
        {R"({"authorization":"Basic synthetic_auth","psn_token":"synthetic_psn","authToken":"synthetic_api","fps":60})", {"synthetic_auth", "synthetic_psn", "synthetic_api"}},
        {"Authorization: Bearer synthetic_credentials\nrate=60", {"synthetic_credentials"}},
        {"token='synthetic spaced token' password=synthetic_password", {"synthetic spaced token", "synthetic_password"}},
        {R"({"client_secret":"synthetic\"escaped"})", {"synthetic", "escaped"}},
        {"https://example.invalid/callback?code=synthetic_code&state=synthetic_state", {"synthetic_code", "synthetic_state", "example.invalid"}},
        {"router aa:bb:cc:dd:ee:ff and 11-22-33-44-55-66", {"aa:bb:cc:dd:ee:ff", "11-22-33-44-55-66"}},
        {"peer 192.0.2.10:9295 and [2001:db8::1234]:9295 and ::1", {"192.0.2.10", "2001:db8::1234", "::1"}},
        {"file /Users/synthetic-user/Library/log and /home/synthetic-person/log", {"synthetic-user", "synthetic-person"}},
        {"console name: Synthetic Personal Console\nHost ID: synthetic_host", {"Synthetic Personal Console", "synthetic_host"}},
        {"Bearer synthetic_unlabeled", {"synthetic_unlabeled"}},
        {"session id = synthetic_session account_id=synthetic_account duid=synthetic_device", {"synthetic_session", "synthetic_account", "synthetic_device"}},
    };
    int n = 0;
    for (const auto &entry : cases)
    {
        ++n;
        QString result = SanitizeLogMessage(entry.first);
        for (const auto &secret : entry.second)
            if (result.contains(secret)) { std::fprintf(stderr, "Redaction case %d failed\n", n); return 1; }
    }
    const QString metrics = "Video 60 fps; bitrate 35000 kbps; loss 0.25%; decode 4.8 ms; audio queue 12 ms";
    if (SanitizeLogMessage(metrics) != metrics) { std::fprintf(stderr, "Metrics were altered\n"); return 1; }
    const QString json = R"({"token":"synthetic_token","bitrate":35000})";
    if (!SanitizeLogMessage(json).contains(R"("token":"<redacted>")")) { std::fprintf(stderr, "JSON quoting failed\n"); return 1; }
    const QString auth_json = R"({"authorization":"Basic synthetic_auth","fps":60})";
    if (SanitizeLogMessage(auth_json) != R"({"authorization":"<redacted>","fps":60})") { std::fprintf(stderr, "JSON authorization quoting failed\n"); return 1; }
    if (SanitizeLogMessage(SanitizeLogMessage(json)) != SanitizeLogMessage(json)) { std::fprintf(stderr, "Redaction is not idempotent\n"); return 1; }
    std::printf("Log privacy: %d synthetic cases plus metrics, JSON and idempotence passed\n", n);
    return 0;
}
