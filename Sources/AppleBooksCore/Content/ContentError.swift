public enum ContentError: Error, Equatable, Sendable {
    case unavailable(BookContentAvailability)
    case bookPathUnavailable
    case unsupportedFormat
    case contentEncryptionUnsupported
    case malformedEncryptionMetadata
}
