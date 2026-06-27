import AppKit
import Foundation
import XCTest

final class CodexSkillServiceTests: CodexBarTestCase {
    func testLoadSkillsReadsEnabledAndDisabledSkillMetadata() throws {
        let root = CodexPaths.skillsDirectoryURL
        let alphaDirectory = root.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(
            at: alphaDirectory,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: alpha
        description: |
          Alpha helper skill.
        ---
        """.write(
            to: alphaDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let betaDirectory = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(
            at: betaDirectory,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: beta
        description: Beta helper skill.
        ---
        """.write(
            to: betaDirectory.appendingPathComponent("SKILL.md.disabled"),
            atomically: true,
            encoding: .utf8
        )

        let service = CodexSkillService(skillsDirectoryURL: root)

        let skills = try service.loadSkills()

        XCTAssertEqual(skills.map(\.folderName), ["alpha", "beta"])
        XCTAssertEqual(skills[0].name, "alpha")
        XCTAssertEqual(skills[0].description, "Alpha helper skill.")
        XCTAssertEqual(skills[0].status, .enabled)
        XCTAssertNotNil(skills[0].createdAt)
        XCTAssertNotNil(skills[0].modifiedAt)
        XCTAssertGreaterThan(skills[0].fileSizeBytes ?? 0, 0)
        XCTAssertEqual(skills[1].status, .disabled)
    }

    func testLoadSkillsReadsNestedMultiSkillDirectoriesWithoutParentPlaceholder() throws {
        let root = CodexPaths.skillsDirectoryURL
        let parentDirectory = root.appendingPathComponent("multi-pack", isDirectory: true)
        let firstSkillDirectory = parentDirectory.appendingPathComponent("first", isDirectory: true)
        let secondSkillDirectory = parentDirectory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(
            at: firstSkillDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondSkillDirectory,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: multi-pack:first
        description: First nested skill.
        ---
        """.write(
            to: firstSkillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        name: multi-pack:second
        description: Second nested skill.
        ---
        """.write(
            to: secondSkillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let service = CodexSkillService(skillsDirectoryURL: root)

        let skills = try service.loadSkills()

        XCTAssertEqual(skills.map(\.id).sorted(), ["multi-pack/first", "multi-pack/second"])
        XCTAssertEqual(Set(skills.map(\.displayName)), ["multi-pack:first", "multi-pack:second"])
        XCTAssertFalse(skills.contains { $0.id == "multi-pack" })
    }

    func testLoadSkillsKeepsTopLevelSkillWhenSubSkillsExist() throws {
        let root = CodexPaths.skillsDirectoryURL
        let parentDirectory = root.appendingPathComponent("market-pack", isDirectory: true)
        let nestedSkillDirectory = parentDirectory
            .appendingPathComponent("sub-skills", isDirectory: true)
            .appendingPathComponent("quote", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedSkillDirectory,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: market-pack
        description: Main market skill.
        ---
        """.write(
            to: parentDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        name: quote
        description: Nested quote skill.
        ---
        """.write(
            to: nestedSkillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let service = CodexSkillService(skillsDirectoryURL: root)

        let skills = try service.loadSkills()

        XCTAssertEqual(skills.map(\.id), ["market-pack"])
        XCTAssertEqual(skills.first?.displayName, "market-pack")
    }

    func testSkillSearchMatchesNameDescriptionPathAndStatus() throws {
        let root = CodexPaths.skillsDirectoryURL
        let alphaDirectory = root.appendingPathComponent("alpha-review", isDirectory: true)
        try FileManager.default.createDirectory(
            at: alphaDirectory,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: alpha-review
        description: |
          Helps review Swift settings UI.
        ---
        """.write(
            to: alphaDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let service = CodexSkillService(skillsDirectoryURL: root)
        let skill = try XCTUnwrap(try service.loadSkills().first)

        XCTAssertTrue(skill.matchesSearchQuery("Alpha"))
        XCTAssertTrue(skill.matchesSearchQuery("swift settings"))
        XCTAssertTrue(skill.matchesSearchQuery("alpha-review"))
        XCTAssertTrue(skill.matchesSearchQuery("enabled"))
        XCTAssertFalse(skill.matchesSearchQuery("openrouter"))
    }

    func testCreateSkillWritesStarterSkillFile() throws {
        let service = CodexSkillService(skillsDirectoryURL: CodexPaths.skillsDirectoryURL)

        let skill = try service.createSkill(
            name: "Review Helper",
            description: "Use during code review."
        )

        XCTAssertEqual(skill.folderName, "review-helper")
        XCTAssertEqual(skill.status, .enabled)
        let text = try String(
            contentsOf: CodexPaths.skillsDirectoryURL
                .appendingPathComponent("review-helper", isDirectory: true)
                .appendingPathComponent("SKILL.md")
        )
        XCTAssertTrue(text.contains("name: review-helper"))
        XCTAssertTrue(text.contains("Use during code review."))
    }

    func testSetSkillEnabledRenamesSkillFileWithoutDeletingDirectory() throws {
        let service = CodexSkillService(skillsDirectoryURL: CodexPaths.skillsDirectoryURL)
        let skill = try service.createSkill(name: "toggle-me", description: "Toggle test.")

        try service.setSkill(skill, enabled: false)

        let toggleDirectory = CodexPaths.skillsDirectoryURL.appendingPathComponent("toggle-me", isDirectory: true)
        let enabledURL = toggleDirectory.appendingPathComponent("SKILL.md")
        let disabledURL = toggleDirectory.appendingPathComponent("SKILL.md.disabled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: enabledURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: disabledURL.path))
        XCTAssertEqual(try service.loadSkills().first?.status, .disabled)

        let disabledSkill = try XCTUnwrap(try service.loadSkills().first)
        try service.setSkill(disabledSkill, enabled: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: enabledURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disabledURL.path))
        XCTAssertEqual(try service.loadSkills().first?.status, .enabled)
    }

    func testSetNestedSkillEnabledRenamesNestedSkillFile() throws {
        let root = CodexPaths.skillsDirectoryURL
        let nestedDirectory = root
            .appendingPathComponent("multi-pack", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: multi-pack:nested
        description: Nested toggle test.
        ---
        """.write(
            to: nestedDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let service = CodexSkillService(skillsDirectoryURL: root)
        let skill = try XCTUnwrap(try service.loadSkills().first)

        try service.setSkill(skill, enabled: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedDirectory.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedDirectory.appendingPathComponent("SKILL.md.disabled").path))
    }

    func testDeleteSkillRemovesOnlyImmediateSkillFolder() throws {
        let service = CodexSkillService(skillsDirectoryURL: CodexPaths.skillsDirectoryURL)
        let skill = try service.createSkill(name: "delete-me", description: "Delete test.")

        try service.deleteSkill(skill)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: CodexPaths.skillsDirectoryURL
                    .appendingPathComponent("delete-me", isDirectory: true)
                    .path
            )
        )
        XCTAssertTrue(try service.loadSkills().isEmpty)
    }

    func testRevealSkillsDirectoryCreatesRootAndUsesInjectedOpenURL() throws {
        var openedURLs: [URL] = []
        let service = CodexSkillService(
            skillsDirectoryURL: CodexPaths.skillsDirectoryURL,
            openURL: { openedURLs.append($0) }
        )

        try service.revealSkillsDirectory()

        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.skillsDirectoryURL.path))
        XCTAssertEqual(openedURLs, [CodexPaths.skillsDirectoryURL])
    }

    func testOpenSkillFileUsesSkillFileWhenAvailable() throws {
        var openedURLs: [URL] = []
        let service = CodexSkillService(
            skillsDirectoryURL: CodexPaths.skillsDirectoryURL,
            openURL: { openedURLs.append($0) }
        )
        let skill = try service.createSkill(name: "edit-me", description: "Edit test.")

        service.openSkillFile(skill)

        XCTAssertEqual(
            openedURLs,
            [
                CodexPaths.skillsDirectoryURL
                    .appendingPathComponent("edit-me", isDirectory: true)
                    .appendingPathComponent("SKILL.md"),
            ]
        )
    }

    func testGitRepositoryMetadataAndUpdateUseNearestRepository() throws {
        let root = CodexPaths.skillsDirectoryURL
        let repositoryDirectory = root.appendingPathComponent("repo-pack", isDirectory: true)
        let gitDirectory = repositoryDirectory.appendingPathComponent(".git", isDirectory: true)
        let nestedSkillDirectory = repositoryDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gitDirectory,
            withIntermediateDirectories: true
        )
        try """
        [remote "origin"]
            url = git@github.com:example/repo-pack.git
        """.write(
            to: gitDirectory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: nestedSkillDirectory,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: repo-pack:nested
        description: Nested repo skill.
        ---
        """.write(
            to: nestedSkillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        var pulledRepositories: [URL] = []
        let service = CodexSkillService(
            skillsDirectoryURL: root,
            runGitPull: { repositoryURL in
                pulledRepositories.append(repositoryURL)
                return "Already up to date."
            }
        )
        let skill = try XCTUnwrap(try service.loadSkills().first)

        XCTAssertEqual(skill.gitRepositoryURL, repositoryDirectory)
        XCTAssertEqual(skill.gitRemoteURL, "git@github.com:example/repo-pack.git")
        XCTAssertTrue(skill.canUpdateFromGit)

        let output = try service.updateSkill(skill)

        XCTAssertEqual(output, "Already up to date.")
        XCTAssertEqual(pulledRepositories, [repositoryDirectory])
    }

    func testSourceRepositoryMetadataCanGenerateUpdateCommandWithoutLocalGitRepository() throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root
            .appendingPathComponent("chengfeng-videocut-skills", isDirectory: true)
            .appendingPathComponent("剪口播", isDirectory: true)
        try FileManager.default.createDirectory(
            at: skillDirectory,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: chengfeng-videocut-skills:剪口播
        description: Old local copy.
        source: https://github.com/Agentchengfeng/chengfeng-videocut-skills
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let service = CodexSkillService(skillsDirectoryURL: root)
        let skill = try XCTUnwrap(try service.loadSkills().first)

        XCTAssertNil(skill.gitRepositoryURL)
        XCTAssertEqual(skill.sourceRepositoryURL, "https://github.com/Agentchengfeng/chengfeng-videocut-skills.git")
        XCTAssertTrue(skill.canUpdateFromGit)

        let plan = CodexSkillUpdatePlan(
            skill: skill,
            sourceURL: skill.sourceRepositoryURL,
            sourceRepositorySubpath: skill.sourceRepositorySubpath,
            detail: skill.sourceRepositoryURL ?? ""
        )
        let command = service.updateCommand(for: plan)

        XCTAssertTrue(command.contains("chengfeng-videocut-skills:剪口播"))
        XCTAssertTrue(command.contains("https://github.com/Agentchengfeng/chengfeng-videocut-skills.git"))
        XCTAssertTrue(command.contains("更新目标"))
        XCTAssertTrue(command.contains("更新源"))
        XCTAssertFalse(command.contains("配套文件"))
    }

    func testCheckLocalGitUpdateReportsUpToDateWhenRevisionsMatch() throws {
        let root = CodexPaths.skillsDirectoryURL
        let repositoryDirectory = root.appendingPathComponent("repo-pack", isDirectory: true)
        let gitDirectory = repositoryDirectory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gitDirectory,
            withIntermediateDirectories: true
        )
        try """
        [remote "origin"]
            url = https://github.com/example/repo-pack.git
        """.write(
            to: gitDirectory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        name: repo-pack
        description: Local git skill.
        ---
        """.write(
            to: repositoryDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        var didFetch = false
        let service = CodexSkillService(
            skillsDirectoryURL: root,
            runGitFetch: { repositoryURL in
                didFetch = repositoryURL == repositoryDirectory
                return ""
            },
            runGitRevision: { _, revision in
                revision == "HEAD" ? "abc123\n" : "abc123\n"
            }
        )
        let skill = try XCTUnwrap(try service.loadSkills().first)

        let availability = try service.checkSkillUpdate(skill)

        XCTAssertTrue(didFetch)
        XCTAssertEqual(availability, .upToDate("https://github.com/example/repo-pack.git"))
    }

    func testCheckSourceUpdateReportsUpToDateWhenClonedContentMatches() throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("source-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        let skillFile = """
        ---
        name: source-skill
        description: Same content.
        source: https://github.com/example/source-skill
        ---
        """
        try skillFile.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let service = CodexSkillService(
            skillsDirectoryURL: root,
            runGitClone: { _, destinationURL in
                try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                try skillFile.write(
                    to: destinationURL.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
                return "Cloned"
            }
        )
        let skill = try XCTUnwrap(try service.loadSkills().first)

        let availability = try service.checkSkillUpdate(skill)

        XCTAssertEqual(availability, .upToDate("https://github.com/example/source-skill.git"))
    }

    func testUpdateCommandCanBeCopiedToPasteboard() throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("clipboard-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: clipboard-skill
        description: Clipboard test.
        source: https://github.com/example/clipboard-skill
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let service = CodexSkillService(skillsDirectoryURL: root)
        let skill = try XCTUnwrap(try service.loadSkills().first)
        let plan = CodexSkillUpdatePlan(
            skill: skill,
            sourceURL: skill.sourceRepositoryURL,
            sourceRepositorySubpath: skill.sourceRepositorySubpath,
            detail: skill.sourceRepositoryURL ?? ""
        )
        let command = service.updateCommand(for: plan)
        let pasteboard = LocalPasteboardSpy()

        _ = pasteboard.clearContents()
        _ = pasteboard.setString(command, forType: NSPasteboard.PasteboardType.string)

        XCTAssertEqual(pasteboard.clearContentsCallCount, 1)
        XCTAssertEqual(pasteboard.lastString, command)
        XCTAssertEqual(pasteboard.lastType, NSPasteboard.PasteboardType.string)
    }

    func testManualSourceURLIsCachedAndCanReportAvailableUpdate() throws {
        let root = CodexPaths.skillsDirectoryURL
        let cacheURL = CodexPaths.skillGitSourceCacheURL
        let skillDirectory = root.appendingPathComponent("manual-source", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: manual-source
        description: Old local copy.
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let resolver = CodexSkillGitSourceResolver(cacheURL: cacheURL)
        let service = CodexSkillService(
            skillsDirectoryURL: root,
            gitSourceResolver: resolver,
            runGitClone: { sourceURL, destinationURL in
                XCTAssertEqual(sourceURL, "https://github.com/example/manual-source.git")
                try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                try """
                ---
                name: manual-source
                description: New remote copy.
                ---
                """.write(
                    to: destinationURL.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
                return "Cloned"
            }
        )
        let skill = try XCTUnwrap(try service.loadSkills().first)

        let availability = try service.checkSkillUpdate(
            skill,
            sourceURL: "https://github.com/example/manual-source"
        )

        guard case .updateAvailable(let plan) = availability else {
            return XCTFail("Expected available update")
        }
        XCTAssertEqual(plan.sourceURL, "https://github.com/example/manual-source.git")
        let reloadedSkill = try XCTUnwrap(try service.loadSkills().first)
        XCTAssertEqual(reloadedSkill.sourceRepositoryURL, "https://github.com/example/manual-source.git")
    }

    func testAutomaticCachedSourceMustMatchSkillIdentity() throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("weread-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: weread-skills
        description: 微信读书助手。
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let resolver = CodexSkillGitSourceResolver(cacheURL: CodexPaths.skillGitSourceCacheURL)
        resolver.saveSource(
            "https://github.com/vivy-yi/xiaohongshu-skills.git",
            for: "weread-skills",
            isUserProvided: false
        )
        let service = CodexSkillService(skillsDirectoryURL: root, gitSourceResolver: resolver)

        let skill = try XCTUnwrap(try service.loadSkills().first)

        XCTAssertNil(skill.sourceRepositoryURL)
        XCTAssertTrue(service.skillsNeedingGitSourceDiscovery([skill]).contains(skill))
    }

    func testManualCachedSourceCanOverrideSkillIdentity() throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("weread-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: weread-skills
        description: 微信读书助手。
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let resolver = CodexSkillGitSourceResolver(cacheURL: CodexPaths.skillGitSourceCacheURL)
        resolver.saveSource(
            "https://github.com/vivy-yi/xiaohongshu-skills.git",
            for: "weread-skills",
            isUserProvided: true
        )
        let service = CodexSkillService(skillsDirectoryURL: root, gitSourceResolver: resolver)

        let skill = try XCTUnwrap(try service.loadSkills().first)

        XCTAssertEqual(skill.sourceRepositoryURL, "https://github.com/vivy-yi/xiaohongshu-skills.git")
        XCTAssertFalse(service.skillsNeedingGitSourceDiscovery([skill]).contains(skill))
    }

    func testExplicitSourceWinsOverLocalGitAndCache() throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("priority-skill", isDirectory: true)
        let gitDirectory = skillDirectory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try """
        [remote "origin"]
            url = git@github.com:example/local-priority.git
        """.write(
            to: gitDirectory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        name: priority-skill
        description: Priority test.
        source: https://github.com/example/explicit-priority
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let resolver = CodexSkillGitSourceResolver(cacheURL: CodexPaths.skillGitSourceCacheURL)
        resolver.saveSource(
            "https://github.com/example/cache-priority.git",
            for: "priority-skill",
            isUserProvided: true
        )
        let service = CodexSkillService(skillsDirectoryURL: root, gitSourceResolver: resolver)

        let skill = try XCTUnwrap(try service.loadSkills().first)

        XCTAssertEqual(skill.sourceRepositoryURL, "https://github.com/example/explicit-priority.git")
        XCTAssertEqual(skill.gitRemoteURL, "git@github.com:example/local-priority.git")
    }

    func testLocalGitRemoteWinsOverUserProvidedCacheWhenNoExplicitSourceExists() throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("local-priority", isDirectory: true)
        let gitDirectory = skillDirectory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try """
        [remote "origin"]
            url = https://github.com/example/local-priority.git
        """.write(
            to: gitDirectory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        name: local-priority
        description: Local priority test.
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let resolver = CodexSkillGitSourceResolver(cacheURL: CodexPaths.skillGitSourceCacheURL)
        resolver.saveSource(
            "https://github.com/example/cache-priority.git",
            for: "local-priority",
            isUserProvided: true
        )
        let service = CodexSkillService(skillsDirectoryURL: root, gitSourceResolver: resolver)

        let skill = try XCTUnwrap(try service.loadSkills().first)

        XCTAssertEqual(skill.sourceRepositoryURL, "https://github.com/example/local-priority.git")
    }

    func testVerifiedCacheDoesNotOverrideMismatchedSkillIdentity() throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("weread-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: weread-skills
        description: 微信读书助手。
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let resolver = CodexSkillGitSourceResolver(cacheURL: CodexPaths.skillGitSourceCacheURL)
        resolver.saveSource(
            "https://github.com/vivy-yi/xiaohongshu-skills.git",
            for: "weread-skills",
            isUserProvided: false
        )
        let service = CodexSkillService(skillsDirectoryURL: root, gitSourceResolver: resolver)

        let skill = try XCTUnwrap(try service.loadSkills().first)

        XCTAssertNil(skill.sourceRepositoryURL)
        XCTAssertTrue(service.skillsNeedingGitSourceDiscovery([skill]).contains(skill))
    }

    func testGitSourceDiscoveryRejectsWrongRepositoryForWereadSkill() async throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("weread-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: weread-skills
        description: 微信读书助手。
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let wrongCandidate = CodexSkillGitHubRepositoryCandidate(
            name: "xiaohongshu-skills",
            fullName: "vivy-yi/xiaohongshu-skills",
            description: nil,
            cloneURL: "https://github.com/vivy-yi/xiaohongshu-skills.git",
            htmlURL: "https://github.com/vivy-yi/xiaohongshu-skills",
            defaultBranch: "main"
        )
        let resolver = CodexSkillGitSourceResolver(
            cacheURL: CodexPaths.skillGitSourceCacheURL,
            searchRepositories: { _ in [wrongCandidate] },
            fetchSkillFile: { _, _ in
                """
                ---
                name: xiaohongshu-skills
                description: Xiaohongshu helper.
                ---
                """
            }
        )
        let service = CodexSkillService(skillsDirectoryURL: root, gitSourceResolver: resolver)
        let skill = try XCTUnwrap(try service.loadSkills().first)

        let discoveredSources = await service.discoverGitSources(for: [skill])

        XCTAssertTrue(discoveredSources.isEmpty)
        let reloadedSkill = try XCTUnwrap(try service.loadSkills().first)
        XCTAssertNil(reloadedSkill.sourceRepositoryURL)
    }

    func testGitSourceDiscoveryRejectsRepositoryWithoutSkillFileEvenWhenNameMatches() async throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("ab-testing", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: ab-testing
        description: A/B testing helper.
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let matchingNameCandidate = CodexSkillGitHubRepositoryCandidate(
            name: "AB-Testing",
            fullName: "FrancescoCasalegno/AB-Testing",
            description: nil,
            cloneURL: "https://github.com/FrancescoCasalegno/AB-Testing.git",
            htmlURL: "https://github.com/FrancescoCasalegno/AB-Testing",
            defaultBranch: "main"
        )
        let resolver = CodexSkillGitSourceResolver(
            cacheURL: CodexPaths.skillGitSourceCacheURL,
            searchRepositories: { _ in [matchingNameCandidate] },
            fetchSkillFile: { _, _ in nil }
        )
        let service = CodexSkillService(skillsDirectoryURL: root, gitSourceResolver: resolver)
        let skill = try XCTUnwrap(try service.loadSkills().first)

        let discoveredSources = await service.discoverGitSources(for: [skill])

        XCTAssertTrue(discoveredSources.isEmpty)
        let reloadedSkill = try XCTUnwrap(try service.loadSkills().first)
        XCTAssertNil(reloadedSkill.sourceRepositoryURL)
    }

    func testGitSourceDiscoveryRejectsWrongSemanticMatchEvenWhenNamesOverlap() async throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("weread-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: weread-skills
        description: 微信读书助手。
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let wrongCandidate = CodexSkillGitHubRepositoryCandidate(
            name: "xiaohongshu-skills",
            fullName: "vivy-yi/xiaohongshu-skills",
            description: "Xiaohongshu helper for creators.",
            cloneURL: "https://github.com/vivy-yi/xiaohongshu-skills.git",
            htmlURL: "https://github.com/vivy-yi/xiaohongshu-skills",
            defaultBranch: "main"
        )
        let resolver = CodexSkillGitSourceResolver(
            cacheURL: CodexPaths.skillGitSourceCacheURL,
            searchRepositories: { _ in [wrongCandidate] },
            fetchSkillFile: { _, path in
                guard path == "SKILL.md" else { return nil }
                return """
                ---
                name: xiaohongshu-skills
                description: Xiaohongshu helper.
                ---
                """
            }
        )
        let service = CodexSkillService(skillsDirectoryURL: root, gitSourceResolver: resolver)
        let skill = try XCTUnwrap(try service.loadSkills().first)

        let discoveredSources = await service.discoverGitSources(for: [skill])

        XCTAssertTrue(discoveredSources.isEmpty)
        let reloadedSkill = try XCTUnwrap(try service.loadSkills().first)
        XCTAssertNil(reloadedSkill.sourceRepositoryURL)
    }

    func testGitSourceDiscoveryKeepsSubpathWhenRepositoryHasNestedSkillDirectory() async throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root
            .appendingPathComponent("multi-pack", isDirectory: true)
            .appendingPathComponent("nested-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: multi-pack:nested-skill
        description: Nested skill.
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let nestedCandidate = CodexSkillGitHubRepositoryCandidate(
            name: "multi-pack",
            fullName: "example/multi-pack",
            description: "Multi skill pack.",
            cloneURL: "https://github.com/example/multi-pack.git",
            htmlURL: "https://github.com/example/multi-pack",
            defaultBranch: "main"
        )
        let resolver = CodexSkillGitSourceResolver(
            cacheURL: CodexPaths.skillGitSourceCacheURL,
            searchRepositories: { _ in [nestedCandidate] },
            fetchSkillFile: { _, path in
                guard path == "skills/nested-skill/SKILL.md" else { return nil }
                return """
                ---
                name: multi-pack:nested-skill
                description: Nested skill.
                ---
                """
            }
        )
        let service = CodexSkillService(skillsDirectoryURL: root, gitSourceResolver: resolver)
        let skill = try XCTUnwrap(try service.loadSkills().first)

        let discoveredSources = await service.discoverGitSources(for: [skill])

        XCTAssertEqual(
            discoveredSources,
            ["multi-pack/nested-skill": "https://github.com/example/multi-pack.git"]
        )
        let reloadedSkill = try XCTUnwrap(try service.loadSkills().first)
        XCTAssertEqual(reloadedSkill.sourceRepositoryURL, "https://github.com/example/multi-pack.git")
        XCTAssertEqual(reloadedSkill.sourceRepositorySubpath, "skills/nested-skill")

        let updateService = CodexSkillService(
            skillsDirectoryURL: root,
            gitSourceResolver: resolver,
            runGitClone: { _, destinationURL in
                let replacementDirectory = destinationURL
                    .appendingPathComponent("skills", isDirectory: true)
                    .appendingPathComponent("nested-skill", isDirectory: true)
                try FileManager.default.createDirectory(at: replacementDirectory, withIntermediateDirectories: true)
                try """
                ---
                name: multi-pack:nested-skill
                description: Nested skill.
                ---
                """.write(
                    to: replacementDirectory.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
                return "Cloned"
            }
        )
        let updatedSkill = try XCTUnwrap(try updateService.loadSkills().first)
        let availability: CodexSkillUpdateAvailability = try updateService.checkSkillUpdate(updatedSkill)
        XCTAssertEqual(availability, .upToDate("https://github.com/example/multi-pack.git / skills/nested-skill"))
    }

    func testUpdateCommandHandlesExplicitRootSourceAndSubpath() throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("gsap-core", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: gsap-core
        description: GSAP core skill.
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let service = CodexSkillService(skillsDirectoryURL: root)
        let skill = try XCTUnwrap(try service.loadSkills().first)
        let plan = CodexSkillUpdatePlan(
            skill: skill,
            sourceURL: "https://github.com/greensock/gsap-skills",
            sourceRepositorySubpath: "skills/gsap-core",
            detail: "https://github.com/greensock/gsap-skills / skills/gsap-core"
        )

        let command = service.updateCommand(for: plan)

        XCTAssertTrue(command.contains("gsap-core"))
        XCTAssertTrue(command.contains("https://github.com/greensock/gsap-skills"))
        XCTAssertFalse(command.contains("本地目录"))
        XCTAssertFalse(command.contains("仓库子路径"))
        XCTAssertFalse(command.contains("不要只改 SKILL.md"))
    }

    func testSuggestedMatchesDoNotAutoWriteSourceCache() async throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("short", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: short
        description: Generic short skill.
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let suggestedCandidate = CodexSkillGitHubRepositoryCandidate(
            name: "short-tools",
            fullName: "example/short-tools",
            description: "A generic tooling repo.",
            cloneURL: "https://github.com/example/short-tools.git",
            htmlURL: "https://github.com/example/short-tools",
            defaultBranch: "main"
        )
        let resolver = CodexSkillGitSourceResolver(
            cacheURL: CodexPaths.skillGitSourceCacheURL,
            searchRepositories: { _ in [suggestedCandidate] },
            fetchSkillFile: { _, path in
                guard path == "SKILL.md" else { return nil }
                return """
                ---
                name: short-tools
                description: A generic tooling repo.
                ---
                """
            }
        )
        let service = CodexSkillService(skillsDirectoryURL: root, gitSourceResolver: resolver)
        let skill = try XCTUnwrap(try service.loadSkills().first)

        let discoveredSources = await service.discoverGitSources(for: [skill])

        XCTAssertTrue(discoveredSources.isEmpty)
        let reloadedSkill = try XCTUnwrap(try service.loadSkills().first)
        XCTAssertNil(reloadedSkill.sourceRepositoryURL)
    }

    func testBareGitHubURLInSkillHeaderCanBeUsedAsUpdateSource() throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root
            .appendingPathComponent("chengfeng-videocut-skills", isDirectory: true)
            .appendingPathComponent("口播成片", isDirectory: true)
        try FileManager.default.createDirectory(
            at: skillDirectory,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: chengfeng-videocut-skills:口播成片
        description: Video cut skill.
        ---
        https://github.com/Agentchengfeng/chengfeng-videocut-skills
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let service = CodexSkillService(skillsDirectoryURL: root)
        let skill = try XCTUnwrap(try service.loadSkills().first)

        XCTAssertEqual(skill.sourceRepositoryURL, "https://github.com/Agentchengfeng/chengfeng-videocut-skills.git")
        XCTAssertTrue(skill.canUpdateFromGit)
    }

    func testConvertedFromLineCanBeUsedAsUpdateSource() throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("xiaohongshu-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: xiaohongshu-skills
        description: Xiaohongshu helper.
        ---

        ## Source

        Converted from: https://github.com/vivy-yi/xiaohongshu-skills
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let service = CodexSkillService(skillsDirectoryURL: root)

        let skill = try XCTUnwrap(try service.loadSkills().first)

        XCTAssertEqual(skill.sourceRepositoryURL, "https://github.com/vivy-yi/xiaohongshu-skills.git")
    }

    func testGitSourceResolverDiscoversMatchingGitHubRepositoryAndCachesIt() async throws {
        let root = CodexPaths.skillsDirectoryURL
        let skillDirectory = root.appendingPathComponent("xiaohongshu-skills", isDirectory: true)
        try FileManager.default.createDirectory(
            at: skillDirectory,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: xiaohongshu-skills
        description: Xiaohongshu helper.
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        var searchedTerms: [String] = []
        var fetchedPaths: [String] = []
        let candidate = CodexSkillGitHubRepositoryCandidate(
            name: "xiaohongshu-skills",
            fullName: "vivy-yi/xiaohongshu-skills",
            description: nil,
            cloneURL: "https://github.com/vivy-yi/xiaohongshu-skills.git",
            htmlURL: "https://github.com/vivy-yi/xiaohongshu-skills",
            defaultBranch: "main"
        )
        let resolver = CodexSkillGitSourceResolver(
            cacheURL: CodexPaths.skillGitSourceCacheURL,
            searchRepositories: { term in
                searchedTerms.append(term)
                return [candidate]
            },
            fetchSkillFile: { _, path in
                fetchedPaths.append(path)
                guard path == "SKILL.md" else { return nil }
                return """
                ---
                name: xiaohongshu-skills
                description: Remote skill.
                ---
                """
            }
        )
        let service = CodexSkillService(
            skillsDirectoryURL: root,
            gitSourceResolver: resolver
        )
        let skill = try XCTUnwrap(try service.loadSkills().first)

        XCTAssertFalse(skill.canUpdateFromGit)

        let discoveredSources = await service.discoverGitSources(for: [skill])

        XCTAssertEqual(searchedTerms.first, "xiaohongshu-skills")
        XCTAssertEqual(fetchedPaths.first, "SKILL.md")
        XCTAssertEqual(
            discoveredSources,
            ["xiaohongshu-skills": "https://github.com/vivy-yi/xiaohongshu-skills.git"]
        )
        let reloadedSkill = try XCTUnwrap(try service.loadSkills().first)
        XCTAssertEqual(reloadedSkill.sourceRepositoryURL, "https://github.com/vivy-yi/xiaohongshu-skills.git")
        XCTAssertTrue(reloadedSkill.canUpdateFromGit)
    }

    func testSkillWithoutGitRepositoryCannotUpdate() throws {
        let service = CodexSkillService(skillsDirectoryURL: CodexPaths.skillsDirectoryURL)
        let skill = try service.createSkill(name: "local-only", description: "Local only.")

        XCTAssertFalse(skill.canUpdateFromGit)
        XCTAssertThrowsError(try service.updateSkill(skill)) { error in
            XCTAssertEqual(error as? CodexSkillServiceError, .gitRepositoryMissing)
        }
    }
}

private final class LocalPasteboardSpy: StringPasteboardWriting {
    private(set) var clearContentsCallCount = 0
    private(set) var lastString: String?
    private(set) var lastType: NSPasteboard.PasteboardType?

    func clearContents() -> Int {
        self.clearContentsCallCount += 1
        return self.clearContentsCallCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        self.lastString = string
        self.lastType = dataType
        return true
    }
}
