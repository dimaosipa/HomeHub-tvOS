//
//  MainView.swift
//  HomeHub
//
//  Created by Dima Osipa on 6/1/25.
//

import SwiftUI
import AVKit

struct MainView: View {
  let server: DiscoveredServer
  @StateObject private var apiService: VideoAPIService
  @State private var selectedTab = 0
  let onDisconnect: () -> Void

  init(server: DiscoveredServer, onDisconnect: @escaping () -> Void = {}) {
    self.server = server
    self.onDisconnect = onDisconnect
    self._apiService = StateObject(wrappedValue: VideoAPIService(baseURL: server.httpBaseURL))
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      AllVideosView()
        .tabItem {
          Label("Videos", systemImage: "play.rectangle.fill")
        }
        .tag(0)

      FoldersView()
        .tabItem {
          Label("Folders", systemImage: "folder.fill")
        }
        .tag(1)

      VideoSearchView()
        .tabItem {
          Label("Search", systemImage: "magnifyingglass")
        }
        .tag(2)

      AppSettingsView(onDisconnect: onDisconnect)
        .tabItem {
          Label("Settings", systemImage: "gear")
        }
        .tag(3)
    }
    .environmentObject(apiService)
    .preferredColorScheme(.dark)
    .task {
      await apiService.fetchServerInfo()
      await apiService.fetchVideos()
    }
  }
}

#Preview {
  MainView(server: DiscoveredServer(name: "Test Server", host: "127.0.0.1", port: 8080)) { }
}
