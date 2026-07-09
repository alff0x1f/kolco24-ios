//
//  SyncSource.swift
//  kolco24
//
//  Зеркало `data/SyncSource.kt` 1:1: из какого сервера sync-репозиторий тянет данные.
//  `.cloud` — дефолт всех существующих call site'ов; `.local` целит в LAN-сервер гоночного
//  дня (`localApiClient`). Драйвит cloud-persist guard (pin-guard) в репозиториях; полный
//  LAN-режим / координатор — этап 9.
//

/// Куда sync-репозиторий обращается за данными.
enum SyncSource {
    case cloud
    case local
}
