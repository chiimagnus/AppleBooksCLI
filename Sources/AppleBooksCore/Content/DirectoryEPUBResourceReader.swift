import Darwin
import Foundation

final class DirectoryEPUBResourceReader: EPUBResourceReader {
    let root: URL

    init(root: URL) throws {
        let canonicalRoot = root.standardizedFileURL
        var metadata = stat()
        guard lstat(canonicalRoot.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw ContentError.unavailable(.missing) }
            throw ContentError.unavailable(.unknown)
        }
        guard metadata.st_mode & S_IFMT != S_IFLNK else {
            throw EPUBResourceError.unsafeResource
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ContentError.unsupportedFormat
        }
        let availability = BookContentAvailability.inspect(canonicalRoot)
        guard availability == .available else {
            throw ContentError.unavailable(availability)
        }
        self.root = canonicalRoot
    }

    func contains(_ path: EPUBPath) throws -> Bool {
        guard try preflightResource(path, missingIsFalse: true) != nil else { return false }
        let descriptor = try openResource(path, missingIsFalse: true)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        _ = try requireRegularFile(descriptor)

        switch BookContentAvailability.inspect(resourceURL(path)) {
        case .missing:
            return false
        case .notDownloaded:
            throw ContentError.unavailable(.notDownloaded)
        case .unknown:
            throw ContentError.unavailable(.unknown)
        case .available:
            return true
        }
    }

    func readExactResource(_ path: EPUBPath, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0 else { throw EPUBResourceError.invalidByteBudget }
        let preflight: stat
        do {
            guard let metadata = try preflightResource(path, missingIsFalse: false) else {
                throw ContentError.unavailable(.missing)
            }
            preflight = metadata
        } catch EPUBResourceError.missingResource {
            throw ContentError.unavailable(.missing)
        }
        guard UInt64(preflight.st_size) <= UInt64(maxBytes) else {
            throw EPUBResourceError.resourceTooLarge
        }

        let descriptor: Int32
        do {
            descriptor = try openResource(path, missingIsFalse: false)
        } catch EPUBResourceError.missingResource {
            throw ContentError.unavailable(.missing)
        }
        guard descriptor >= 0 else { throw ContentError.unavailable(.missing) }
        defer { close(descriptor) }

        let metadata = try requireRegularFile(descriptor)
        guard UInt64(metadata.st_size) <= UInt64(maxBytes) else {
            throw EPUBResourceError.resourceTooLarge
        }
        switch BookContentAvailability.inspect(resourceURL(path)) {
        case .missing:
            throw ContentError.unavailable(.missing)
        case .notDownloaded:
            throw ContentError.unavailable(.notDownloaded)
        case .unknown:
            throw ContentError.unavailable(.unknown)
        case .available:
            break
        }

        var output = Data()
        while true {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return output }
            guard count > 0 else { throw EPUBResourceError.unreadableResource }
            guard output.count <= maxBytes - count else { throw EPUBResourceError.resourceTooLarge }
            output.append(buffer, count: count)
        }
    }

    private func resourceURL(_ path: EPUBPath) -> URL {
        path.relativePath.split(separator: "/").reduce(root) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }
    }

    private func preflightResource(_ path: EPUBPath, missingIsFalse: Bool) throws -> stat? {
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw EPUBResourceError.unsafeResource }
        var current = rootDescriptor
        defer {
            if current != rootDescriptor { close(current) }
            close(rootDescriptor)
        }

        let components = path.relativePath.split(separator: "/").map(String.init)
        guard let final = components.last else { throw EPUBResourceError.unsafeResource }
        for component in components.dropLast() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else {
                if missingIsFalse && (errno == ENOENT || errno == ENOTDIR) { return nil }
                if errno == ENOENT || errno == ENOTDIR { throw EPUBResourceError.missingResource }
                throw EPUBResourceError.unsafeResource
            }
            if current != rootDescriptor { close(current) }
            current = next
        }

        var metadata = stat()
        let result = final.withCString { fstatat(current, $0, &metadata, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else {
            if missingIsFalse && (errno == ENOENT || errno == ENOTDIR) { return nil }
            if errno == ENOENT || errno == ENOTDIR { throw EPUBResourceError.missingResource }
            throw EPUBResourceError.unsafeResource
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0 else {
            throw EPUBResourceError.unsafeResource
        }
        return metadata
    }

    private func requireRegularFile(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0 else {
            throw EPUBResourceError.unsafeResource
        }
        return metadata
    }

    private func openResource(_ path: EPUBPath, missingIsFalse: Bool) throws -> Int32 {
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw EPUBResourceError.unsafeResource }
        var current = rootDescriptor

        let components = path.relativePath.split(separator: "/").map(String.init)
        guard components.isEmpty == false else {
            close(rootDescriptor)
            throw EPUBResourceError.unsafeResource
        }

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isLast ? 0 : O_DIRECTORY)
            let next = openat(current, component, flags)
            if current != rootDescriptor { close(current) }
            if next < 0 {
                close(rootDescriptor)
                if missingIsFalse && (errno == ENOENT || errno == ENOTDIR) { return -1 }
                if errno == ENOENT || errno == ENOTDIR { throw EPUBResourceError.missingResource }
                throw EPUBResourceError.unsafeResource
            }
            current = next
        }
        close(rootDescriptor)
        return current
    }
}
