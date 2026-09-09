import Foundation

@inline(__always)
func withCloudBridgeUTF8Bytes<Result>(
    _ value: String,
    _ body: (UnsafePointer<UInt8>, Int) -> Result
) -> Result {
    let byteCount = value.utf8.count
    return value.withCString { pointer in
        body(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), byteCount)
    }
}
