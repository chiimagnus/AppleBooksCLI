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

    init(
        sourceURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.sourceURL = sourceURL
        self.environment = environment
        self.homeDirectory = homeDirectory
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
