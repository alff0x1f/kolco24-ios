//
//  UploadView.swift
//  kolco24
//
//  Экран «Загрузка данных» (этап 6). Порт ПОВЕДЕНИЯ `ui/upload/UploadScreen.kt`: единое место проверить
//  статус выгрузки взятий, открывается из «Команда → Прочее». Одна секция «Отметки» с receipt-строками
//  «Интернет» (cloud, всегда) и «Финиш» (LAN, только по правилу видимости `UploadModel.finishLine`).
//  Pull-to-refresh == принудительная отправка (отдельной кнопки нет, как на Android); жест держится до
//  конца дренажа. Пустой скоуп — empty-state «Пока нечего загружать» (без жеста — слать нечего).
//
//  Данные и derived полностью в `UploadModel` (`hasContent`/`cloudLine`/`finishLine`/`refresh()`);
//  вьюха только рендерит — доменной логики здесь нет.
//

import SwiftUI

struct UploadView: View {
    @Environment(\.dismiss) private var dismiss
    let model: UploadModel

    var body: some View {
        NavigationStack {
            Group {
                if model.hasContent {
                    content
                } else {
                    emptyState
                }
            }
            .background(Color.paper)
            .navigationTitle("Загрузка данных")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private var content: some View {
        List {
            // Секция «Отметки» — только когда есть взятия (скрыта при нуле, как «Фото»/«Трек»: трек-only
            // скоуп иначе показал бы вводящий в заблуждение ряд «0/0» отметок).
            if model.hasMarks {
                Section {
                    ReceiptRow(line: model.cloudLine)
                        .listRowBackground(Color.card)
                    if let finish = model.finishLine {
                        ReceiptRow(line: finish)
                            .listRowBackground(Color.card)
                    }
                } header: {
                    Text("Отметки")
                }
            }

            // Секция «Фото» — только когда есть кадры (скрыта при нуле, как Android).
            if model.hasPhotos {
                Section {
                    ReceiptRow(line: model.photoCloudLine)
                        .listRowBackground(Color.card)
                    if let finish = model.photoFinishLine {
                        ReceiptRow(line: finish)
                            .listRowBackground(Color.card)
                    }
                } header: {
                    Text("Фото")
                }
            }

            // Секция «Трек» — только когда есть точки GPS (скрыта при нуле, правило секции «Фото»).
            if model.hasTrack {
                Section {
                    ReceiptRow(line: model.trackCloudLine)
                        .listRowBackground(Color.card)
                    if let finish = model.trackFinishLine {
                        ReceiptRow(line: finish)
                            .listRowBackground(Color.card)
                    }
                } header: {
                    Text("Трек")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.paper)
        .refreshable { await model.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 44))
                .foregroundStyle(Color.sub)
            Text("Пока нечего загружать")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.ink)
            Text("Здесь появится статус загрузки отметок после сканирования КП.")
                .font(.system(size: 13))
                .foregroundStyle(Color.sub)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Receipt Row

/// Одна receipt-строка цели: лид-глиф (done → зелёный `GreenCheckCircle`, error/offline → красный
/// `icloud.slash`, иначе приглушённый «отправлено, ждём»), лейбл + вторая строка «{время} · {статус}»,
/// моноширинный `uploaded/total`. Порт `ReceiptLine` из `UploadScreen.kt`.
private struct ReceiptRow: View {
    let line: UploadModel.ReceiptLine

    var body: some View {
        HStack(spacing: 12) {
            glyph
            VStack(alignment: .leading, spacing: 2) {
                Text(line.label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ink)
                if let second = line.secondLine {
                    Text(second)
                        .font(.system(size: 12))
                        .foregroundStyle(line.isError ? Color.brandRed : Color.sub)
                }
            }
            Spacer()
            Text("\(line.uploaded)/\(line.total)")
                .font(.mono(14, weight: .semibold))
                .foregroundStyle(line.isError ? Color.brandRed : Color.sub)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var glyph: some View {
        if line.done {
            GreenCheckCircle(size: 22)
        } else if line.isError {
            ZStack {
                Circle().fill(Color.brandRed.opacity(0.12))
                Image(systemName: "icloud.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.brandRed)
            }
            .frame(width: 22, height: 22)
        } else {
            ZStack {
                Circle().fill(Color.sub.opacity(0.15))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.sub)
            }
            .frame(width: 22, height: 22)
        }
    }
}

// MARK: - Preview

#if DEBUG
/// Хост превью: реальный in-memory граф + пара марок с разными флагами, привязка к их скоупу — receipt
/// «Интернет» показывает частичный прогресс, empty-state отдельным превью не поднимаем (см. счётчики).
private struct UploadViewPreviewHost: View {
    @State private var model: UploadModel?

    var body: some View {
        Group {
            if let model {
                UploadView(model: model)
            } else {
                Color.paper
            }
        }
        .task { await setUp() }
    }

    private func setUp() async {
        guard model == nil else { return }
        guard let env = try? AppEnvironment.inMemory(transport: { _ in
            (Data(), HTTPURLResponse(
                url: URL(string: "https://preview.invalid")!, statusCode: 500,
                httpVersion: nil, headerFields: nil)!)
        }) else { return }

        func mark(_ id: String, cloud: Bool) -> Mark {
            Mark(
                id: id, raceId: 7, teamId: 5, checkpointId: 264, checkpointNumber: 12,
                cost: 5, method: "nfc", cpUid: "04A2B3C4D5E680", cpCode: "9f1a2b3c4d5e6f70",
                present: [1], presentDetails: nil, expectedCount: 1, complete: true,
                takenAt: 1000, updatedAt: 1000, uploadedLocal: false, uploadedCloud: cloud,
                trustedTakenAt: nil, elapsedRealtimeAt: nil, bootCount: nil, locLat: nil, locLon: nil
            )
        }
        try? await env.markStore.upsert(mark("a", cloud: true))
        try? await env.markStore.upsert(mark("b", cloud: false))
        try? await env.markStore.upsert(mark("c", cloud: false))

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)
        self.model = model
    }
}

#Preview("Light") {
    UploadViewPreviewHost()
}

#Preview("Dark") {
    UploadViewPreviewHost()
        .preferredColorScheme(.dark)
}
#endif
