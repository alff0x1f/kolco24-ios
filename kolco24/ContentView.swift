//
//  ContentView.swift
//  kolco24
//
//  Created by Ildus Ilistanov on 06.04.2026.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { MarksView() }
                .tabItem { Label("Отметки", systemImage: "flag.fill") }
                .tag(0)
            NavigationStack { LegendView() }
                .tabItem { Label("Легенда", systemImage: "map.fill") }
                .tag(1)
            NavigationStack { TeamView() }
                .tabItem { Label("Команда", systemImage: "person.3.fill") }
                .tag(2)
        }
        .tint(Color.kolcoOrange)
        .onChange(of: selectedTab) {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}

#Preview {
    ContentView()
}

#Preview("Dark") {
    ContentView().preferredColorScheme(.dark)
}
