import Foundation

struct AnnotationPresentationGroup: Equatable, Sendable {
    let members: [ExportRecord]

    static func make(
        records: [ExportRecord],
        groupConsecutiveNullLocationFragments: Bool
    ) -> [AnnotationPresentationGroup] {
        guard groupConsecutiveNullLocationFragments else {
            return records.map { AnnotationPresentationGroup(members: [$0]) }
        }

        var groups: [AnnotationPresentationGroup] = []
        var pending: [ExportRecord] = []
        for record in records {
            if hasPresentationLocation(record) {
                if pending.isEmpty {
                    groups.append(AnnotationPresentationGroup(members: [record]))
                } else {
                    pending.append(record)
                    groups.append(AnnotationPresentationGroup(members: pending))
                    pending.removeAll(keepingCapacity: true)
                }
            } else {
                pending.append(record)
            }
        }
        if pending.isEmpty == false {
            groups.append(AnnotationPresentationGroup(members: pending))
        }
        return groups
    }

    var locatedMember: ExportRecord? {
        members.last(where: Self.hasPresentationLocation)
    }

    private static func hasPresentationLocation(_ record: ExportRecord) -> Bool {
        switch record.payload {
        case let .epub(enriched):
            enriched.annotation.location != nil
        case .pdf:
            true
        }
    }
}
