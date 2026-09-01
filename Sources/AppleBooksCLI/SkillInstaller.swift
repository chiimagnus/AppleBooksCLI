import Darwin
import Foundation

enum SkillInstallerError: Error, Equatable, Sendable {
    case packagedSourceUnavailable
    case packagedSourceUnsafe
    case packagedSkillUnavailable
    case packagedSkillUnsafe
    case invalidCodexHome
    case invalidSkillsDirectory
    case unsafeTarget
    case targetExists
    case stagingUnsafe
    case installFailed
    case cleanupFailed
    case backupFailed
    case replacementFailed
    case rollbackFailed
}

enum SkillInstallerWarning: String, Equatable, Sendable {
    case previousVersionBackupRetained = "previous_version_backup_retained"
}

struct SkillInstallationResult: Equatable, Sendable {
    let target: URL
    let replaced: Bool
    let warnings: [SkillInstallerWarning]
}

struct SkillInstallerFileOperations {
    let createDirectory: (URL) throws -> Void
    let copyItem: (URL, URL) throws -> Void
    let moveItem: (URL, URL) throws -> Void
    let removeItem: (URL) throws -> Void
    let trashItem: (URL) throws -> Void

    static var live: SkillInstallerFileOperations {
        let fileManager = FileManager.default
        return SkillInstallerFileOperations(
            createDirectory: { url in
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            },
            copyItem: fileManager.copyItem(at:to:),
            moveItem: fileManager.moveItem(at:to:),
            removeItem: fileManager.removeItem(at:),
            trashItem: { url in
                var resultingURL: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
            }
        )
    }
}

struct SkillInstallPaths: Equatable, Sendable {
    let source: URL
    let codexHome: URL
    let skillsDirectory: URL
    let target: URL

    func stagingURL(id: UUID) throws -> URL {
        try controlledChild(named: ".applebookscli-install-\(id.uuidString.lowercased())")
    }

    func backupURL(id: UUID) throws -> URL {
        try controlledChild(named: ".applebookscli-backup-\(id.uuidString.lowercased())")
    }

    private func controlledChild(named basename: String) throws -> URL {
        let candidate = skillsDirectory.appendingPathComponent(basename, isDirectory: true).standardizedFileURL
        guard candidate.lastPathComponent == basename,
              candidate.deletingLastPathComponent() == skillsDirectory else {
            throw SkillInstallerError.unsafeTarget
        }
        return candidate
    }
}

struct SkillInstaller {
    static let skillName = "applebookscli"

    let sourceURL: URL
    let environment: [String: String]
    let homeDirectory: URL
    let fileOperations: SkillInstallerFileOperations

    init(
        sourceURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileOperations: SkillInstallerFileOperations = .live
    ) {
        self.sourceURL = sourceURL
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileOperations = fileOperations
    }

    func resolvedPaths() throws -> SkillInstallPaths {
        let source = try validatedSource()
        let codexHome = try resolvedCodexHome()
        let skills = try resolvedSkillsDirectory(codexHome: codexHome)
        let target = skills.appendingPathComponent(Self.skillName, isDirectory: true).standardizedFileURL
        guard target.lastPathComponent == Self.skillName,
              target.deletingLastPathComponent() == skills else {
            throw SkillInstallerError.unsafeTarget
        }
        if [.symlink, .other].contains(nodeKind(at: target)) {
            throw SkillInstallerError.unsafeTarget
        }
        return SkillInstallPaths(source: source, codexHome: codexHome, skillsDirectory: skills, target: target)
    }

    @discardableResult
    func install(force: Bool = false) throws -> SkillInstallationResult {
        let paths = try resolvedPaths()
        let initialTargetKind = nodeKind(at: paths.target)
        if force == false, initialTargetKind != .missing {
            throw SkillInstallerError.targetExists
        }
        try ensureSkillsDirectory(paths.skillsDirectory)
        let staging = try prepareStaging(paths)

        if nodeKind(at: paths.target) == .missing {
            do {
                try fileOperations.moveItem(staging, paths.target)
                return SkillInstallationResult(target: paths.target, replaced: false, warnings: [])
            } catch {
                try failAfterCleaningStaging(error, staging: staging, skillsDirectory: paths.skillsDirectory)
            }
        }

        guard force, nodeKind(at: paths.target) == .directory else {
            try failAfterCleaningStaging(
                SkillInstallerError.unsafeTarget,
                staging: staging,
                skillsDirectory: paths.skillsDirectory
            )
        }
        return try replaceExistingTarget(paths: paths, staging: staging)
    }

    private func prepareStaging(_ paths: SkillInstallPaths) throws -> URL {
        let staging = try paths.stagingURL(id: UUID())
        guard nodeKind(at: staging) == .missing else {
            throw SkillInstallerError.stagingUnsafe
        }
        do {
            try fileOperations.copyItem(paths.source, staging)
            try validateStaging(staging)
            return staging
        } catch {
            try failAfterCleaningStaging(error, staging: staging, skillsDirectory: paths.skillsDirectory)
        }
    }

    private func replaceExistingTarget(paths: SkillInstallPaths, staging: URL) throws -> SkillInstallationResult {
        guard nodeKind(at: paths.target) == .directory else {
            try failAfterCleaningStaging(
                SkillInstallerError.unsafeTarget,
                staging: staging,
                skillsDirectory: paths.skillsDirectory
            )
        }

        let backup = try paths.backupURL(id: UUID())
        guard nodeKind(at: backup) == .missing else {
            try failAfterCleaningStaging(
                SkillInstallerError.backupFailed,
                staging: staging,
                skillsDirectory: paths.skillsDirectory
            )
        }

        do {
            try fileOperations.moveItem(paths.target, backup)
        } catch {
            try failAfterCleaningStaging(
                SkillInstallerError.backupFailed,
                staging: staging,
                skillsDirectory: paths.skillsDirectory
            )
        }

        guard isOwnedBackupDirectory(backup, under: paths.skillsDirectory) else {
            try rollbackOrFail(paths: paths, staging: staging, backup: backup)
        }

        do {
            try fileOperations.moveItem(staging, paths.target)
        } catch {
            try rollbackOrFail(paths: paths, staging: staging, backup: backup)
        }

        let warnings: [SkillInstallerWarning]
        if isOwnedBackupDirectory(backup, under: paths.skillsDirectory) {
            do {
                try fileOperations.trashItem(backup)
                warnings = []
            } catch {
                warnings = [.previousVersionBackupRetained]
            }
        } else {
            warnings = [.previousVersionBackupRetained]
        }
        return SkillInstallationResult(target: paths.target, replaced: true, warnings: warnings)
    }

    private func rollbackOrFail(paths: SkillInstallPaths, staging: URL, backup: URL) throws -> Never {
        do {
            try removeOwnedStagingIfPresent(staging, under: paths.skillsDirectory)
        } catch {
            throw SkillInstallerError.cleanupFailed
        }
        guard nodeKind(at: paths.target) == .missing else {
            throw SkillInstallerError.rollbackFailed
        }
        do {
            try fileOperations.moveItem(backup, paths.target)
        } catch {
            throw SkillInstallerError.rollbackFailed
        }
        throw SkillInstallerError.replacementFailed
    }

    private func failAfterCleaningStaging(
        _ error: Error,
        staging: URL,
        skillsDirectory: URL
    ) throws -> Never {
        do {
            try removeOwnedStagingIfPresent(staging, under: skillsDirectory)
        } catch {
            throw SkillInstallerError.cleanupFailed
        }
        if let installerError = error as? SkillInstallerError {
            throw installerError
        }
        throw SkillInstallerError.installFailed
    }

    private func ensureSkillsDirectory(_ skillsDirectory: URL) throws {
        switch nodeKind(at: skillsDirectory) {
        case .missing:
            do {
                try fileOperations.createDirectory(skillsDirectory)
            } catch {
                throw SkillInstallerError.installFailed
            }
        case .directory:
            break
        default:
            throw SkillInstallerError.invalidSkillsDirectory
        }
        guard nodeKind(at: skillsDirectory) == .directory,
              skillsDirectory.resolvingSymlinksInPath().path == skillsDirectory.path else {
            throw SkillInstallerError.invalidSkillsDirectory
        }
    }

    private func validateStaging(_ staging: URL) throws {
        guard nodeKind(at: staging) == .directory,
              staging.resolvingSymlinksInPath().path == staging.path else {
            throw SkillInstallerError.stagingUnsafe
        }
        let skillFile = staging.appendingPathComponent("SKILL.md", isDirectory: false)
        var metadata = stat()
        guard lstat(skillFile.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0 else {
            throw SkillInstallerError.stagingUnsafe
        }
    }

    private func removeOwnedStagingIfPresent(_ staging: URL, under skillsDirectory: URL) throws {
        let candidate = staging.standardizedFileURL
        guard candidate.deletingLastPathComponent().path == skillsDirectory.path,
              candidate.lastPathComponent.hasPrefix(".applebookscli-install-"),
              candidate.path.hasPrefix(skillsDirectory.path + "/") else {
            throw SkillInstallerError.unsafeTarget
        }
        guard nodeKind(at: candidate) != .missing else { return }
        do {
            try fileOperations.removeItem(candidate)
        } catch {
            throw SkillInstallerError.cleanupFailed
        }
    }

    private func isOwnedBackupDirectory(_ backup: URL, under skillsDirectory: URL) -> Bool {
        let candidate = backup.standardizedFileURL
        return candidate.deletingLastPathComponent().path == skillsDirectory.path
            && candidate.lastPathComponent.hasPrefix(".applebookscli-backup-")
            && candidate.path.hasPrefix(skillsDirectory.path + "/")
            && nodeKind(at: candidate) == .directory
            && candidate.resolvingSymlinksInPath().path == candidate.path
    }

    private func validatedSource() throws -> URL {
        let source = sourceURL.standardizedFileURL
        switch nodeKind(at: source) {
        case .directory:
            break
        case .missing:
            throw SkillInstallerError.packagedSourceUnavailable
        default:
            throw SkillInstallerError.packagedSourceUnsafe
        }

        let canonicalSource = source.resolvingSymlinksInPath()
        let skillFile = canonicalSource.appendingPathComponent("SKILL.md", isDirectory: false)
        switch nodeKind(at: skillFile) {
        case .regular:
            guard access(skillFile.path, R_OK) == 0 else {
                throw SkillInstallerError.packagedSkillUnavailable
            }
        case .missing:
            throw SkillInstallerError.packagedSkillUnavailable
        default:
            throw SkillInstallerError.packagedSkillUnsafe
        }
        return canonicalSource
    }

    private func resolvedCodexHome() throws -> URL {
        let raw: String
        if let configured = environment["CODEX_HOME"], configured.isEmpty == false {
            raw = configured
        } else {
            raw = homeDirectory.appendingPathComponent(".codex", isDirectory: true).path
        }
        guard raw.hasPrefix("/") else { throw SkillInstallerError.invalidCodexHome }

        let candidate = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        switch nodeKind(at: candidate) {
        case .directory:
            return candidate.resolvingSymlinksInPath()
        case .symlink:
            let resolved = candidate.resolvingSymlinksInPath()
            guard nodeKind(at: resolved) == .directory else {
                throw SkillInstallerError.invalidCodexHome
            }
            return resolved
        case .missing:
            return candidate.resolvingSymlinksInPath()
        case .regular, .other:
            throw SkillInstallerError.invalidCodexHome
        }
    }

    private func resolvedSkillsDirectory(codexHome: URL) throws -> URL {
        let candidate = codexHome.appendingPathComponent("skills", isDirectory: true).standardizedFileURL
        switch nodeKind(at: candidate) {
        case .directory:
            return candidate.resolvingSymlinksInPath()
        case .symlink:
            let resolved = candidate.resolvingSymlinksInPath()
            guard nodeKind(at: resolved) == .directory else {
                throw SkillInstallerError.invalidSkillsDirectory
            }
            return resolved
        case .missing:
            return candidate
        case .regular, .other:
            throw SkillInstallerError.invalidSkillsDirectory
        }
    }

    private enum NodeKind: Equatable {
        case missing
        case regular
        case directory
        case symlink
        case other
    }

    private func nodeKind(at url: URL) -> NodeKind {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .other
        }
        switch metadata.st_mode & S_IFMT {
        case S_IFREG: return .regular
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }
}
