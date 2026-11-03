import Foundation

/// The file types each viewer opens by extension. Pure values, so they are tested without a window.
enum FileKinds {
    static let images: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "svg", "tif", "tiff", "bmp", "ico", "icns", "avif", "jp2",
    ]
    static let pdf: Set<String> = ["pdf"]
    static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "opus", "ogg", "oga"]
    static let video: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "3gp"]
    /// Notes: the Markdown editor's, never offered a preview.
    static let notes: Set<String> = ["md", "markdown"]
    static var media: Set<String> { audio.union(video) }
}
