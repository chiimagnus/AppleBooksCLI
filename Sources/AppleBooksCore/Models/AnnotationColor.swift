public enum AnnotationQueryInputError: Error, Equatable, Sendable {
    case unknownColor
    case invalidDateRange
}

public enum AnnotationColor: Int64, CaseIterable, Sendable {
    case green = 1
    case blue = 2
    case yellow = 3
    case pink = 4
    case purple = 5

    public init(name: String) throws {
        guard name.utf8.allSatisfy({ $0 < 0x80 }) else {
            throw AnnotationQueryInputError.unknownColor
        }
        switch name.lowercased() {
        case "green": self = .green
        case "blue": self = .blue
        case "yellow": self = .yellow
        case "pink": self = .pink
        case "purple": self = .purple
        default: throw AnnotationQueryInputError.unknownColor
        }
    }
}
