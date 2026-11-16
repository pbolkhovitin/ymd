#include "backend.h"

Backend::Backend(const QString &dataDir, QObject *parent)
    : QObject(parent)
    , m_dataDir(dataDir)
{
}

void Backend::toggle()
{
    m_playing = !m_playing;
    m_status = m_playing ? QStringLiteral("Играет") : QStringLiteral("Пауза");
    emit playingChanged();
    emit statusChanged();
}

void Backend::next()
{
    m_status = QStringLiteral("Следующий трек");
    emit statusChanged();
}

void Backend::prev()
{
    m_status = QStringLiteral("Предыдущий трек");
    emit statusChanged();
}

void Backend::search(const QString &text)
{
    m_status = text.trimmed().isEmpty()
        ? QStringLiteral("Введите запрос")
        : QStringLiteral("Поиск: %1").arg(text.trimmed());
    emit statusChanged();
}
