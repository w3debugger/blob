import Foundation

struct BigFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let size: Int64
    let modified: Date

    var path: String { url.path }
    var name: String { url.lastPathComponent }
}

enum ScanState: Equatable {
    case idle
    case scanning(path: String, scanned: Int, found: Int)
    case done(total: Int, scanned: Int, elapsed: TimeInterval)
    case error(String)
}

enum ScanMode: String, CaseIterable, Identifiable, Hashable {
    case files
    case dirs
    case devjunk

    var id: String { rawValue }
    var label: String {
        switch self {
        case .files:   return "files"
        case .dirs:    return "dirs"
        case .devjunk: return "dev"
        }
    }
}

enum SizeFilter: Int, CaseIterable, Identifiable {
    case mb1 = 1
    case mb10 = 10
    case mb50 = 50
    case mb100 = 100
    case mb250 = 250
    case mb500 = 500
    case gb1 = 1024
    case gb2 = 2048
    case gb5 = 5120
    case gb10 = 10240

    var id: Int { rawValue }
    var bytes: Int64 { Int64(rawValue) * 1024 * 1024 }
    var label: String {
        switch self {
        case .mb1:   return ">1MB"
        case .mb10:  return ">10MB"
        case .mb50:  return ">50MB"
        case .mb100: return ">100MB"
        case .mb250: return ">250MB"
        case .mb500: return ">500MB"
        case .gb1:   return ">1GB"
        case .gb2:   return ">2GB"
        case .gb5:   return ">5GB"
        case .gb10:  return ">10GB"
        }
    }
}

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useGB, .useMB, .useKB]
    return f
}()

func formatBytes(_ bytes: Int64) -> String {
    byteFormatter.string(fromByteCount: bytes)
}
