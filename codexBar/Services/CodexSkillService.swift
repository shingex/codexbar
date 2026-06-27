import AppKit
import Foundation

enum CodexSkillStatus: String, Equatable, Sendable {
    case enabled
    case disabled
    case invalid
}

struct CodexSkillSummary: Identifiable, Equatable, Sendable {
    let id: String
    let folderName: String
    let relativePath: String
    let name: String
    let description: String
    let directoryURL: URL
    let skillFileURL: URL?
    let gitRepositoryURL: URL?
    let gitRemoteURL: String?
    let sourceRepositoryURL: String?
    let sourceRepositorySubpath: String?
    let status: CodexSkillStatus
    let issues: [String]
    let createdAt: Date?
    let modifiedAt: Date?
    let fileSizeBytes: Int64?

    var displayName: String {
        self.name.isEmpty ? self.folderName : self.name
    }

    var canUpdateFromGit: Bool {
        self.updateSourceURL != nil
    }

    var updateSourceURL: String? {
        if let gitRemoteURL, gitRemoteURL.isEmpty == false {
            return gitRemoteURL
        }
        if let sourceRepositoryURL, sourceRepositoryURL.isEmpty == false {
            return sourceRepositoryURL
        }
        return nil
    }

    func matchesSearchQuery(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return true }

        return [
            self.displayName,
            self.folderName,
            self.relativePath,
            self.description,
            self.directoryURL.path,
            self.status.rawValue,
        ].contains { value in
            value.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }
}

enum CodexSkillServiceError: LocalizedError, Equatable {
    case invalidName
    case skillAlreadyExists(String)
    case skillFileMissing(String)
    case unsafeSkillPath
    case gitRepositoryMissing
    case invalidGitSourceURL

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return L.skillsErrorInvalidName
        case .skillAlreadyExists(let name):
            return L.skillsErrorAlreadyExists(name)
        case .skillFileMissing(let name):
            return L.skillsErrorFileMissing(name)
        case .unsafeSkillPath:
            return L.skillsErrorUnsafePath
        case .gitRepositoryMissing:
            return L.skillsErrorGitRepositoryMissing
        case .invalidGitSourceURL:
            return L.skillsErrorInvalidGitSourceURL
        }
    }
}

struct CodexSkillUpdatePlan: Identifiable, Equatable, Sendable {
    let skill: CodexSkillSummary
    let sourceURL: String?
    let sourceRepositorySubpath: String?
    let detail: String

    var id: String {
        "\(self.skill.id)|\(self.sourceURL ?? "local-git")|\(self.sourceRepositorySubpath ?? "root")"
    }
}

enum CodexSkillUpdateAvailability: Equatable, Sendable {
    case upToDate(String)
    case updateAvailable(CodexSkillUpdatePlan)
}

struct CodexSkillService {
    var skillsDirectoryURL: URL
    var fileManager: FileManager
    var openURL: (URL) -> Void
    var gitSourceResolver: CodexSkillGitSourceResolver
    var runGitPull: (URL) throws -> String
    var runGitFetch: (URL) throws -> String
    var runGitRevision: (URL, String) throws -> String
    var runGitClone: (String, URL) throws -> String

    init(
        skillsDirectoryURL: URL = CodexPaths.skillsDirectoryURL,
        fileManager: FileManager = .default,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        gitSourceResolver: CodexSkillGitSourceResolver = CodexSkillGitSourceResolver(),
        runGitPull: @escaping (URL) throws -> String = Self.runGitPull(in:),
        runGitFetch: @escaping (URL) throws -> String = Self.runGitFetch(in:),
        runGitRevision: @escaping (URL, String) throws -> String = Self.runGitRevision(in:revision:),
        runGitClone: @escaping (String, URL) throws -> String = Self.runGitClone(sourceURL:destinationURL:)
    ) {
        self.skillsDirectoryURL = skillsDirectoryURL
        self.fileManager = fileManager
        self.openURL = openURL
        self.gitSourceResolver = gitSourceResolver
        self.runGitPull = runGitPull
        self.runGitFetch = runGitFetch
        self.runGitRevision = runGitRevision
        self.runGitClone = runGitClone
    }

    func loadSkills() throws -> [CodexSkillSummary] {
        try self.fileManager.createDirectory(at: self.skillsDirectoryURL, withIntermediateDirectories: true)
        let topLevelURLs = try self.fileManager.contentsOfDirectory(
            at: self.skillsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let visibleSkillDirectories = try topLevelURLs.flatMap { url -> [URL] in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return []
            }
            return try self.visibleSkillDirectories(in: url, includeInvalidIfEmpty: true)
        }

        return visibleSkillDirectories.map { self.summary(for: $0) }
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func createSkill(name: String, description: String) throws -> CodexSkillSummary {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = Self.slug(for: trimmedName)
        guard folderName.isEmpty == false else {
            throw CodexSkillServiceError.invalidName
        }

        try self.fileManager.createDirectory(at: self.skillsDirectoryURL, withIntermediateDirectories: true)
        let directoryURL = self.skillsDirectoryURL.appendingPathComponent(folderName, isDirectory: true)
        guard self.fileManager.fileExists(atPath: directoryURL.path) == false else {
            throw CodexSkillServiceError.skillAlreadyExists(folderName)
        }

        try self.fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let skillText = Self.skillTemplate(
            name: folderName,
            description: trimmedDescription.isEmpty ? L.skillsDefaultDescription : trimmedDescription
        )
        try skillText.write(
            to: directoryURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return self.summary(for: directoryURL)
    }

    func setSkill(_ skill: CodexSkillSummary, enabled: Bool) throws {
        try self.validateSkillDirectory(skill.directoryURL)
        let enabledURL = skill.directoryURL.appendingPathComponent("SKILL.md")
        let disabledURL = skill.directoryURL.appendingPathComponent("SKILL.md.disabled")

        if enabled {
            guard self.fileManager.fileExists(atPath: disabledURL.path) else {
                if self.fileManager.fileExists(atPath: enabledURL.path) { return }
                throw CodexSkillServiceError.skillFileMissing(skill.folderName)
            }
            if self.fileManager.fileExists(atPath: enabledURL.path) {
                try self.fileManager.removeItem(at: disabledURL)
            } else {
                try self.fileManager.moveItem(at: disabledURL, to: enabledURL)
            }
        } else {
            guard self.fileManager.fileExists(atPath: enabledURL.path) else {
                if self.fileManager.fileExists(atPath: disabledURL.path) { return }
                throw CodexSkillServiceError.skillFileMissing(skill.folderName)
            }
            if self.fileManager.fileExists(atPath: disabledURL.path) {
                try self.fileManager.removeItem(at: enabledURL)
            } else {
                try self.fileManager.moveItem(at: enabledURL, to: disabledURL)
            }
        }
    }

    func deleteSkill(_ skill: CodexSkillSummary) throws {
        try self.validateSkillDirectory(skill.directoryURL)
        try self.fileManager.removeItem(at: skill.directoryURL)
    }

    @discardableResult
    func updateSkill(_ skill: CodexSkillSummary, sourceURL: String? = nil) throws -> String {
        try self.validateSkillDirectory(skill.directoryURL)
        if self.shouldUseLocalGitUpdate(for: skill, sourceURL: sourceURL) {
            guard let gitRepositoryURL = skill.gitRepositoryURL else {
                throw CodexSkillServiceError.gitRepositoryMissing
            }
            return try self.runGitPull(gitRepositoryURL)
        }
        let resolvedSourceReference = try self.resolvedUpdateSourceReference(for: skill, sourceURL: sourceURL)
        guard let resolvedSourceReference else {
            throw CodexSkillServiceError.gitRepositoryMissing
        }
        return try self.updateSkillFromSource(skill, sourceReference: resolvedSourceReference)
    }

    func checkSkillUpdate(
        _ skill: CodexSkillSummary,
        sourceURL: String? = nil
    ) throws -> CodexSkillUpdateAvailability {
        try self.validateSkillDirectory(skill.directoryURL)
        if self.shouldUseLocalGitUpdate(for: skill, sourceURL: sourceURL) {
            guard let gitRepositoryURL = skill.gitRepositoryURL else {
                throw CodexSkillServiceError.gitRepositoryMissing
            }
            return try self.checkLocalGitUpdate(skill, repositoryURL: gitRepositoryURL)
        }
        let resolvedSourceReference = try self.resolvedUpdateSourceReference(for: skill, sourceURL: sourceURL)
        guard let resolvedSourceReference else {
            throw CodexSkillServiceError.gitRepositoryMissing
        }
        return try self.checkSourceUpdate(skill, sourceReference: resolvedSourceReference)
    }

    func skillsNeedingGitSourceDiscovery(_ skills: [CodexSkillSummary]) -> [CodexSkillSummary] {
        skills.filter { self.gitSourceResolver.needsDiscovery(for: $0) }
    }

    func discoverGitSources(for skills: [CodexSkillSummary]) async -> [String: String] {
        await self.gitSourceResolver.discoverSources(for: skills)
    }

    func revealSkillsDirectory() throws {
        try self.fileManager.createDirectory(at: self.skillsDirectoryURL, withIntermediateDirectories: true)
        self.openURL(self.skillsDirectoryURL)
    }

    func revealSkill(_ skill: CodexSkillSummary) {
        self.openURL(skill.directoryURL)
    }

    func openSkillFile(_ skill: CodexSkillSummary) {
        self.openURL(skill.skillFileURL ?? skill.directoryURL)
    }

    private func summary(for directoryURL: URL) -> CodexSkillSummary {
        let enabledURL = directoryURL.appendingPathComponent("SKILL.md")
        let disabledURL = directoryURL.appendingPathComponent("SKILL.md.disabled")
        let enabledExists = self.fileManager.fileExists(atPath: enabledURL.path)
        let disabledExists = self.fileManager.fileExists(atPath: disabledURL.path)
        let skillFileURL = enabledExists ? enabledURL : (disabledExists ? disabledURL : nil)
        var issues: [String] = []
        var metadata = SkillMetadata(name: "", description: "", sourceRepositoryURL: nil)

        if let skillFileURL {
            do {
                let text = try String(contentsOf: skillFileURL, encoding: .utf8)
                metadata = Self.parseMetadata(from: text)
                if metadata.name.isEmpty {
                    issues.append(L.skillsIssueMissingName)
                }
                if metadata.description.isEmpty {
                    issues.append(L.skillsIssueMissingDescription)
                }
            } catch {
                issues.append(error.localizedDescription)
            }
        } else {
            issues.append(L.skillsIssueMissingSkillFile)
        }

        let status: CodexSkillStatus
        if enabledExists {
            status = issues.isEmpty ? .enabled : .invalid
        } else if disabledExists {
            status = .disabled
        } else {
            status = .invalid
        }

        let directoryValues = try? directoryURL.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        let fileValues = try? skillFileURL?.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let fileSize = fileValues?.fileSize.map { Int64($0) }
        let gitRepositoryURL = self.gitRepositoryURL(containing: directoryURL)
        let relativePath = self.relativePath(for: directoryURL)
        let previewSkill = CodexSkillSummary(
            id: relativePath,
            folderName: directoryURL.lastPathComponent,
            relativePath: relativePath,
            name: metadata.name,
            description: metadata.description,
            directoryURL: directoryURL,
            skillFileURL: skillFileURL,
            gitRepositoryURL: gitRepositoryURL,
            gitRemoteURL: gitRepositoryURL.flatMap { self.gitRemoteURL(in: $0) },
            sourceRepositoryURL: nil,
            sourceRepositorySubpath: nil,
            status: status,
            issues: issues,
            createdAt: directoryValues?.creationDate,
            modifiedAt: fileValues?.contentModificationDate ?? directoryValues?.contentModificationDate,
            fileSizeBytes: fileSize
        )
        let gitRemoteReference: CodexSkillGitSourceReference? = {
            guard let gitRemoteURL = previewSkill.gitRemoteURL,
                  let normalizedGitRemoteURL = self.gitSourceResolver.normalizedGitRepositoryURL(from: gitRemoteURL) else {
                return nil
            }
            let cachedReference = self.gitSourceResolver.cachedSourceReference(
                for: relativePath,
                skillName: metadata.name,
                folderName: directoryURL.lastPathComponent,
                relativePath: relativePath
            )
            return CodexSkillGitSourceReference(
                sourceURL: normalizedGitRemoteURL,
                repositorySubpath: cachedReference?.sourceURL == normalizedGitRemoteURL ? cachedReference?.repositorySubpath : nil
            )
        }()
        let sourceReference: CodexSkillGitSourceReference? = {
            if let sourceRepositoryURL = metadata.sourceRepositoryURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               sourceRepositoryURL.isEmpty == false,
               let normalizedSourceURL = self.gitSourceResolver.normalizedGitRepositoryURL(from: sourceRepositoryURL) {
                let cachedReference = self.gitSourceResolver.cachedSourceReference(
                    for: relativePath,
                    skillName: metadata.name,
                    folderName: directoryURL.lastPathComponent,
                    relativePath: relativePath
                )
                if cachedReference?.sourceURL == normalizedSourceURL {
                    return CodexSkillGitSourceReference(
                        sourceURL: normalizedSourceURL,
                        repositorySubpath: cachedReference?.repositorySubpath
                    )
                }
                return CodexSkillGitSourceReference(
                    sourceURL: normalizedSourceURL,
                    repositorySubpath: nil
                )
            }
            if let gitRemoteReference {
                return gitRemoteReference
            }
            if let userProvidedReference = self.gitSourceResolver.userProvidedCachedSourceReference(for: relativePath) {
                return userProvidedReference
            }
            if let verifiedReference = self.gitSourceResolver.verifiedCachedSourceReference(for: previewSkill) {
                return verifiedReference
            }
            return nil
        }()
        return CodexSkillSummary(
            id: relativePath,
            folderName: directoryURL.lastPathComponent,
            relativePath: relativePath,
            name: metadata.name,
            description: metadata.description,
            directoryURL: directoryURL,
            skillFileURL: skillFileURL,
            gitRepositoryURL: gitRepositoryURL,
            gitRemoteURL: gitRepositoryURL.flatMap { self.gitRemoteURL(in: $0) },
            sourceRepositoryURL: sourceReference?.sourceURL,
            sourceRepositorySubpath: sourceReference?.repositorySubpath,
            status: status,
            issues: issues,
            createdAt: directoryValues?.creationDate,
            modifiedAt: fileValues?.contentModificationDate ?? directoryValues?.contentModificationDate,
            fileSizeBytes: fileSize
        )
    }

    private func validateSkillDirectory(_ url: URL) throws {
        let rootPath = self.skillsDirectoryURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") || path == rootPath else {
            throw CodexSkillServiceError.unsafeSkillPath
        }

        let relativePath = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard relativePath.isEmpty == false,
              relativePath
                .split(separator: "/")
                .contains(where: { $0.hasPrefix(".") }) == false else {
            throw CodexSkillServiceError.unsafeSkillPath
        }
    }

    private func visibleSkillDirectories(in directoryURL: URL, includeInvalidIfEmpty: Bool) throws -> [URL] {
        if self.hasSkillFile(in: directoryURL) {
            return [directoryURL]
        }

        let childSkillDirectories = try self.immediateChildDirectories(in: directoryURL)
            .flatMap { childURL in
                try self.visibleSkillDirectories(in: childURL, includeInvalidIfEmpty: false)
            }
        if childSkillDirectories.isEmpty, includeInvalidIfEmpty {
            return [directoryURL]
        }
        return childSkillDirectories
    }

    private func immediateChildDirectories(in rootURL: URL) throws -> [URL] {
        try self.fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func hasSkillFile(in directoryURL: URL) -> Bool {
        self.fileManager.fileExists(atPath: directoryURL.appendingPathComponent("SKILL.md").path) ||
            self.fileManager.fileExists(atPath: directoryURL.appendingPathComponent("SKILL.md.disabled").path)
    }

    private func relativePath(for directoryURL: URL) -> String {
        let rootPath = self.skillsDirectoryURL.standardizedFileURL.path
        let path = directoryURL.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            return directoryURL.lastPathComponent
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func gitRepositoryURL(containing directoryURL: URL) -> URL? {
        let rootPath = self.skillsDirectoryURL.standardizedFileURL.path
        var candidate = directoryURL.standardizedFileURL

        while candidate.path.hasPrefix(rootPath) {
            if self.fileManager.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return candidate
            }
            if candidate.path == rootPath {
                break
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private func gitRemoteURL(in repositoryURL: URL) -> String? {
        let configURL = repositoryURL.appendingPathComponent(".git", isDirectory: true).appendingPathComponent("config")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        var isOriginSection = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                isOriginSection = trimmed == "[remote \"origin\"]"
                continue
            }
            if isOriginSection,
               let value = trimmed.value(after: "url =") {
                return value
            }
        }
        return nil
    }

    private func resolvedUpdateSourceReference(
        for skill: CodexSkillSummary,
        sourceURL: String?
    ) throws -> CodexSkillGitSourceReference? {
        let trimmedSourceURL = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedSourceURL.isEmpty == false {
            guard let normalizedSourceURL = self.gitSourceResolver.normalizedGitRepositoryURL(from: trimmedSourceURL) else {
                throw CodexSkillServiceError.invalidGitSourceURL
            }
            if let gitRemoteURL = skill.gitRemoteURL,
               let normalizedGitRemoteURL = self.gitSourceResolver.normalizedGitRepositoryURL(from: gitRemoteURL),
               normalizedSourceURL == normalizedGitRemoteURL {
                return nil
            }
            let cachedReference =
                self.gitSourceResolver.cachedSourceReference(
                    for: skill.id,
                    skillName: skill.displayName,
                    folderName: skill.folderName,
                    relativePath: skill.relativePath
                )
                ?? self.gitSourceResolver.userProvidedCachedSourceReference(for: skill.id)
                ?? self.gitSourceResolver.verifiedCachedSourceReference(for: skill)
            let repositorySubpath = cachedReference?.sourceURL == normalizedSourceURL ? cachedReference?.repositorySubpath : nil
            self.gitSourceResolver.saveSource(
                normalizedSourceURL,
                repositorySubpath: repositorySubpath,
                for: skill.id
            )
            return CodexSkillGitSourceReference(
                sourceURL: normalizedSourceURL,
                repositorySubpath: repositorySubpath
            )
        }
        if let sourceRepositoryURL = skill.sourceRepositoryURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           sourceRepositoryURL.isEmpty == false {
            guard let normalizedSourceURL = self.gitSourceResolver.normalizedGitRepositoryURL(from: sourceRepositoryURL) else {
                throw CodexSkillServiceError.invalidGitSourceURL
            }
            return CodexSkillGitSourceReference(
                sourceURL: normalizedSourceURL,
                repositorySubpath: skill.sourceRepositorySubpath
            )
        }
        if let cachedReference = self.gitSourceResolver.cachedSourceReference(
            for: skill.id,
            skillName: skill.displayName,
            folderName: skill.folderName,
            relativePath: skill.relativePath
        ) {
            return cachedReference
        }
        if let verifiedReference = self.gitSourceResolver.verifiedCachedSourceReference(for: skill) {
            return verifiedReference
        }
        return nil
    }

    private func shouldUseLocalGitUpdate(
        for skill: CodexSkillSummary,
        sourceURL: String?
    ) -> Bool {
        guard skill.gitRepositoryURL != nil,
              let gitRemoteURL = skill.gitRemoteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              gitRemoteURL.isEmpty == false else {
            return false
        }

        let trimmedSourceURL = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedSourceURL.isEmpty {
            return true
        }

        guard let normalizedSourceURL = self.gitSourceResolver.normalizedGitRepositoryURL(from: trimmedSourceURL),
              let normalizedGitRemoteURL = self.gitSourceResolver.normalizedGitRepositoryURL(from: gitRemoteURL) else {
            return false
        }
        return normalizedSourceURL == normalizedGitRemoteURL
    }

    private func checkLocalGitUpdate(
        _ skill: CodexSkillSummary,
        repositoryURL: URL
    ) throws -> CodexSkillUpdateAvailability {
        _ = try self.runGitFetch(repositoryURL)
        let localRevision = try self.runGitRevision(repositoryURL, "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamRevision = try self.runGitRevision(repositoryURL, "@{u}")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if localRevision == upstreamRevision {
            return .upToDate(skill.gitRemoteURL ?? repositoryURL.path)
        }
        return .updateAvailable(
            CodexSkillUpdatePlan(
                skill: skill,
                sourceURL: nil,
                sourceRepositorySubpath: nil,
                detail: skill.gitRemoteURL ?? repositoryURL.path
            )
        )
    }

    private func checkSourceUpdate(
        _ skill: CodexSkillSummary,
        sourceReference: CodexSkillGitSourceReference
    ) throws -> CodexSkillUpdateAvailability {
        let tempRootURL = self.fileManager.temporaryDirectory
            .appendingPathComponent("codexbar-skill-check-\(UUID().uuidString)", isDirectory: true)
        let cloneURL = tempRootURL.appendingPathComponent("repo", isDirectory: true)
        try self.fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
        defer { try? self.fileManager.removeItem(at: tempRootURL) }

        _ = try self.runGitClone(sourceReference.sourceURL, cloneURL)
        let replacementURL = try self.replacementDirectory(
            for: skill,
            in: cloneURL,
            sourceRepositorySubpath: sourceReference.repositorySubpath
        )
        let localSnapshot = try self.directoryContentSnapshot(for: skill.directoryURL)
        let remoteSnapshot = try self.directoryContentSnapshot(for: replacementURL)
        if localSnapshot == remoteSnapshot {
            return .upToDate(sourceReference.displayDetail)
        }
        return .updateAvailable(
            CodexSkillUpdatePlan(
                skill: skill,
                sourceURL: sourceReference.sourceURL,
                sourceRepositorySubpath: sourceReference.repositorySubpath,
                detail: sourceReference.displayDetail
            )
        )
    }

    private func directoryContentSnapshot(for directoryURL: URL) throws -> [String: Data] {
        guard let enumerator = self.fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var snapshot: [String: Data] = [:]
        let rootPath = directoryURL.standardizedFileURL.path
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true, fileURL.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            var relativePath = String(fileURL.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            if relativePath == "SKILL.md.disabled" {
                relativePath = "SKILL.md"
            } else if relativePath.hasSuffix("/SKILL.md.disabled") {
                relativePath.removeLast(".disabled".count)
            }
            snapshot[relativePath] = try Data(contentsOf: fileURL)
        }
        return snapshot
    }

    private func updateSkillFromSource(
        _ skill: CodexSkillSummary,
        sourceReference: CodexSkillGitSourceReference
    ) throws -> String {
        let tempRootURL = self.fileManager.temporaryDirectory
            .appendingPathComponent("codexbar-skill-update-\(UUID().uuidString)", isDirectory: true)
        let cloneURL = tempRootURL.appendingPathComponent("repo", isDirectory: true)
        let backupURL = tempRootURL.appendingPathComponent("backup", isDirectory: true)
        try self.fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
        defer { try? self.fileManager.removeItem(at: tempRootURL) }

        let output = try self.runGitClone(sourceReference.sourceURL, cloneURL)
        let replacementURL = try self.replacementDirectory(
            for: skill,
            in: cloneURL,
            sourceRepositorySubpath: sourceReference.repositorySubpath
        )
        let wasDisabled = skill.status == .disabled

        try self.fileManager.moveItem(at: skill.directoryURL, to: backupURL)
        do {
            try self.fileManager.copyItem(at: replacementURL, to: skill.directoryURL)
            if wasDisabled {
                try self.disableUpdatedSkillFile(in: skill.directoryURL)
            }
        } catch {
            if self.fileManager.fileExists(atPath: skill.directoryURL.path) == false {
                try? self.fileManager.moveItem(at: backupURL, to: skill.directoryURL)
            }
            throw error
        }
        return output
    }

    private func replacementDirectory(
        for skill: CodexSkillSummary,
        in cloneURL: URL,
        sourceRepositorySubpath: String? = nil
    ) throws -> URL {
        let relativeComponents = skill.relativePath.split(separator: "/").map(String.init)
        let relativePathWithoutTopLevel = relativeComponents.dropFirst().joined(separator: "/")
        let normalizedSourceSubpath = sourceRepositorySubpath?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let localCandidates: [String] = [
            relativePathWithoutTopLevel.isEmpty ? nil : relativePathWithoutTopLevel,
            skill.folderName,
            skill.relativePath,
        ].compactMap { $0 }
        var candidates: [URL] = []
        if let normalizedSourceSubpath, normalizedSourceSubpath.isEmpty == false {
            candidates.append(cloneURL.appendingPathComponent(normalizedSourceSubpath, isDirectory: true))
        }
        for candidate in localCandidates {
            candidates.append(cloneURL.appendingPathComponent(candidate, isDirectory: true))
            candidates.append(
                cloneURL
                    .appendingPathComponent("skills", isDirectory: true)
                    .appendingPathComponent(candidate, isDirectory: true)
            )
            candidates.append(
                cloneURL
                    .appendingPathComponent("modules", isDirectory: true)
                    .appendingPathComponent(candidate, isDirectory: true)
            )
            candidates.append(
                cloneURL
                    .appendingPathComponent("sub-skills", isDirectory: true)
                    .appendingPathComponent(candidate, isDirectory: true)
            )
        }
        candidates.append(cloneURL)

        if let replacementURL = candidates.first(where: { self.hasSkillFile(in: $0) }) {
            return replacementURL
        }
        throw CodexSkillServiceError.skillFileMissing(skill.folderName)
    }

    private func disableUpdatedSkillFile(in directoryURL: URL) throws {
        let enabledURL = directoryURL.appendingPathComponent("SKILL.md")
        let disabledURL = directoryURL.appendingPathComponent("SKILL.md.disabled")
        guard self.fileManager.fileExists(atPath: enabledURL.path) else { return }
        if self.fileManager.fileExists(atPath: disabledURL.path) {
            try self.fileManager.removeItem(at: disabledURL)
        }
        try self.fileManager.moveItem(at: enabledURL, to: disabledURL)
    }

    private struct SkillMetadata {
        var name: String
        var description: String
        var sourceRepositoryURL: String?
    }

    private static func parseMetadata(from text: String) -> SkillMetadata {
        var metadata = SkillMetadata(name: "", description: "", sourceRepositoryURL: nil)
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            metadata.sourceRepositoryURL = CodexSkillGitSourceResolver().sourceRepositoryURL(in: text)
            return metadata
        }

        var index = 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                break
            }

            if let value = trimmed.value(after: "name:") {
                metadata.name = Self.unquoted(value)
            } else if let value = trimmed.value(after: "description:") {
                if value == "|" || value == ">" {
                    var body: [String] = []
                    index += 1
                    while index < lines.count {
                        let nextLine = lines[index]
                        let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                        if nextTrimmed == "---" || Self.isTopLevelYAMLKey(nextLine) {
                            index -= 1
                            break
                        }
                        body.append(nextLine.trimmingCharacters(in: .whitespaces))
                        index += 1
                    }
                    metadata.description = body
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    metadata.description = Self.unquoted(value)
                }
            } else if let value = trimmed.value(after: "source:")
                ?? trimmed.value(after: "repository:")
                ?? trimmed.value(after: "repo:") {
                metadata.sourceRepositoryURL = CodexSkillGitSourceResolver()
                    .normalizedGitRepositoryURL(from: Self.unquoted(value))
            }
            index += 1
        }
        if metadata.sourceRepositoryURL == nil {
            metadata.sourceRepositoryURL = CodexSkillGitSourceResolver().sourceRepositoryURL(in: text)
        }
        return metadata
    }

    private static func isTopLevelYAMLKey(_ line: String) -> Bool {
        line.first?.isWhitespace == false && line.contains(":")
    }

    private static func unquoted(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count >= 2,
           let first = result.first,
           let last = result.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            result.removeFirst()
            result.removeLast()
        }
        return result
    }

    private static func slug(for value: String) -> String {
        value
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "-" || character == "_" {
                    return character
                }
                return "-"
            }
            .reduce(into: "") { partial, character in
                if character == "-", partial.last == "-" {
                    return
                }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    private static func skillTemplate(name: String, description: String) -> String {
        """
        ---
        name: \(name)
        description: |
          \(description)
        ---

        # \(name)

        ## When to use

        Use this skill when the user asks for work related to \(name).

        ## Instructions

        - Read the relevant project files before changing behavior.
        - Keep changes scoped to the user's request.
        - Verify the result with the narrowest meaningful command.
        """
    }

    nonisolated private static func runGitPull(in repositoryURL: URL) throws -> String {
        try self.runGit(arguments: ["-C", repositoryURL.path, "pull", "--ff-only"])
    }

    nonisolated private static func runGitFetch(in repositoryURL: URL) throws -> String {
        try self.runGit(arguments: ["-C", repositoryURL.path, "fetch"])
    }

    nonisolated private static func runGitRevision(in repositoryURL: URL, revision: String) throws -> String {
        try self.runGit(arguments: ["-C", repositoryURL.path, "rev-parse", revision])
    }

    nonisolated private static func runGitClone(sourceURL: String, destinationURL: URL) throws -> String {
        try self.runGit(arguments: ["clone", "--depth", "1", sourceURL, destinationURL.path])
    }

    nonisolated private static func runGit(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "CodexSkillService.Git",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: errorOutput.isEmpty ? output : errorOutput,
                ]
            )
        }
        return output.isEmpty ? errorOutput : output
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        guard self.hasPrefix(prefix) else { return nil }
        return String(self.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
