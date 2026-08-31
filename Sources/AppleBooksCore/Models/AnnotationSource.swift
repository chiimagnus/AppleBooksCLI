public enum AnnotationSource: Equatable, Sendable {
    case currentLibrary(Book)
    case historicalInferred(HistoricalBookMetadata)
    case unmapped
}

public struct EnrichedAnnotation: Equatable, Sendable {
    public let annotation: Annotation
    public let source: AnnotationSource

    public init(annotation: Annotation, source: AnnotationSource) {
        self.annotation = annotation
        self.source = source
    }
}
