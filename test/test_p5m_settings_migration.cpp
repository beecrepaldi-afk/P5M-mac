#include "macSettingsMigration.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <cstdio>
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    QTemporaryDir folder;
    if (!folder.isValid()) return 1;
    QSettings source(folder.filePath("source.ini"), QSettings::IniFormat);
    QSettings target(folder.filePath("target.ini"), QSettings::IniFormat);
    source.setValue("settings/volume", 80);
    source.setValue("registered/placeholder", "synthetic-only");
    source.sync();
    if (!copyMacSettingsIfEmpty(source, target) || target.value("settings/volume").toInt() != 80) return 2;
    target.setValue("settings/volume", 25);
    if (!copyMacSettingsIfEmpty(source, target) || target.value("settings/volume").toInt() != 25) return 3;
    if (source.value("settings/volume").toInt() != 80) return 4;
    puts("P5M settings migration: copies only empty destinations and preserves originals");
}
