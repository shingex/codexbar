import Foundation

struct CodexSkillGitHubRepositoryCandidate: Codable, Equatable, Sendable {
    var name: String
    var fullName: String
    var cloneURL: String
    var htmlURL: String
    var defaultBranch: String
    var description: String?

    init(
        name: String,
        fullName: String,
        description: String? = nil,
        cloneURL: String,
        htmlURL: String,
        defaultBranch: String
    ) {
        self.name = name
        self.fullName = fullName
        self.description = description
        self.cloneURL = cloneURL
        self.htmlURL = htmlURL
        self.defaultBranch = defaultBranch
    }
}

struct CodexSkillGitSourceReference: Codable, Equatable, Sendable {
    var sourceURL: String
    var repositorySubpath: String?

    var displayDetail: String {
        guard let repositorySubpath, repositorySubpath.isEmpty == false else {
            return self.sourceURL
        }
        return "\(self.sourceURL) / \(repositorySubpath)"
    }
}

enum CodexSkillGitSourceEvidenceClass: String, Codable, Equatable, Hashable, Sendable {
    case repository
    case content
    case directory
}

enum CodexSkillGitSourceMatchOutcome: String, Codable, Equatable, Sendable {
    case match
    case suggested
    case none
}

struct CodexSkillGitSourceMatch: Codable, Equatable, Sendable {
    var sourceURL: String
    var repositorySubpath: String?
    var confidence: Double
    var evidenceClasses: Set<CodexSkillGitSourceEvidenceClass>
    var evidence: [String]
    var outcome: CodexSkillGitSourceMatchOutcome
}

struct CodexSkillGitSourceResolver {
    private struct CacheFile: Codable {
        var records: [String: CacheRecord]
    }

    private struct CacheRecord: Codable {
        var sourceURL: String?
        var repositorySubpath: String?
        var updatedAt: Date
        var isUserProvided: Bool?
        var verifiedSkillFile: Bool?
    }

    private struct GitHubSearchResponse: Decodable {
        var items: [GitHubRepositoryItem]
    }

    private struct GitHubRepositoryItem: Decodable {
        var name: String
        var fullName: String
        var description: String?
        var cloneURL: String
        var htmlURL: String
        var defaultBranch: String

        enum CodingKeys: String, CodingKey {
            case name
            case fullName = "full_name"
            case description
            case cloneURL = "clone_url"
            case htmlURL = "html_url"
            case defaultBranch = "default_branch"
        }
    }

    var cacheURL: URL
    var fileManager: FileManager
    var urlSession: URLSession
    var now: () -> Date
    var freshnessInterval: TimeInterval
    var searchRepositories: ((String) async throws -> [CodexSkillGitHubRepositoryCandidate])?
    var fetchSkillFile: ((CodexSkillGitHubRepositoryCandidate, String) async throws -> String?)?

    init(
        cacheURL: URL = CodexPaths.skillGitSourceCacheURL,
        fileManager: FileManager = .default,
        urlSession: URLSession = URLSession(configuration: .ephemeral),
        now: @escaping () -> Date = Date.init,
        freshnessInterval: TimeInterval = 24 * 60 * 60,
        searchRepositories: ((String) async throws -> [CodexSkillGitHubRepositoryCandidate])? = nil,
        fetchSkillFile: ((CodexSkillGitHubRepositoryCandidate, String) async throws -> String?)? = nil
    ) {
        self.cacheURL = cacheURL
        self.fileManager = fileManager
        self.urlSession = urlSession
        self.now = now
        self.freshnessInterval = freshnessInterval
        self.searchRepositories = searchRepositories
        self.fetchSkillFile = fetchSkillFile
    }

    func cachedSource(for skillID: String) -> String? {
        guard let record = self.loadCache().records[skillID],
              self.isFresh(record) else {
            return nil
        }
        return record.sourceURL
    }

    func cachedSourceReference(for skillID: String) -> CodexSkillGitSourceReference? {
        guard let record = self.loadCache().records[skillID],
              self.isFresh(record),
              let sourceURL = record.sourceURL else {
            return nil
        }
        return CodexSkillGitSourceReference(
            sourceURL: sourceURL,
            repositorySubpath: record.repositorySubpath
        )
    }

    func userProvidedCachedSource(for skillID: String) -> String? {
        guard let record = self.loadCache().records[skillID],
              self.isFresh(record),
              record.isUserProvided == true else {
            return nil
        }
        return record.sourceURL
    }

    func userProvidedCachedSourceReference(for skillID: String) -> CodexSkillGitSourceReference? {
        guard let record = self.loadCache().records[skillID],
              self.isFresh(record),
              record.isUserProvided == true,
              let sourceURL = record.sourceURL else {
            return nil
        }
        return CodexSkillGitSourceReference(
            sourceURL: sourceURL,
            repositorySubpath: record.repositorySubpath
        )
    }

    func cachedSource(
        for skillID: String,
        skillName: String,
        folderName: String,
        relativePath: String
    ) -> String? {
        guard let record = self.loadCache().records[skillID],
              self.isFresh(record),
              let sourceURL = record.sourceURL else {
            return nil
        }
        if record.isUserProvided == true ||
            record.verifiedSkillFile == true &&
            self.sourceURL(sourceURL, matchesSkillName: skillName, folderName: folderName, relativePath: relativePath) {
            return sourceURL
        }
        return nil
    }

    func cachedSourceReference(
        for skillID: String,
        skillName: String,
        folderName: String,
        relativePath: String
    ) -> CodexSkillGitSourceReference? {
        guard let record = self.loadCache().records[skillID],
              self.isFresh(record),
              let sourceURL = record.sourceURL else {
            return nil
        }
        if record.isUserProvided == true ||
            record.verifiedSkillFile == true &&
            self.sourceURL(sourceURL, matchesSkillName: skillName, folderName: folderName, relativePath: relativePath) {
            return CodexSkillGitSourceReference(
                sourceURL: sourceURL,
                repositorySubpath: record.repositorySubpath
            )
        }
        return nil
    }

    func verifiedCachedSource(
        for skill: CodexSkillSummary
    ) -> String? {
        guard let record = self.loadCache().records[skill.id],
              self.isFresh(record),
              record.verifiedSkillFile == true,
              let sourceURL = record.sourceURL,
              self.sourceURL(sourceURL, matchesSkillName: skill.displayName, folderName: skill.folderName, relativePath: skill.relativePath) else {
            return nil
        }
        return sourceURL
    }

    func verifiedCachedSourceReference(
        for skill: CodexSkillSummary
    ) -> CodexSkillGitSourceReference? {
        guard let record = self.loadCache().records[skill.id],
              self.isFresh(record),
              record.verifiedSkillFile == true,
              let sourceURL = record.sourceURL,
              self.sourceURL(sourceURL, matchesSkillName: skill.displayName, folderName: skill.folderName, relativePath: skill.relativePath) else {
            return nil
        }
        return CodexSkillGitSourceReference(
            sourceURL: sourceURL,
            repositorySubpath: record.repositorySubpath
        )
    }

    func saveSource(
        _ sourceURL: String?,
        repositorySubpath: String? = nil,
        for skillID: String,
        isUserProvided: Bool = true
    ) {
        self.saveCacheRecord(
            skillID: skillID,
            sourceURL: sourceURL,
            repositorySubpath: repositorySubpath,
            isUserProvided: isUserProvided
        )
    }

    func needsDiscovery(for skill: CodexSkillSummary) -> Bool {
        guard skill.updateSourceURL == nil else { return false }
        if let record = self.loadCache().records[skill.id],
           self.isFresh(record) {
            guard let sourceURL = record.sourceURL else { return false }
            return record.isUserProvided != true &&
                (record.verifiedSkillFile != true || self.sourceURL(sourceURL, matchesSkillName: skill.displayName, folderName: skill.folderName, relativePath: skill.relativePath) == false)
        }
        return true
    }

    func discoverSources(for skills: [CodexSkillSummary]) async -> [String: String] {
        var discovered: [String: String] = [:]
        for skill in skills where self.needsDiscovery(for: skill) {
            if Task.isCancelled { break }
            if let reference = await self.discoverSourceReference(for: skill) {
                discovered[skill.id] = reference.sourceURL
                self.saveCacheRecord(
                    skillID: skill.id,
                    sourceURL: reference.sourceURL,
                    repositorySubpath: reference.repositorySubpath,
                    verifiedSkillFile: true
                )
            } else {
                self.saveCacheRecord(skillID: skill.id, sourceURL: nil)
            }
        }
        return discovered
    }

    func discoverSource(for skill: CodexSkillSummary) async -> String? {
        return await self.discoverSourceReference(for: skill).map(\.sourceURL)
    }

    func discoverSourceReference(for skill: CodexSkillSummary) async -> CodexSkillGitSourceReference? {
        guard let match = await self.analyzeSource(for: skill),
              match.outcome == .match else {
            return nil
        }
        return CodexSkillGitSourceReference(
            sourceURL: match.sourceURL,
            repositorySubpath: match.repositorySubpath
        )
    }

    func analyzeSource(for skill: CodexSkillSummary) async -> CodexSkillGitSourceMatch? {
        var analyses: [CodexSkillGitSourceMatch] = []
        var seenCloneURLs: Set<String> = []

        for term in self.searchTerms(for: skill) {
            do {
                let candidates = try await self.searchGitHubRepositories(term: term)
                for candidate in candidates where seenCloneURLs.insert(candidate.cloneURL).inserted {
                    if let analysis = await self.analyze(candidate, skill: skill) {
                        analyses.append(analysis)
                    }
                }
            } catch {
                continue
            }
        }

        let rankedAnalyses = analyses.sorted {
            if $0.confidence == $1.confidence {
                if $0.evidenceClasses.count == $1.evidenceClasses.count {
                    return $0.sourceURL < $1.sourceURL
                }
                return $0.evidenceClasses.count > $1.evidenceClasses.count
            }
            return $0.confidence > $1.confidence
        }

        guard let best = rankedAnalyses.first else { return nil }
        guard best.outcome != .none else { return nil }
        guard best.confidence >= 0.65 else { return nil }
        guard best.outcome != .match || best.evidenceClasses.contains(.repository) else {
            return nil
        }
        if self.requiresStrictEvidence(for: skill),
           best.evidenceClasses.count < 3 {
            return nil
        }
        if let second = rankedAnalyses.dropFirst().first,
           abs(best.confidence - second.confidence) < 0.05,
           best.sourceURL != second.sourceURL {
            return nil
        }
        return best
    }

    func sourceURL(_ sourceURL: String, matches skill: CodexSkillSummary) -> Bool {
        self.sourceURL(
            sourceURL,
            matchesSkillName: skill.displayName,
            folderName: skill.folderName,
            relativePath: skill.relativePath
        )
    }

    func sourceRepositoryURL(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        for line in lines.prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = trimmed.value(after: "Converted from:")
                ?? trimmed.value(after: "converted from:")
                ?? trimmed.value(after: "canonical:")
                ?? trimmed.value(after: "source:")
                ?? trimmed.value(after: "repository:")
                ?? trimmed.value(after: "repo:") {
                return self.normalizedGitRepositoryURL(from: value)
            }
            if trimmed.contains("github.com/"),
               let sourceURL = self.normalizedGitRepositoryURL(from: trimmed) {
                return sourceURL
            }
        }
        return nil
    }

    func normalizedGitRepositoryURL(from value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>，。,.);]"))
        guard trimmed.isEmpty == false else { return nil }

        if trimmed.hasPrefix("git@") {
            return trimmed
        }

        guard let githubRange = trimmed.range(of: "github.com/") else {
            return nil
        }

        let tail = String(trimmed[githubRange.upperBound...])
        let components = tail
            .split(whereSeparator: { $0 == "/" || $0.isWhitespace })
            .map(String.init)
        guard components.count >= 2 else { return nil }

        var repoName = components[1]
        if repoName.hasSuffix(".git") {
            repoName.removeLast(4)
        }
        return "https://github.com/\(components[0])/\(repoName).git"
    }

    private func analyze(
        _ candidate: CodexSkillGitHubRepositoryCandidate,
        skill: CodexSkillSummary
    ) async -> CodexSkillGitSourceMatch? {
        let paths = self.skillFileCandidatePaths(for: skill)
        let repositorySignals = self.repositorySignals(candidate, skill: skill)
        var bestMatch: CodexSkillGitSourceMatch?
        for path in paths {
            do {
                if let text = try await self.fetchGitHubSkillFile(candidate: candidate, path: path),
                   let contentSignals = self.contentSignals(text, skill: skill) {
                    let directorySignals = self.directorySignals(candidate: candidate, path: path, skill: skill)
                    let evidenceClasses = Set(repositorySignals.classes + contentSignals.classes + directorySignals.classes)
                    guard evidenceClasses.count >= 2 else { continue }
                    let confidence = min(0.98, repositorySignals.score + contentSignals.score + directorySignals.score)
                    let outcome: CodexSkillGitSourceMatchOutcome = confidence >= 0.85 ? .match : .suggested
                    let evidence: [String] = (repositorySignals.evidence + contentSignals.evidence + directorySignals.evidence)
                        .reduce(into: []) { partial, item in
                            if partial.contains(where: { $0 == item }) == false {
                                partial.append(item)
                            }
                        }
                    let match = CodexSkillGitSourceMatch(
                        sourceURL: candidate.cloneURL,
                        repositorySubpath: path == "SKILL.md" ? nil : String(path.dropLast("/SKILL.md".count)),
                        confidence: confidence,
                        evidenceClasses: evidenceClasses,
                        evidence: evidence,
                        outcome: outcome
                    )
                    if let current = bestMatch {
                        if match.confidence > current.confidence {
                            bestMatch = match
                        }
                    } else {
                        bestMatch = match
                    }
                }
            } catch {
                continue
            }
        }
        return bestMatch
    }

    private func repositorySignals(
        _ candidate: CodexSkillGitHubRepositoryCandidate,
        skill: CodexSkillSummary
    ) -> (score: Double, classes: [CodexSkillGitSourceEvidenceClass], evidence: [String]) {
        var score: Double = 0
        var classes: [CodexSkillGitSourceEvidenceClass] = []
        var evidence: [String] = []

        let candidateIdentities = self.repositoryIdentities(candidate)
        let skillIdentities = self.skillIdentities(skill).map { Self.normalizedIdentity($0) }
        if candidateIdentities.contains(where: { candidateIdentity in skillIdentities.contains(candidateIdentity) }) {
            score += 0.45
            classes.append(.repository)
            evidence.append("repo-name:\(candidate.fullName)")
        } else if let repoDescription = candidate.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                  repoDescription.isEmpty == false,
                  self.repositoryDescriptionMatchesSkill(repoDescription, skill: skill) {
            score += 0.2
            classes.append(.repository)
            evidence.append("repo-description:\(repoDescription.prefix(80))")
        }

        return (score, classes, evidence)
    }

    private func contentSignals(
        _ text: String,
        skill: CodexSkillSummary
    ) -> (score: Double, classes: [CodexSkillGitSourceEvidenceClass], evidence: [String])? {
        let names = self.skillIdentities(skill, exactOnly: true).map { Self.normalizedIdentity($0) }
        let normalizedText = Self.normalizedIdentity(text)
        var evidence: [String] = []
        var score: Double = 0
        var classes: [CodexSkillGitSourceEvidenceClass] = []

        if let name = self.skillFileName(in: text) {
            let normalizedName = Self.normalizedIdentity(name)
            guard names.contains(normalizedName) else { return nil }
            score += 0.48
            classes.append(.content)
            evidence.append("skill-name:\(name)")
        }

        let description = self.skillFileDescription(in: text)
        if let description, self.contentLooksRelevant(description, skill: skill) {
            score += 0.22
            classes.append(.content)
            evidence.append("skill-description:\(description.prefix(80))")
        }

        if names.contains(where: { identity in
            guard identity.count >= 8 else { return false }
            return normalizedText.contains(identity)
        }) {
            score += 0.2
            classes.append(.content)
            evidence.append("content-match")
        }

        guard score > 0 else { return nil }
        return (min(score, 0.7), classes, evidence)
    }

    private func directorySignals(
        candidate: CodexSkillGitHubRepositoryCandidate,
        path: String,
        skill: CodexSkillSummary
    ) -> (score: Double, classes: [CodexSkillGitSourceEvidenceClass], evidence: [String]) {
        var score: Double = 0
        var classes: [CodexSkillGitSourceEvidenceClass] = []
        var evidence: [String] = []
        let pathIdentity = Self.normalizedIdentity((path as NSString).deletingLastPathComponent)
        let repoIdentity = Self.normalizedIdentity(candidate.name)
        let skillIdentity = Self.normalizedIdentity(skill.folderName)

        if path != "SKILL.md" {
            score += 0.22
            classes.append(.directory)
            evidence.append("subpath:\(path)")
        }
        if pathIdentity == repoIdentity || pathIdentity == skillIdentity {
            score += 0.18
            classes.append(.directory)
            evidence.append("directory-name:\(pathIdentity)")
        }
        return (score, classes, evidence)
    }

    private func skillFileName(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines).prefix(50) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = trimmed.value(after: "name:") {
                return Self.unquoted(value)
            }
        }
        return nil
    }

    private func skillFileDescription(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines).prefix(50) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = trimmed.value(after: "description:") {
                return Self.unquoted(value)
            }
        }
        return nil
    }

    private func repositoryIdentities(_ candidate: CodexSkillGitHubRepositoryCandidate) -> [String] {
        let repoName = candidate.fullName.split(separator: "/").last.map(String.init) ?? candidate.name
        let raw = [candidate.name, repoName]
        return raw.map { Self.normalizedIdentity($0) }.filter { $0.count >= 3 }
    }

    private func repositoryDescriptionMatchesSkill(_ description: String, skill: CodexSkillSummary) -> Bool {
        let normalizedDescription = Self.normalizedIdentity(description)
        let candidates = self.skillIdentities(skill, exactOnly: true).map { Self.normalizedIdentity($0) }
        return candidates.contains(where: { identity in
            guard identity.count >= 6 else { return false }
            return normalizedDescription.contains(identity)
        })
    }

    private func contentLooksRelevant(_ text: String, skill: CodexSkillSummary) -> Bool {
        let normalizedText = Self.normalizedIdentity(text)
        let identities = self.skillIdentities(skill, exactOnly: true).map { Self.normalizedIdentity($0) }
        return identities.contains { identity in
            guard identity.count >= 6 else { return false }
            return normalizedText.contains(identity)
        }
    }

    private func skillFileCandidatePaths(for skill: CodexSkillSummary) -> [String] {
        let relativeComponents = skill.relativePath.split(separator: "/").map(String.init)
        let relativePathWithoutTopLevel = relativeComponents.dropFirst().joined(separator: "/")
        return [
            "SKILL.md",
            "\(skill.folderName)/SKILL.md",
            relativePathWithoutTopLevel.isEmpty ? nil : "\(relativePathWithoutTopLevel)/SKILL.md",
            "skills/\(skill.folderName)/SKILL.md",
        ]
        .compactMap { $0 }
        .reduce(into: []) { partial, path in
            if partial.contains(path) == false {
                partial.append(path)
            }
        }
    }

    private func skillIdentities(_ skill: CodexSkillSummary, exactOnly: Bool = false) -> [String] {
        let topLevel = skill.relativePath.split(separator: "/").first.map(String.init)
        let nameBeforeColon = skill.displayName.split(separator: ":").first.map(String.init)
        let rawIdentities: [String?] = [
            skill.displayName,
            nameBeforeColon,
            skill.folderName,
            topLevel,
        ]
        let compactIdentities: [String] = rawIdentities.compactMap { $0 }
        var identities = compactIdentities.reduce(into: [String]()) { partial, identity in
            if identity.isEmpty == false, partial.contains(identity) == false {
                partial.append(identity)
            }
        }
        if exactOnly == false {
            identities.append(contentsOf: identities.map { $0.replacingOccurrences(of: "-skills", with: "") })
        }
        return identities.reduce(into: []) { partial, identity in
            if identity.isEmpty == false, partial.contains(identity) == false {
                partial.append(identity)
            }
        }
    }

    private func searchTerms(for skill: CodexSkillSummary) -> [String] {
        self.skillIdentities(skill)
            .filter { $0.count >= 3 }
    }

    private func requiresStrictEvidence(for skill: CodexSkillSummary) -> Bool {
        let genericTerms: Set<String> = [
            "ads",
            "app",
            "docs",
            "skill",
            "skills",
            "tool",
            "tools",
            "video",
        ]
        let identities = self.skillIdentities(skill, exactOnly: true).map { Self.normalizedIdentity($0) }
        return identities.contains { identity in
            identity.count <= 4 || genericTerms.contains(identity)
        }
    }

    private func searchGitHubRepositories(term: String) async throws -> [CodexSkillGitHubRepositoryCandidate] {
        if let searchRepositories {
            return try await searchRepositories(term)
        }

        var components = URLComponents(string: "https://api.github.com/search/repositories")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "\(term) in:name"),
            URLQueryItem(name: "per_page", value: "8"),
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("codexbar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await self.urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return []
        }
        let decoded = try JSONDecoder().decode(GitHubSearchResponse.self, from: data)
        return decoded.items.map {
            CodexSkillGitHubRepositoryCandidate(
                name: $0.name,
                fullName: $0.fullName,
                description: $0.description,
                cloneURL: $0.cloneURL,
                htmlURL: $0.htmlURL,
                defaultBranch: $0.defaultBranch
            )
        }
    }

    private func fetchGitHubSkillFile(
        candidate: CodexSkillGitHubRepositoryCandidate,
        path: String
    ) async throws -> String? {
        if let fetchSkillFile {
            return try await fetchSkillFile(candidate, path)
        }

        let encodedPath = path
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let urlString = "https://raw.githubusercontent.com/\(candidate.fullName)/\(candidate.defaultBranch)/\(encodedPath)"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("codexbar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await self.urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func loadCache() -> CacheFile {
        guard let data = try? Data(contentsOf: self.cacheURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            return CacheFile(records: [:])
        }
        return cache
    }

    private func saveCacheRecord(
        skillID: String,
        sourceURL: String?,
        repositorySubpath: String? = nil,
        isUserProvided: Bool = false,
        verifiedSkillFile: Bool = false
    ) {
        var cache = self.loadCache()
        cache.records[skillID] = CacheRecord(
            sourceURL: sourceURL,
            repositorySubpath: repositorySubpath,
            updatedAt: self.now(),
            isUserProvided: isUserProvided,
            verifiedSkillFile: verifiedSkillFile
        )
        do {
            try self.fileManager.createDirectory(
                at: self.cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cache)
            try data.write(to: self.cacheURL, options: .atomic)
        } catch {
            NSLog("codexbar skill git source cache write failed: %@", error.localizedDescription)
        }
    }

    private func isFresh(_ record: CacheRecord) -> Bool {
        self.now().timeIntervalSince(record.updatedAt) < self.freshnessInterval
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func sourceURL(
        _ sourceURL: String,
        matchesSkillName skillName: String,
        folderName: String,
        relativePath: String
    ) -> Bool {
        guard let repositoryName = self.repositoryName(from: sourceURL) else {
            return false
        }
        let topLevel = relativePath.split(separator: "/").first.map(String.init)
        let nameBeforeColon = skillName.split(separator: ":").first.map(String.init)
        let identities = [
            skillName,
            nameBeforeColon,
            folderName,
            topLevel,
        ]
        .compactMap { $0 }
        .map { Self.normalizedIdentity($0) }
        return identities.contains(Self.normalizedIdentity(repositoryName))
    }

    private func repositoryName(from sourceURL: String) -> String? {
        let trimmed = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail: String
        if let githubRange = trimmed.range(of: "github.com/") {
            tail = String(trimmed[githubRange.upperBound...])
        } else if trimmed.hasPrefix("git@github.com:"),
                  let colonIndex = trimmed.firstIndex(of: ":") {
            tail = String(trimmed[trimmed.index(after: colonIndex)...])
        } else {
            return nil
        }
        let components = tail
            .split(whereSeparator: { $0 == "/" || $0.isWhitespace })
            .map(String.init)
        guard components.count >= 2 else { return nil }
        var repositoryName = components[1]
        if repositoryName.hasSuffix(".git") {
            repositoryName.removeLast(4)
        }
        return repositoryName
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
}

private extension String {
    func value(after prefix: String) -> String? {
        guard self.hasPrefix(prefix) else { return nil }
        return String(self.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
