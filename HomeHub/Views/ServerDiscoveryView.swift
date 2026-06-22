//
//  ServerDiscoveryView.swift
//  HomeHub
//
//  Created by Dima Osipa on 6/1/25.
//

import SwiftUI
import Network

struct ServerDiscoveryView: View {
  @AppStorage("recentServers") private var recentServersData: Data = Data()
  @State private var recentServers: [DiscoveredServer] = []
  @StateObject private var discovery = HomeHubDiscovery()
  @State private var selectedServer: DiscoveredServer?
  @State private var manualServerURL = ""
  @State private var showingManualEntry = false
  @State private var isConnecting = false
  @State private var connectionError: String?
  @FocusState private var focusedField: FocusItem?
  @Namespace private var namespace

  let onServerConnected: (DiscoveredServer) -> Void

  init(onServerConnected: @escaping (DiscoveredServer) -> Void = { _ in }) {
    self.onServerConnected = onServerConnected
  }

  private var gridColumns: [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: 30), count: 3)
  }

  var body: some View {
    NavigationView {
      VStack(spacing: 40) {
        titleSection

        Spacer()

        serverGrid
        recentGrid

        Spacer()

        connectionStatusSection
      }
      .padding()
      .preferredColorScheme(.dark)
    }
    .alert("Enter Server URL", isPresented: $showingManualEntry) {
      TextField("http://192.168.1.100:8080", text: $manualServerURL)
      Button("Connect") {
        connectToManualServer()
      }
      Button("Cancel", role: .cancel) { }
    }
    .onAppear {
      discovery.startDiscovery()
      if let decoded = try? JSONDecoder().decode([DiscoveredServer].self, from: recentServersData) {
        recentServers = decoded
      }
    }
    .onDisappear {
      discovery.stopDiscovery()
    }
  }

  private var titleSection: some View {
    VStack(spacing: 20) {
      Image(systemName: "tv.and.hifispeaker.fill")
        .font(.system(size: 80))
        .foregroundColor(.primary)

      Text("HomeHub")
        .font(.largeTitle)
        .fontWeight(.bold)

      Text("Select a HomeHub server to connect")
        .font(.title2)
        .foregroundColor(.secondary)
    }
    .padding(.top, 50)
  }

  private var serverGrid: some View {
    LazyVGrid(columns: gridColumns, spacing: 30) {
      // Discovered servers
      ForEach(discovery.discoveredServers) { server in
        discoveredServerTile(server)
      }

      // Manual entry tile
      manualEntryTile
      refreshTile
    }
    .focusScope(namespace)
  }

  private var recentGrid: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !recentServers.isEmpty {
        Text("Recent Servers")
          .font(.headline)
          .padding(.leading)

        LazyVGrid(columns: gridColumns, spacing: 30) {
          ForEach(recentServers, id: \.self) { server in
            Button(action: {
              connectToServer(server)
            }) {
              ServerTileView(
                server: server,
                isSelected: focusedField == .server(server.id),
                isConnecting: isConnecting && selectedServer?.id == server.id,
              )
            }
            .buttonStyle(.plain)
            .focused($focusedField, equals: .server(server.id))
          }
        }
      }
    }
  }


  private func discoveredServerTile(_ server: DiscoveredServer) -> some View {
    Button(action: {
      connectToServer(server)
    }) {
      ServerTileView(
        server: server,
        isSelected: focusedField == .server(server.id),
        isConnecting: isConnecting && selectedServer?.id == server.id
      )
    }
    .focused($focusedField, equals: .server(server.id))
    .onChange(of: focusedField) { _, newValue in
      if case .server(let id) = newValue, id == server.id {
        selectedServer = server
      }
    }
  }

  private var manualEntryTile: some View {
    Button(action: {
      presentManualEntry()
    }) {
      ManualServerTileView(
        isSelected: focusedField == .manualEntry,
        isConnecting: isConnecting && showingManualEntry
      )
    }
    .focused($focusedField, equals: .manualEntry)
    .onChange(of: focusedField) { _, newValue in
      if newValue == .manualEntry {
        selectedServer = nil
      }
    }
  }

  private var refreshTile: some View {
    RefreshServerTileView(isSelected: focusedField == .refresh) {
      discovery.startDiscovery()
      connectionError = nil
    }.focused($focusedField, equals: .refresh)
  }

  private var connectionStatusSection: some View {
    Group {
      if let error = connectionError {
        Text("Connection failed: \(error)")
          .foregroundColor(.red)
          .font(.caption)
          .padding()
      }
    }
  }

  private func connectToServer(_ server: DiscoveredServer) {
    isConnecting = true
    connectionError = nil

    Task {
      // Test connection to server
      let apiService = VideoAPIService(baseURL: server.httpBaseURL)

      await apiService.fetchServerInfo()

      await MainActor.run {
        if apiService.errorMessage == nil,
           let discovery = apiService.serverInfo?.discovery,
           discovery.isHomeHubService {
          let connectedServer = Self.canonicalServer(from: server, serverInfo: apiService.serverInfo)
          onServerConnected(connectedServer)
          addServerToRecents(connectedServer)
        } else if apiService.errorMessage == nil {
          connectionError = "Discovered device is not a HomeHub server"
        } else {
          connectionError = apiService.errorMessage
        }
        isConnecting = false
      }
    }
  }

  private func addServerToRecents(_ server: DiscoveredServer) {
    var updated = recentServers.filter { $0 != server }
    updated.insert(server, at: 0)
    if updated.count > 10 { updated = Array(updated.prefix(10)) }

    recentServers = updated
    if let data = try? JSONEncoder().encode(updated) {
      recentServersData = data
    }
  }


  private func connectToManualServer() {
    guard !manualServerURL.isEmpty else { return }

    // Create a temporary server from manual URL
    let components = manualServerURL.replacingOccurrences(of: "http://", with: "").split(separator: ":")
    let host = String(components.first ?? "")
    let port = Int(components.last ?? "") ?? 8080

    let manualServer = DiscoveredServer(name: "Manual Server", host: host, port: port)
    connectToServer(manualServer)
  }

  private func presentManualEntry() {
    showingManualEntry = true
  }

  /// Prefer the mDNS hostname and port the server reports in `/api/info` after Bonjour discovery.
  private static func canonicalServer(from discovered: DiscoveredServer, serverInfo: ServerInfo?) -> DiscoveredServer {
    guard let serverInfo else { return discovered }

    var host = serverInfo.discovery.bonjourService
    if host.hasSuffix(".") {
      host.removeLast()
    }

    return DiscoveredServer(
      name: serverInfo.server.name,
      host: host,
      port: serverInfo.server.port
    )
  }
}


#Preview {
  ServerDiscoveryView()
}
