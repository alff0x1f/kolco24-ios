//
//  PhotoNumberPickerView.swift
//  kolco24
//
//  Пикер номера КП для ветки фото-отметки «askNumber» (нет свежего NFC-взятия в 3-мин окне авто-attach).
//  Порт ПОВЕДЕНИЯ `ui/photo/PhotoNumberPicker.kt`: числовое поле фильтрует легенду вживую
//  (`filterCheckpointsByQuery`), тап по строке / submit точного номера → `resolvePhotoCheckpoint` →
//  переход в камеру standalone-ветки. Номера вне легенды → инлайн-ошибка «КП с таким номером нет в
//  легенде» и НИ одной марки. Залоченные КП (`locked`, `cost = nil`) перечисляются и выбираемы
//  намеренно — ядро сценария «метку сорвали». Данные тут не пишутся; строку создаёт коммит камеры.
//
//  Драйвит `PhotoModel` (`query`/`filteredLegend`/`pickerError`/`submit`/`select`); живёт flat в
//  `kolco24/` (импорт только SwiftUI).
//

import SwiftUI

struct PhotoNumberPickerView: View {
    @Bindable var model: PhotoModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    private var exactMatch: Checkpoint? {
        guard let number = Int(model.query) else { return nil }
        return model.filteredLegend.first { $0.number == number }
    }

    /// Точное совпадение номера — первой строкой, остальные в порядке легенды.
    private var rows: [Checkpoint] {
        guard let exact = exactMatch else { return model.filteredLegend }
        return [exact] + model.filteredLegend.filter { $0.id != exact.id }
    }

    private var noMatches: Bool { !model.query.isEmpty && model.filteredLegend.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            numberInput
            list
        }
        .background(Color.paper)
        .navigationTitle("Фото КП")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { dismiss() }
            }
        }
        .task { fieldFocused = true }
    }

    // MARK: - Ввод номера

    private var numberInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("КП")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.sub)
                TextField("", text: digitQuery, prompt: Text("00").foregroundStyle(Color.sub.opacity(0.3)))
                    .keyboardType(.numberPad)
                    .focused($fieldFocused)
                    .font(.mono(58, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                    .tint(Color.kolcoOrange)
                    .submitLabel(.done)
                    .onSubmit(submit)
                    .accessibilityLabel("Номер КП")
                if !model.query.isEmpty {
                    Button { model.updateQuery("") } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.sub.opacity(0.5))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Стереть номер")
                }
            }

            Capsule()
                .fill(underlineColor)
                .frame(height: 3)
                .animation(.easeOut(duration: 0.2), value: underlineColor)

            Text(status)
                .font(.system(size: 14, weight: isError ? .semibold : .regular))
                .foregroundStyle(isError ? Color.brandRed : Color.sub)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        }
        .padding(.horizontal, DS.hPad + 4)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var isError: Bool { model.pickerError != nil || noMatches }

    private var underlineColor: Color {
        if isError { return .brandRed }
        if exactMatch != nil { return .kolcoOrange }
        return Color.ink.opacity(0.12)
    }

    private var status: String {
        if let error = model.pickerError { return error }
        if noMatches { return "В легенде нет КП \(model.query)" }
        if model.query.isEmpty { return "Номер написан на табличке КП" }
        if exactMatch != nil { return "Нажмите на КП, чтобы открыть камеру" }
        return "Введите номер полностью или выберите из списка"
    }

    // MARK: - Список

    @ViewBuilder
    private var list: some View {
        if noMatches {
            Spacer()
        } else {
            List {
                Section {
                    ForEach(rows, id: \.id) { cp in
                        let isExact = cp.id == exactMatch?.id
                        Button { model.select(cp) } label: {
                            CheckpointPickRow(cp: cp, highlighted: isExact)
                        }
                        .listRowBackground(isExact ? Color.kolcoOrange.opacity(0.12) : Color.card)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 8, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .animation(.snappy(duration: 0.25), value: rows.map(\.id))
        }
    }

    /// Числовое поле: биндинг фильтрует ввод до цифр (поле — номер КП) и сбрасывает устаревшую ошибку;
    /// живой фильтр легенды идёт от `query`.
    private var digitQuery: Binding<String> {
        Binding(
            get: { model.query },
            set: { model.updateQuery($0) }
        )
    }

    private func submit() {
        guard let number = Int(model.query) else { return }
        model.submit(number: number)
    }
}

// MARK: - Строка КП пикера

private struct CheckpointPickRow: View {
    let cp: Checkpoint
    let highlighted: Bool

    /// «<cost>-<number>» (padded) для открытого КП; только номер — для залоченного (cost скрыт).
    private var label: String {
        let number = String(format: "%02d", cp.number)
        if let cost = cp.cost, cost != 0 {
            return "\(cost)-\(number)"
        }
        return number
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if cp.locked {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(Color.ink.opacity(0.08))
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.sub)
                    }
                    .frame(width: 18, height: 18)
                }
                Text(label)
                    .font(.mono(16, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(highlighted ? Color.kolcoOrange : (cp.locked ? Color.sub : Color.ink))
            }
            .frame(width: 60, alignment: .leading)

            Text(cp.locked ? (cp.description ?? "Описание скрыто") : (cp.description ?? ""))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(cp.locked ? Color.sub : Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            cameraBadge
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Открыть камеру")
    }

    @ViewBuilder
    private var cameraBadge: some View {
        if highlighted {
            Image(systemName: "camera.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.kolcoOrange))
        } else {
            Image(systemName: "camera")
                .font(.system(size: 15))
                .foregroundStyle(Color.sub.opacity(0.6))
                .frame(width: 34, height: 34)
        }
    }
}
