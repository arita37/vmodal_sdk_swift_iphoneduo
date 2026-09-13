import Foundation

public enum RouteCategory: String, Codable, Sendable {
    case active
    case usersApi
    case image
    case signedSingle
    case multipartExperimental
    case deprecated
    case disabled
}

public struct RouteSpec: Codable, Sendable, Equatable {
    public let name: String
    public let method: String
    public let path: String
    public let category: RouteCategory
    public let source: String

    public init(name: String, method: String, path: String, category: RouteCategory, source: String) {
        self.name = name
        self.method = method
        self.path = path
        self.category = category
        self.source = source
    }
}

public enum Routes {
    public static let prefix = routeValue("prefix")
    public static let usersAPIPrefix = routeValue("usersApiPrefix")

    public static let health = routeValue("auth.health")
    public static let searchClient = routeValue("searches.search_video")
    public static let groups = routeValue("collections.list_groups")
    public static let indexationJobs = routeValue("indexes.jobs_list")
    public static let indexationSubmit = routeValue("indexes.create_index")
    public static let indexationStatus = routeValue("indexes.index_status")
    public static let indexationDelete = routeValue("indexes.delete_index")
    public static let upload = routeValue("collections.upload_file")
    public static let uploadFolder = routeValue("collections.upload_folder")
    public static let uploadGoogleDriveFolder = routeValue("collections.upload_google_drive_folder")
    public static let uploadMetadataJSONL = routeValue("collections.upload_metadata_jsonl")
    public static let collectionDescriptionUpdate = routeValue("collections.update_description")
    public static let collectionDelete = routeValue("collections.delete")
    public static let collectionAddAssets = routeValue("collections.add_assets")
    public static let adminUserStats = routeValue("admin.user_stats")
    public static let uploadMetadataItemParquetInternal = routeValue("metadata.internal_fallback")
    public static let imageGetURL = routeValue("images.get_url")
    public static let imageGetURLBulk = routeValue("images.get_url_bulk")
    public static let imageGetImage = routeValue("images.get_image_from_url")
    public static let imageGetImageBulk = routeValue("images.get_image_bulk_from_urls")
    public static let authMe = routeValue("auth.me")
    public static let adminUsage = routeValue("admin.usage")
    public static let adminCacheStats = routeValue("admin.cache_stats")
    public static let r2Credentials = routeValue("r2.credentials")
    public static let r2UploadFile = routeValue("r2.presign_upload_file")
    public static let r2UploadFolderVideo = routeValue("r2.presign_upload_folder_video")
    public static let externalUploadGetSignedURL = routeValue("collections.video_upload.presign")
    public static let externalUploadDone = routeValue("collections.video_upload.done")
    public static let externalUploadMultipartCreate = routeValue("multipart.create")
    public static let externalUploadMultipartSignParts = routeValue("multipart.sign_parts")
    public static let externalUploadMultipartStatus = routeValue("multipart.status")
    public static let externalUploadMultipartComplete = routeValue("multipart.complete")
    public static let externalUploadMultipartAbort = routeValue("multipart.abort")

    public static func full(_ path: String) throws -> String { try addPrefix(path, prefix: prefix) }
    public static func usersFull(_ path: String) throws -> String { try addPrefix(path, prefix: usersAPIPrefix) }

    public static func replacingPathSegment(in path: String, placeholder: String, value: String) throws -> String {
        guard let clean = value.addingPercentEncoding(withAllowedCharacters: .urlPathSegmentAllowed), !clean.isEmpty else {
            throw ValidationError("invalid path segment")
        }
        return path.replacingOccurrences(of: "{\(placeholder)}", with: clean)
    }

    private static func addPrefix(_ path: String, prefix: String) throws -> String {
        guard URL(string: path)?.scheme == nil else {
            throw ValidationError("absolute URLs are not allowed in the API route table")
        }
        return prefix + (path.hasPrefix("/") ? path : "/\(path)")
    }
}

private extension CharacterSet {
    static let urlPathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#[]@!$&'()*+,;=:%")
        return set
    }()
}
