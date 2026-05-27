//
//  HomeHubDiscovery.swift
//  HomeHub
//
//  Created by Dima Osipa on 6/1/25.
//

import Foundation
import Network
import Combine

/// Bonjour contract shared with the HomeHub server (`app/utils/service_discovery.py`).
private enum HomeHubBonjour {
  static let serviceType = "_homehub._tcp"
  static let domain = "local."

  enum TXTKey {
    static let displayName = "name"
    static let port = "port"
    static let serviceKind = "type"
  }

  /// Published in TXT by the Python server.
  static let expectedServiceKind = "HomeHub VOD Server"
}

struct DiscoveredServer: Identifiable, Equatable, Codable, Hashable {
  let name: String
  let host: String
  let port: Int
  var id: String { "\(host):\(port)" }

  static func == (lhs: DiscoveredServer, rhs: DiscoveredServer) -> Bool {
    return lhs.host == rhs.host && lhs.port == rhs.port
  }

  var httpBaseURL: String {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = port
    guard let url = components.url else {
      return "http://\(host):\(port)"
    }
    var absolute = url.absoluteString
    if absolute.hasSuffix("/") {
      absolute.removeLast()
    }
    return absolute
  }
}

@MainActor
class HomeHubDiscovery: ObservableObject {
  @Published var discoveredServers: [DiscoveredServer] = []
  @Published var isDiscovering = false

  private var browser: NWBrowser?
  private var resolveConnections: [String: NWConnection] = [:]
  /// Maps Bonjour service identity to the last resolved host/port for exact removal.
  private var serviceEndpoints: [String: (host: String, port: Int)] = [:]
  private let queue = DispatchQueue(label: "HomeHubDiscovery")

  func startDiscovery() {
    stopDiscovery()

    isDiscovering = true
    discoveredServers.removeAll()
    serviceEndpoints.removeAll()

    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    parameters.prohibitExpensivePaths = false

    // bonjourWithTXTRecord is required for metadata; plain .bonjour leaves metadata empty.
    browser = NWBrowser(
      for: .bonjourWithTXTRecord(type: HomeHubBonjour.serviceType, domain: HomeHubBonjour.domain),
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
    serviceEndpoints.removeAll()
  }

  private func handleBrowseResults(changes: Set<NWBrowser.Result.Change>) {
    for change in changes {
      switch change {
      case .added(let result):
        handleBrowseResult(result)
      case .changed(old: let old, new: let new, flags: _):
        handleRemovedResult(old)
        handleBrowseResult(new)
      case .removed(let result):
        handleRemovedResult(result)
      default:
        break
      }
    }
  }

  private func handleBrowseResult(_ result: NWBrowser.Result) {
    let parsed = parseResult(result)
    guard parsed.isValid else { return }

    let key = serviceKey(for: result.endpoint)

    if !parsed.host.isEmpty {
      addOrUpdateServer(name: parsed.name, host: parsed.host, port: parsed.port, serviceKey: key)
      return
    }

    if case .service = result.endpoint {
      resolveService(
        result,
        name: parsed.name,
        txtPort: parsed.txtPort,
        serviceKey: key
      )
    }
  }

  private func handleRemovedResult(_ result: NWBrowser.Result) {
    if let key = serviceKey(for: result.endpoint) {
      resolveConnections[key]?.cancel()
      resolveConnections.removeValue(forKey: key)

      if let mapped = serviceEndpoints.removeValue(forKey: key) {
        removeServer(host: mapped.host, port: mapped.port)
        return
      }
    }

    let parsed = parseResult(result)
    if !parsed.host.isEmpty {
      removeServer(host: parsed.host, port: parsed.port)
    }
  }

  private func resolveService(
    _ result: NWBrowser.Result,
    name: String,
    txtPort: Int?,
    serviceKey key: String?
  ) {
    guard let key else { return }
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
        // Server publishes port in the SRV record; TXT does not include `port`.
        let port = txtPort ?? Int(endpointPort.rawValue)

        Task { @MainActor in
          self?.resolveConnections.removeValue(forKey: key)
          self?.addOrUpdateServer(name: name, host: host, port: port, serviceKey: key)
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

  private func parseResult(_ result: NWBrowser.Result) -> (
    name: String, host: String, port: Int, txtPort: Int?, isValid: Bool
  ) {
    var name = "HomeHub Server"
    var host = ""
    var port = 8080
    var txtPort: Int?

    switch result.endpoint {
    case .hostPort(let endpointHost, let endpointPort):
      host = Self.hostString(from: endpointHost)
      port = Int(endpointPort.rawValue)
    case .service(let serviceName, _, _, _):
      name = Self.displayName(fromServiceInstance: serviceName)
    default:
      break
    }

    if case .bonjour(let txtRecord) = result.metadata {
      let txtDict = parseTXTRecord(txtRecord)

      if let kind = txtDict[HomeHubBonjour.TXTKey.serviceKind],
         kind != HomeHubBonjour.expectedServiceKind {
        print("Ignoring non-HomeHub Bonjour service (type=\(kind))")
        return (name, "", port, nil, false)
      }

      if let serverName = txtDict[HomeHubBonjour.TXTKey.displayName] {
        name = serverName
      }
      if let serverPort = txtDict[HomeHubBonjour.TXTKey.port], let portInt = Int(serverPort) {
        txtPort = portInt
        port = portInt
      }
    }

    return (name, host, port, txtPort, true)
  }

  /// Fallback label before TXT resolves (e.g. `homehub` from `homehub._homehub._tcp.local.`).
  private static func displayName(fromServiceInstance serviceName: String) -> String {
    let label = serviceName.split(separator: ".").first.map(String.init) ?? serviceName
    return label.replacingOccurrences(of: "-", with: " ").capitalized
  }

  private func addOrUpdateServer(name: String, host: String, port: Int, serviceKey: String? = nil) {
    guard !host.isEmpty else { return }

    if let serviceKey {
      if let previous = serviceEndpoints[serviceKey],
         previous.host != host || previous.port != port {
        removeServer(host: previous.host, port: previous.port)
      }
      serviceEndpoints[serviceKey] = (host, port)
    }

    let server = DiscoveredServer(name: name, host: host, port: port)
    if let index = discoveredServers.firstIndex(where: { $0.host == host && $0.port == port }) {
      discoveredServers[index] = server
    } else {
      discoveredServers.append(server)
    }

    print("Found HomeHub service: \(name) at \(host):\(port)")
  }

  private func removeServer(host: String, port: Int) {
    discoveredServers.removeAll { $0.host == host && $0.port == port }
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
