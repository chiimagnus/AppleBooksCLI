public struct CursorPage<Element> {
    public let items: [Element]
    public let nextCursor: String?
    public let hasMore: Bool
    public let total: Int?

    public init(items: [Element], nextCursor: String?, hasMore: Bool, total: Int? = nil) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.total = total
    }
}

extension CursorPage: Sendable where Element: Sendable {}

public enum CursorPaginationError: Error, Equatable, Sendable {
    case limitOutOfRange
    case invalidCursor
    case filterMismatch
    case staleCursor
    case generationUnavailable
    case internalContractFailure
}
