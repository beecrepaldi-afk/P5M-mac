// Converte o chiaki-settings.json do app Android (P5M/chiaki) para o .ini
// que o "Import Settings" do chiaki-ng desktop lê (mesmo formato do Export).
#include <QCoreApplication>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSettings>
#include <QTemporaryFile>
#include <cstdio>

static int targetFromName(const QString &n)
{
	if (n == "PS5_1") return 1000100;
	if (n == "PS5_UNKNOWN") return 1000000;
	if (n == "PS4_10") return 1000;
	if (n == "PS4_9") return 900;
	if (n == "PS4_8") return 800;
	return -1;
}

int main(int argc, char **argv)
{
	QCoreApplication app(argc, argv);
	if (argc != 3) { fprintf(stderr, "Usage: quest2ini input.json output.ini\n"); return 2; }
	const QString output = QString::fromLocal8Bit(argv[2]);
	const QFileInfo destination(output);
	if (destination.exists() || destination.isSymLink()) {
		fprintf(stderr, "Output already exists; choose a new file.\n");
		return 1;
	}
	QFile in(QString::fromLocal8Bit(argv[1]));
	if (!in.open(QIODevice::ReadOnly)) { fprintf(stderr, "Could not open input.\n"); return 1; }
	QJsonParseError parseError;
	const QJsonDocument document = QJsonDocument::fromJson(in.readAll(), &parseError);
	if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
		fprintf(stderr, "Input is not a valid JSON object.\n");
		return 1;
	}
	const QJsonValue hostsValue = document.object()["settings"].toObject()["registered_hosts"];
	if (!hostsValue.isArray() || hostsValue.toArray().isEmpty()) {
		fprintf(stderr, "Input has no registered consoles.\n");
		return 1;
	}
	const QJsonArray hosts = hostsValue.toArray();
	static const QRegularExpression macPattern(QStringLiteral("^(?:[0-9a-fA-F]{12}|(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})$"));
	int index = 0;
	for (const auto &v : hosts) {
		const QJsonObject h = v.toObject();
		const auto flags = QByteArray::AbortOnBase64DecodingErrors;
		const QByteArray regist = QByteArray::fromBase64(h["rp_regist_key"].toString().toLatin1(), flags);
		const QByteArray key = QByteArray::fromBase64(h["rp_key"].toString().toLatin1(), flags);
		if (targetFromName(h["target"].toString()) < 0 ||
			!macPattern.match(h["server_mac"].toString()).hasMatch() || regist.size() != 16 || key.size() != 16) {
			fprintf(stderr, "Console %d has an invalid target, MAC or registration keys.\n", index);
			return 1;
		}
		++index;
	}

	// QSettings escreve primeiro num arquivo privado: erro de entrada ou de
	// gravação nunca deve substituir a configuração anterior por uma parcial.
	QTemporaryFile temporary(destination.absoluteDir().filePath(QStringLiteral(".quest2ini-XXXXXX")));
	if (!temporary.open()) { fprintf(stderr, "Could not create temporary output.\n"); return 1; }
	const QString temporaryPath = temporary.fileName();
	temporary.close();
	{
		QSettings out(temporaryPath, QSettings::IniFormat);
		out.beginWriteArray("registered_hosts");
		int n = 0;
		for (const auto &v : hosts) {
			const QJsonObject h = v.toObject();
			out.setArrayIndex(n++);
			out.setValue("target", targetFromName(h["target"].toString()));
			out.setValue("ap_ssid", h["ap_ssid"].toString());
			out.setValue("ap_bssid", h["ap_bssid"].toString());
			out.setValue("ap_key", h["ap_key"].toString());
			out.setValue("ap_name", h["ap_name"].toString());
			out.setValue("server_nickname", h["server_nickname"].toString());
			out.setValue("server_mac", QByteArray::fromHex(h["server_mac"].toString().remove(':').toLatin1()));
			out.setValue("rp_regist_key", QByteArray::fromBase64(h["rp_regist_key"].toString().toLatin1()));
			out.setValue("rp_key_type", h["rp_key_type"].toInt());
			out.setValue("rp_key", QByteArray::fromBase64(h["rp_key"].toString().toLatin1()));
			out.setValue("console_pin", QString());
		}
		out.endArray();
		out.sync();
		if (out.status() != QSettings::NoError) { fprintf(stderr, "Could not write temporary settings.\n"); return 1; }
	}
	QFile encoded(temporaryPath);
	if (!encoded.open(QIODevice::ReadOnly)) { fprintf(stderr, "Could not read temporary settings.\n"); return 1; }
	const QByteArray data = encoded.readAll();
	if (encoded.error() != QFile::NoError || data.isEmpty()) { fprintf(stderr, "Could not read complete settings.\n"); return 1; }
	if (QFileInfo::exists(output) || QFileInfo(output).isSymLink()) { fprintf(stderr, "Output appeared during conversion; choose a new file.\n"); return 1; }
	QSaveFile saved(output);
	saved.setDirectWriteFallback(false);
	if (!saved.open(QIODevice::WriteOnly) ||
		!saved.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner) ||
		saved.write(data) != data.size() || !saved.commit()) {
		fprintf(stderr, "Could not save complete settings.\n");
		return 1;
	}
	printf("Converted %lld console(s).\n", static_cast<long long>(hosts.size()));
	return 0;
}
