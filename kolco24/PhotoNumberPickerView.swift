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

    var body: some View {
        VStack(spacing: 0) {
            TextField("Введите номер КП", text: digitQuery)
                .keyboardType(.numberPad)
                .focused($fieldFocused)
                .font(.mono(18, weight: .semibold))
                .submitLabel(.done)
                .onSubmit(submit)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color.card)
                .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cardRadius)
                        .stroke(model.pickerError != nil ? Color.brandRed : Color.hairline, lineWidth: 1)
                )
                .padding(.horizontal, DS.hPad)
                .padding(.top, 12)

            if let error = model.pickerError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.brandRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.hPad + 8)
                    .padding(.top, 6)
            }

            list
        }
        .background(Color.paper)
        .navigationTitle("Номер КП")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { dismiss() }
            }
        }
        .task { fieldFocused = true }
    }

    @ViewBuilder
    private var list: some View {
        if model.filteredLegend.isEmpty {
            Text("Ничего не найдено")
                .font(.system(size: 15))
                .foregroundStyle(Color.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.hPad + 8)
                .padding(.top, 20)
            Spacer()
        } else {
            List(model.filteredLegend, id: \.id) { cp in
                Button { model.select(cp) } label: {
                    CheckpointPickRow(cp: cp)
                }
                .listRowBackground(Color.card)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    /// Числовое поле: биндинг фильтрует ввод до цифр (поле — номер КП), живой фильтр легенды идёт от `query`.
    private var digitQuery: Binding<String> {
        Binding(
            get: { model.query },
            set: { model.query = $0.filter(\.isNumber) }
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
            if cp.locked {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.ink.opacity(0.08))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.sub)
                }
                .frame(width: 22, height: 22)
            }
            Text(label)
                .font(.mono(16, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(minWidth: 52, alignment: .leading)
            Text(cp.description ?? "")
                .font(.system(size: 15))
                .foregroundStyle(Color.sub)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}
