//
//  HomeHubDiscovery.swift
//  HomeHub
//
//  Created by Dima Osipa on 6/1/25.
//

import Foundation
import Network
import Combine

struct DiscoveredServer: Identifiable, Equatable, Codable, Hashable {
  let name: String
  let host: String
  let port: Int
  var id: String { "\(host):\(port)" }

  static func == (lhs: DiscoveredServer, rhs: DiscoveredServer) -> Bool {
    return lhs.host == rhs.host && lhs.port == rhs.port
  }
}

@MainActor
class HomeHubDiscovery: ObservableObject {
  @Published var discoveredServers: [DiscoveredServer] = []
  @Published var isDiscovering = false

  private var browser: NWBrowser?
  private var resolveConnections: [String: NWConnection] = [:]
  private let queue = DispatchQueue(label: "HomeHubDiscovery")

  func startDiscovery() {
    stopDiscovery()

    isDiscovering = true
    discoveredServers.removeAll()

    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    parameters.prohibitExpensivePaths = false

    // bonjourWithTXTRecord is required for metadata; plain .bonjour leaves metadata empty.
    browser = NWBrowser(
      for: .bonjourWithTXTRecord(type: "_homehub._tcp", domain: "local."),
      using: parameters
    )

    browser?.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        switch state {
        case .ready:
          print("HomeHub discovery started")
        case .failed(let error):
          print("HomeHub discovery failed: \(error)")
          self?.isDiscovering = false
        case .cancelled:
          print("HomeHub discovery cancelled")
          self?.isDiscovering = false
        default:
          break
        }
      }
    }

    browser?.browseResultsChangedHandler = { [weak self] _, changes in
      Task { @MainActor in
        self?.handleBrowseResults(changes: changes)
      }
    }

    browser?.start(queue: queue)
  }

  func stopDiscovery() {
    browser?.cancel()
    browser = nil
    cancelAllResolutions()
    isDiscovering = false
  }

  private func cancelAllResolutions() {
    for connection in resolveConnections.values {
      connection.cancel()
    }
    resolveConnections.removeAll()
  }

  private func handleBrowseResults(changes: Set<NWBrowser.Result.Change>) {
    for change in changes {
      switch change {
      case .added(let result), .changed(old: _, new: let result, flags: _):
        handleBrowseResult(result)
      case .removed(let result):
        handleRemovedResult(result)
      default:
        break
      }
    }
  }

  private func handleBrowseResult(_ result: NWBrowser.Result) {
    let parsed = parseResult(result)

    if !parsed.host.isEmpty {
      addOrUpdateServer(name: parsed.name, host: parsed.host, port: parsed.port)
      return
    }

    if case .service = result.endpoint {
      resolveService(result, name: parsed.name, preferredPort: parsed.port)
    }
  }

  private func handleRemovedResult(_ result: NWBrowser.Result) {
    if let key = serviceKey(for: result.endpoint) {
      resolveConnections[key]?.cancel()
      resolveConnections.removeValue(forKey: key)
    }

    let parsed = parseResult(result)
    if !parsed.host.isEmpty {
      discoveredServers.removeAll { $0.host == parsed.host && $0.port == parsed.port }
    } else if case .service(let serviceName, _, _, _) = result.endpoint {
      discoveredServers.removeAll { $0.name == serviceName }
    }
  }

  private func resolveService(_ result: NWBrowser.Result, name: String, preferredPort: Int) {
    guard let key = serviceKey(for: result.endpoint) else { return }
    guard resolveConnections[key] == nil else { return }

    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let connection = NWConnection(to: result.endpoint, using: parameters)
    resolveConnections[key] = connection

    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        defer { connection.cancel() }
        guard let remote = connection.currentPath?.remoteEndpoint,
              case .hostPort(let endpointHost, let endpointPort) = remote else { return }

        let host = Self.hostString(from: endpointHost)
        let port = preferredPort != 8080 ? preferredPort : Int(endpointPort.rawValue)

        Task { @MainActor in
          self?.resolveConnections.removeValue(forKey: key)
          self?.addOrUpdateServer(name: name, host: host, port: port)
        }

      case .failed(let error):
        print("Failed to resolve HomeHub service \(key): \(error)")
        connection.cancel()
        Task { @MainActor in
          self?.resolveConnections.removeValue(forKey: key)
        }

      case .cancelled:
        Task { @MainActor in
          self?.resolveConnections.removeValue(forKey: key)
        }

      default:
        break
      }
    }

    connection.start(queue: queue)
  }

  private func parseResult(_ result: NWBrowser.Result) -> (name: String, host: String, port: Int) {
    var name = "HomeHub Server"
    var host = ""
    var port = 8080

    switch result.endpoint {
    case .hostPort(let endpointHost, let endpointPort):
      host = Self.hostString(from: endpointHost)
      port = Int(endpointPort.rawValue)
    case .service(let serviceName, _, _, _):
      name = serviceName
    default:
      break
    }

    if case .bonjour(let txtRecord) = result.metadata {
      let txtDict = parseTXTRecord(txtRecord)
      if let serverName = txtDict["name"] {
        name = serverName
      }
      if let serverPort = txtDict["port"], let portInt = Int(serverPort) {
        port = portInt
      }
    }

    return (name, host, port)
  }

  private func addOrUpdateServer(name: String, host: String, port: Int) {
    guard !host.isEmpty else { return }

    let server = DiscoveredServer(name: name, host: host, port: port)
    if let index = discoveredServers.firstIndex(where: { $0.host == host && $0.port == port }) {
      discoveredServers[index] = server
    } else {
      discoveredServers.append(server)
    }

    print("Found HomeHub service: \(name) at \(host):\(port)")
  }

  private func serviceKey(for endpoint: NWEndpoint) -> String? {
    guard case .service(let name, let type, let domain, _) = endpoint else { return nil }
    return "\(name)|\(type)|\(domain)"
  }

  private static func hostString(from host: NWEndpoint.Host) -> String {
    switch host {
    case .ipv4(let ipv4):
      return "\(ipv4)"
    case .ipv6(let ipv6):
      return "\(ipv6)"
    case .name(let hostname, _):
      return hostname
    @unknown default:
      return ""
    }
  }

  private func parseTXTRecord(_ txtRecord: NWTXTRecord) -> [String: String] {
    var result: [String: String] = [:]

    for (key, entry) in txtRecord {
      switch entry {
      case .string(let value):
        result[key] = value
      case .data(let data):
        if let stringValue = String(data: data, encoding: .utf8) {
          result[key] = stringValue
        }
      case .empty, .none:
        continue
      @unknown default:
        result[key] = ""
      }
    }

    return result
  }

  deinit {
    browser?.cancel()
    for connection in resolveConnections.values {
      connection.cancel()
    }
  }
}
