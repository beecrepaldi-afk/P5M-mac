#pragma once

#include <QSettings>
#include <QStringList>

// Copia localmente sem sobrescrever o P5M nem alterar a instalação original.
// Nunca escreve valores de configuração no diário.
inline bool copyMacSettingsIfEmpty(QSettings &source, QSettings &target)
{
    source.setFallbacksEnabled(false);
    target.setFallbacksEnabled(false);
    if (!target.allKeys().isEmpty() || source.allKeys().isEmpty())
        return true;
    for (const auto &key : source.allKeys())
        target.setValue(key, source.value(key));
    target.sync();
    return target.status() == QSettings::NoError;
}

inline void migrateMacSettings()
{
    QSettings oldBase("Chiaki", "Chiaki"), newBase("P5M", "P5M");
    newBase.setFallbacksEnabled(false);
    if (!newBase.allKeys().isEmpty())
        return;
    oldBase.setFallbacksEnabled(false);
    QStringList profiles;
    const int count = oldBase.beginReadArray("profiles");
    for (int i = 0; i < count; ++i) {
        oldBase.setArrayIndex(i);
        profiles.append(oldBase.value("settings/profile_name").toString());
    }
    oldBase.endArray();
    // A base vai por último: se um perfil falhar, a próxima abertura tenta de novo.
    for (const auto &name : profiles) {
        if (name.isEmpty())
            continue;
        QSettings source("Chiaki", "Chiaki-" + name), target("P5M", "P5M-" + name);
        if (!copyMacSettingsIfEmpty(source, target))
            return;
    }
    QSettings sourceRender("Chiaki", "pl_render_params"), targetRender("P5M", "pl_render_params");
    if (!copyMacSettingsIfEmpty(sourceRender, targetRender))
        return;
    copyMacSettingsIfEmpty(oldBase, newBase);
}
