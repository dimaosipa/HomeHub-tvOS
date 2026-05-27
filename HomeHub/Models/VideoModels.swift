//
//  VideoModels.swift
//  HomeHub
//
//  Created by Dima Osipa on 6/1/25.
//

import Foundation
import SwiftUI

// MARK: - Data Models

struct VideoItem: Codable, Identifiable, Equatable {
  let id: String
  let title: String
  let file: String
  let thumbnail: String?
  let duration: String?
  let size: Int?
  let folder: String?
  let streamURL: String
  let modifiedTime: String?
  var thumbnailImage: UIImage?

  private enum CodingKeys: String, CodingKey {
    case id
    case title = "name"
    case file = "path"
    case thumbnail = "thumbnail_url"
    case duration
    case size
    case folder
    case streamURL = "stream_url"
    case modifiedTime = "modified_time"
  }

  static func == (lhs: VideoItem, rhs: VideoItem) -> Bool {
    return lhs.id == rhs.id
  }
}

struct Folder: Codable, Identifiable, Equatable {
  let id = UUID()
  let name: String
  let path: String

  private enum CodingKeys: String, CodingKey {
    case name, path
  }

  static func == (lhs: Folder, rhs: Folder) -> Bool {
    return lhs.path == rhs.path
  }
}

struct FoldersResponse: Codable {
  let folders: [Folder]
  let totalFolders: Int

  private enum CodingKeys: String, CodingKey {
    case folders
    case totalFolders = "total_folders"
  }
}

struct APIResponse: Codable {
  let videos: [VideoItem]
  let folders: [Folder]
  let currentFolder: String
  let pagination: Pagination

  private enum CodingKeys: String, CodingKey {
    case videos, folders, currentFolder = "current_folder", pagination
  }
}

struct Pagination: Codable {
  let currentPage: Int
  let totalPages: Int
  let perPage: Int
  let totalVideos: Int

  private enum CodingKeys: String, CodingKey {
    case currentPage = "current_page"
    case totalPages = "total_pages"
    case perPage = "per_page"
    case totalVideos = "total_videos"
  }
}

struct ServerInfo: Codable {
  let server: ServerDetails
  let endpoints: Endpoints
  let discovery: Discovery

  struct ServerDetails: Codable {
    let name: String
    let version: String
    let host: String
    let port: Int
    let videoExtensions: [String]
    let videosPerPage: Int

    private enum CodingKeys: String, CodingKey {
      case name, version, host, port
      case videoExtensions = "video_extensions"
      case videosPerPage = "videos_per_page"
    }
  }

  struct Endpoints: Codable {
    let folders: String
    let refreshCache: String
    let search: String
    let videos: String

    private enum CodingKeys: String, CodingKey {
      case folders, search, videos
      case refreshCache = "refresh_cache"
    }
  }

  struct Discovery: Codable {
    let bonjourService: String
    let serviceType: String
    let serviceName: String?

    private enum CodingKeys: String, CodingKey {
      case bonjourService = "bonjour_service"
      case serviceType = "service_type"
      case serviceName = "service_name"
    }

    var isHomeHubService: Bool {
      serviceType.contains("_homehub._tcp")
    }
  }
}

struct SearchResponse: Codable {
  let pagination: Pagination
  let query: String
  let results: SearchResults
  let totalResults: Int

  private enum CodingKeys: String, CodingKey {
    case pagination, query, results
    case totalResults = "total_results"
  }
}

struct SearchResults: Codable {
  let videos: [VideoItem]
  let folders: [Folder]
}
