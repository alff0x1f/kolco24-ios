//
//  ContentView.swift
//  kolco24
//
//  Created by Ildus Ilistanov on 06.04.2026.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack { MarksView() }
                .tabItem { Label("Отметки", systemImage: "flag.fill") }
            NavigationStack { LegendView() }
                .tabItem { Label("Легенда", systemImage: "map.fill") }
            NavigationStack { TeamView() }
                .tabItem { Label("Команда", systemImage: "person.3.fill") }
        }
        .tint(Color.kolcoOrange)
    }
}

#Preview {
    ContentView()
}
