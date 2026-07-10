//
//  PhotoLightboxView.swift
//  kolco24
//
//  Полноэкранный просмотрщик кадров фото-взятий (только просмотр). Порт `PhotoLightbox`
//  (`ui/marks/MarksScreen.kt`): `TabView(.page)` листает по ГЛОБАЛЬНОЙ ленте кадров всех взятий
//  (`lightboxPhotos`, порядок сетки), открываясь на кадре тапнутого тайла. Счётчик `k/N` при >1 кадре;
//  КП-чип резолвится ПОСТРАНИЧНО из взятия своего кадра (свайп между взятиями меняет токен). `ShareLink`
//  шлёт текущий кадр (иммутабельный даунскейл-JPEG на диске) системному шиту. Свайп вниз за порог —
//  закрытие (иначе пружина назад), фон затемняется по мере перетаскивания; чёрный фон, статус-бар скрыт.
//
//  Абсолютные пути резолвит инжектированное замыкание `urlFor` (над `PhotoStorage.rootURL`) — вьюхе не
//  нужен ни GRDB, ни `Photo/` (grep-инвариант).
//

import SwiftUI

// MARK: - Токен КП тайла
/// Display-токен КП тайла: `<стоимость>-<номер>` для scoring-КП, голый номер при нулевой цене
/// (locked/технический). Общий для тайла сетки и КП-чипа лайтбокса.
func markTileToken(_ tile: MarkTile) -> String {
    tile.cost > 0 ? "\(tile.cost)-\(tile.number)" : tile.number
}

// MARK: - PhotoLightboxView
struct PhotoLightboxView: View {
    /// Глобальная лента кадров (все взятия, порядок сетки).
    let photos: [LightboxPhoto]
    /// Индекс кадра, на котором открыться (первый кадр тапнутого тайла).
    let initialIndex: Int
    /// Резолвер относительного пути кадра в абсолютный URL (`marks/<id>/<uuid>.jpg` → файл).
    let urlFor: (String) -> URL?

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    /// Вертикальное смещение drag-to-dismiss.
    @State private var dragOffset: CGFloat = 0

    /// Порог перетаскивания, за которым отпускание закрывает просмотрщик (иначе пружина назад).
    private let dismissThreshold: CGFloat = 120

    init(photos: [LightboxPhoto], initialIndex: Int, urlFor: @escaping (String) -> URL?) {
        self.photos = photos
        self.initialIndex = initialIndex
        self.urlFor = urlFor
        // Клип на валидный диапазон — защита от рассинхрона ленты и стартового индекса.
        _index = State(initialValue: min(max(initialIndex, 0), max(photos.count - 1, 0)))
    }

    /// Прозрачность фона: затемняется к 0.3 по мере приближения к порогу закрытия — превью закрытия.
    private var backdropOpacity: Double {
        let progress = min(abs(dragOffset) / dismissThreshold, 1)
        return 1 - progress * 0.7
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backdropOpacity).ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { offset, photo in
                    LightboxPage(url: urlFor(photo.path))
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Только вертикальное перетаскивание (горизонталь отдаём пейджеру).
                        if abs(value.translation.height) > abs(value.translation.width) {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { _ in
                        if abs(dragOffset) > dismissThreshold {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                        }
                    }
            )

            overlay
        }
        .statusBarHidden(true)
    }

    // MARK: - Оверлей (чип КП, счётчик, шаринг/закрытие)
    @ViewBuilder
    private var overlay: some View {
        let current = photos.indices.contains(index) ? photos[index] : nil

        VStack {
            HStack(alignment: .top) {
                if let current {
                    PhotoKpChip(token: markTileToken(current.tile), scale: 1.35)
                }
                Spacer()
                if photos.count > 1 {
                    Text("\(index + 1)/\(photos.count)")
                        .font(.mono(15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.top, 6)
                }
                Spacer()
                HStack(spacing: 4) {
                    if let current, let url = urlFor(current.path) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }
                    }
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                }
            }
            .padding(.horizontal, 8)
            Spacer()
        }
        .opacity(backdropOpacity)
    }
}

// MARK: - Одна страница лайтбокса
private struct LightboxPage: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.black
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                // Файл отсутствует/нечитаем — нейтральная заглушка (тот же контракт, что тайл).
                Image(systemName: "photo")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }
}

// MARK: - КП-чип поверх кадра
/// Токен КП поверх кадра (тайл-угол / страница лайтбокса): тёмная плашка + белый mono-токен,
/// читаемый на любом фоне. [scale] увеличивает чип на полноэкранной странице.
struct PhotoKpChip: View {
    let token: String
    var scale: CGFloat = 1

    var body: some View {
        Text(token)
            .font(.mono(13 * scale, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7 * scale)
            .padding(.vertical, 4 * scale)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6 * scale))
    }
}
