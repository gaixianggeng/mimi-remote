import Foundation
import XCTest
@testable import MimiRemote

@MainActor
final class WorkspaceAppearanceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WorkspaceAppearanceStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testBuiltInCharacterPoolKeepsProductOrder() {
        XCTAssertEqual(
            WorkspaceAppearanceStore.builtInCharacters.map(\.id),
            [
                "sun-wukong", "tang-sanzang", "zhu-bajie", "sha-wujing", "white-dragon-horse",
                "guanyin", "tathagata", "jade-emperor", "taishang-laojun", "nezha",
                "erlang-shen", "bull-demon-king", "princess-iron-fan", "red-boy", "white-bone-demon",
                "spider-demon", "yellow-robed-demon", "golden-horn-king", "silver-horn-king",
                "queen-womens-kingdom"
            ]
        )
    }

    func testBuiltInCharacterNamesHaveEnglishAndChineseLocalizations() {
        let allCharacters = WorkspaceIconStyle.allCases
            .filter(\.usesCharacters)
            .flatMap { WorkspaceAppearanceStore.characters(for: $0) }

        for character in allCharacters {
            let englishName = L10n.text(character.nameKey, language: .english)
            let chineseName = L10n.text(character.nameKey, language: .simplifiedChinese)

            XCTAssertNotEqual(englishName, character.nameKey, "缺少英文角色名：\(character.id)")
            XCTAssertNotEqual(chineseName, character.nameKey, "缺少中文角色名：\(character.id)")
            XCTAssertNotEqual(englishName, chineseName, "中英文角色名不应共用未翻译文案：\(character.id)")
        }
    }

    func testCuratedIconStylesKeepExpectedCountsAndUniqueAssets() {
        let tenIconStyles: [WorkspaceIconStyle] = [
            .threeKingdoms,
            .abstractGeometry,
            .redChamber,
            .greekMythology,
            .sherlockHolmes,
            .aliceWonderland,
            .onePiece,
            .naruto,
            .worldArt
        ]
        let curatedIcons = (tenIconStyles + [.solarSystem]).flatMap {
            WorkspaceAppearanceStore.characters(for: $0)
        }

        for style in tenIconStyles {
            XCTAssertEqual(
                WorkspaceAppearanceStore.characters(for: style).count,
                10,
                "\(style.rawValue) 应提供 10 个图标"
            )
        }
        XCTAssertEqual(WorkspaceAppearanceStore.characters(for: .solarSystem).count, 9)
        XCTAssertEqual(Set(curatedIcons.map(\.id)).count, 99)
        XCTAssertEqual(Set(curatedIcons.map(\.assetName)).count, 99)
        XCTAssertTrue(WorkspaceAppearanceStore.characters(for: .emoji).isEmpty)
    }

    func testRetiredStylesKeepOnlyPersistenceIdentifiersAndMigrate() {
        XCTAssertEqual(WorkspaceIconStyle.waterMargin.availableStyle, .abstractGeometry)
        XCTAssertEqual(WorkspaceIconStyle.digimon.availableStyle, .solarSystem)
        XCTAssertEqual(WorkspaceIconStyle.classicAlbums.availableStyle, .worldArt)
        XCTAssertFalse(WorkspaceIconStyle.visibleStyles.contains(.waterMargin))
        XCTAssertFalse(WorkspaceIconStyle.visibleStyles.contains(.digimon))
        XCTAssertFalse(WorkspaceIconStyle.visibleStyles.contains(.classicAlbums))
        XCTAssertNil(WorkspaceIconStyle.waterMargin.representativeAssetName)
        XCTAssertNil(WorkspaceIconStyle.digimon.representativeAssetName)
        XCTAssertNil(WorkspaceIconStyle.classicAlbums.representativeAssetName)
        XCTAssertTrue(WorkspaceAppearanceStore.characters(for: .waterMargin).isEmpty)
        XCTAssertTrue(WorkspaceAppearanceStore.characters(for: .digimon).isEmpty)
        XCTAssertTrue(WorkspaceAppearanceStore.characters(for: .classicAlbums).isEmpty)
    }

    func testOriginalThemePoolsKeepProductOrderAndRepresentatives() {
        let abstractIcons = WorkspaceAppearanceStore.characters(for: .abstractGeometry)
        let solarIcons = WorkspaceAppearanceStore.characters(for: .solarSystem)

        XCTAssertEqual(
            abstractIcons.map(\.id),
            [
                "abstract-orbit", "abstract-prism", "abstract-waves", "abstract-grid",
                "abstract-bloom", "abstract-rings", "abstract-blocks", "abstract-spiral",
                "abstract-crossing", "abstract-mosaic"
            ]
        )
        XCTAssertEqual(
            solarIcons.map(\.id),
            [
                "solar-sun", "solar-mercury", "solar-venus", "solar-earth", "solar-mars",
                "solar-jupiter", "solar-saturn", "solar-uranus", "solar-neptune"
            ]
        )
        XCTAssertEqual(
            WorkspaceIconStyle.abstractGeometry.representativeAssetName,
            "WorkspaceAbstractOrbit"
        )
        XCTAssertEqual(
            WorkspaceIconStyle.solarSystem.representativeAssetName,
            "WorkspaceSolarSun"
        )
    }

    func testWorldArtPoolKeepsCuratedOrderAndRepresentativeAsset() {
        let artworks = WorkspaceAppearanceStore.characters(for: .worldArt)

        XCTAssertEqual(
            artworks.map(\.id),
            [
                "art-van-gogh-self-portrait",
                "art-great-wave",
                "art-manet-boating",
                "art-degas-dancing-class",
                "art-view-of-toledo",
                "art-death-of-socrates",
                "art-vermeer-water-pitcher",
                "art-madame-x",
                "art-washington-crossing-delaware",
                "art-springtime"
            ]
        )
        XCTAssertEqual(
            WorkspaceIconStyle.worldArt.representativeAssetName,
            "WorkspaceArtVanGoghSelfPortrait"
        )
        XCTAssertEqual(Set(artworks.map(\.id)).count, 10)
        XCTAssertEqual(Set(artworks.map(\.assetName)).count, 10)
    }

    func testEveryCuratedStyleAssignsOneProjectPerAvailableIconStably() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let curatedStyles: [WorkspaceIconStyle] = [
            .threeKingdoms,
            .abstractGeometry,
            .redChamber,
            .greekMythology,
            .sherlockHolmes,
            .aliceWonderland,
            .onePiece,
            .naruto,
            .solarSystem,
            .worldArt
        ]

        for style in curatedStyles {
            let iconCount = WorkspaceAppearanceStore.characters(for: style).count
            let projectIDs = (0..<iconCount).map { "project-\($0)" }
            let assignments = store.characterAssignments(
                style: style,
                profileID: "mac-a",
                projectIDs: projectIDs
            )

            XCTAssertEqual(assignments.count, iconCount)
            XCTAssertEqual(Set(assignments.values.map(\.id)).count, iconCount)
            XCTAssertEqual(
                store.characterAssignments(
                    style: style,
                    profileID: "mac-a",
                    projectIDs: Array(projectIDs.reversed())
                ),
                assignments,
                "\(style.rawValue) 不应因项目输入顺序变化重新洗牌"
            )
        }
    }

    func testAllWorkspaceIconStyleNamesHaveEnglishAndChineseLocalizations() {
        for style in WorkspaceIconStyle.allCases {
            let englishName = L10n.text(style.titleKey, language: .english)
            let chineseName = L10n.text(style.titleKey, language: .simplifiedChinese)
            let compactEnglishName = L10n.text(style.compactTitleKey, language: .english)
            let compactChineseName = L10n.text(
                style.compactTitleKey,
                language: .simplifiedChinese
            )

            XCTAssertNotEqual(englishName, style.titleKey)
            XCTAssertNotEqual(chineseName, style.titleKey)
            XCTAssertNotEqual(compactEnglishName, style.compactTitleKey)
            XCTAssertNotEqual(compactChineseName, style.compactTitleKey)
            XCTAssertFalse(compactEnglishName.isEmpty)
            XCTAssertFalse(compactChineseName.isEmpty)
        }
    }

    func testHiddenStylesStayAvailableOnlyWhileCurrentlySelected() {
        XCTAssertEqual(
            WorkspaceIconStyle.visibleStyles,
            [
                .journey,
                .threeKingdoms,
                .abstractGeometry,
                .redChamber,
                .onePiece,
                .naruto,
                .solarSystem,
                .worldArt,
                .emoji
            ]
        )
        XCTAssertEqual(WorkspaceIconStyle.visibleStyles.count, 9)
        XCTAssertEqual(
            WorkspaceIconStyle.selectableStyles(currentStyle: .journey),
            WorkspaceIconStyle.visibleStyles
        )
        XCTAssertEqual(
            WorkspaceIconStyle.selectableStyles(currentStyle: .sherlockHolmes),
            WorkspaceIconStyle.visibleStyles + [.sherlockHolmes]
        )
        XCTAssertEqual(
            WorkspaceIconStyle.selectableStyles(currentStyle: .aliceWonderland),
            WorkspaceIconStyle.visibleStyles + [.aliceWonderland]
        )
        XCTAssertEqual(
            WorkspaceIconStyle.selectableStyles(currentStyle: .greekMythology),
            WorkspaceIconStyle.visibleStyles + [.greekMythology]
        )
        XCTAssertEqual(
            WorkspaceIconStyle.selectableStyles(currentStyle: .classicAlbums),
            WorkspaceIconStyle.visibleStyles
        )
        XCTAssertEqual(
            WorkspaceIconStyle.selectableStyles(currentStyle: .waterMargin),
            WorkspaceIconStyle.visibleStyles
        )
        XCTAssertEqual(
            WorkspaceIconStyle.selectableStyles(currentStyle: .digimon),
            WorkspaceIconStyle.visibleStyles
        )
    }

    func testBuiltInEmojiPoolKeepsPreviousProductChoices() {
        XCTAssertEqual(
            WorkspaceAppearanceStore.builtInEmoji,
            ["🐱", "🤖", "🦧", "🌻", "🍔", "⚾️", "🌍", "🌓", "🌈", "🚕", "🌋", "🍍", "📮"]
        )
    }

    func testNewProfileDefaultsToJourneyStyle() {
        let store = WorkspaceAppearanceStore(defaults: defaults)

        XCTAssertEqual(store.style(profileID: "mac-a"), .journey)
    }

    func testLegacyEmojiSelectionRestoresEmojiStyleAndChoice() throws {
        let legacy = [
            "byProfileID": [
                "mac-a": [
                    "project-1": "🌻",
                    "project-2": "🤖"
                ]
            ]
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: "agentd.workspaceAppearancePreferences.v1"
        )

        let store = WorkspaceAppearanceStore(defaults: defaults)

        XCTAssertEqual(store.style(profileID: "mac-a"), .emoji)
        XCTAssertEqual(store.customEmoji(profileID: "mac-a", projectID: "project-1"), "🌻")
        XCTAssertEqual(store.customEmoji(profileID: "mac-a", projectID: "project-2"), "🤖")
    }

    func testLegacyEndpointEmojiMigrationRestoresStyleBeforeWorkspaceOpens() throws {
        let endpoint = "http://mac-a.local:8787"
        let legacy = [
            "byEndpoint": [
                endpoint: [
                    "project-1": "🦧"
                ]
            ]
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: "agentd.workspaceAppearancePreferences.v1"
        )
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: endpoint,
            lastSuccessfulAt: nil
        )
        let store = WorkspaceAppearanceStore(defaults: defaults)

        XCTAssertEqual(store.style(profileID: profile.id), .journey)

        store.migrateLegacyValueIfNeeded(
            profileID: profile.id,
            endpoint: profile.endpoint,
            profiles: [profile]
        )

        XCTAssertEqual(store.style(profileID: profile.id), .emoji)
        XCTAssertEqual(store.customEmoji(profileID: profile.id, projectID: "project-1"), "🦧")
    }

    func testStyleAndTwoKindsOfProjectChoicesPersistIndependently() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setCustomEmoji("🌈", profileID: "mac-a", projectID: "project-1")
        store.setCustomCharacterID("red-boy", profileID: "mac-a", projectID: "project-1")
        store.setStyle(.emoji, profileID: "mac-a")

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(restored.style(profileID: "mac-a"), .emoji)
        XCTAssertEqual(restored.customEmoji(profileID: "mac-a", projectID: "project-1"), "🌈")
        XCTAssertEqual(
            restored.customCharacterID(profileID: "mac-a", projectID: "project-1"),
            "red-boy"
        )

        restored.setStyle(.journey, profileID: "mac-a")
        let switchedBack = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(switchedBack.style(profileID: "mac-a"), .journey)
        XCTAssertEqual(switchedBack.customEmoji(profileID: "mac-a", projectID: "project-1"), "🌈")
        XCTAssertEqual(
            switchedBack.customCharacterID(profileID: "mac-a", projectID: "project-1"),
            "red-boy"
        )
    }

    func testCharacterChoicesPersistIndependentlyForEachStyle() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setCustomCharacterID(
            "three-guan-yu",
            style: .threeKingdoms,
            profileID: "mac-a",
            projectID: "project-1"
        )
        store.setCustomCharacterID(
            "abstract-waves",
            style: .abstractGeometry,
            profileID: "mac-a",
            projectID: "project-1"
        )

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(
            restored.customCharacterID(
                style: .threeKingdoms,
                profileID: "mac-a",
                projectID: "project-1"
            ),
            "three-guan-yu"
        )
        XCTAssertEqual(
            restored.customCharacterID(
                style: .abstractGeometry,
                profileID: "mac-a",
                projectID: "project-1"
            ),
            "abstract-waves"
        )
        XCTAssertNil(
            restored.customCharacterID(
                style: .redChamber,
                profileID: "mac-a",
                projectID: "project-1"
            )
        )
    }

    func testLegacyClassicAlbumPreferenceMigratesToWorldArt() throws {
        let legacyPreferences: [String: Any] = [
            "byProfileID": [
                "mac-a": [
                    "style": "classicAlbums",
                    "characterIDsByStyleAndProject": [
                        "classicAlbums": ["project-1": "album-sos"]
                    ]
                ]
            ]
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacyPreferences),
            forKey: "agentd.workspaceAppearancePreferences.v2"
        )

        let restored = WorkspaceAppearanceStore(defaults: defaults)

        XCTAssertEqual(restored.style(profileID: "mac-a"), .worldArt)
        XCTAssertTrue(
            WorkspaceAppearanceStore.worldArtCharacters.contains(
                restored.character(profileID: "mac-a", projectID: "project-1")
            )
        )

        // 即使旧调用方继续传入已下架 raw value，也只会持久化可用替代项。
        restored.setStyle(.classicAlbums, profileID: "mac-a")
        XCTAssertEqual(restored.style(profileID: "mac-a"), .worldArt)
    }

    func testPreviouslyPersistedV2PreferencesDecodeWithoutNewStyleMap() throws {
        let previousV2: [String: Any] = [
            "byProfileID": [
                "mac-a": [
                    "style": "journey",
                    "characterIDsByProject": ["project-1": "red-boy"],
                    "emojiByProject": ["project-1": "🌈"]
                ]
            ]
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: previousV2),
            forKey: "agentd.workspaceAppearancePreferences.v2"
        )

        let restored = WorkspaceAppearanceStore(defaults: defaults)

        XCTAssertEqual(restored.style(profileID: "mac-a"), .journey)
        XCTAssertEqual(
            restored.customCharacterID(profileID: "mac-a", projectID: "project-1"),
            "red-boy"
        )
        XCTAssertEqual(restored.customEmoji(profileID: "mac-a", projectID: "project-1"), "🌈")
    }

    func testStylePreferenceStaysScopedToConnectionProfile() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setStyle(.emoji, profileID: "mac-a")

        XCTAssertEqual(store.style(profileID: "mac-a"), .emoji)
        XCTAssertEqual(store.style(profileID: "mac-b"), .journey)
    }

    func testDefaultCharacterIsStableForProfileAndProject() {
        let first = WorkspaceAppearanceStore(defaults: defaults)
        let value = first.defaultCharacterID(profileID: "mac-a", projectID: "project-1")

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(
            restored.defaultCharacterID(profileID: "mac-a", projectID: "project-1"),
            value
        )
        XCTAssertTrue(WorkspaceAppearanceStore.builtInCharacters.map(\.id).contains(value))
    }

    func testProjectCharacterIconStaysStableWhenCollidingCatalogArrives() throws {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        // 这两个项目的默认哈希都落在同一角色；旧实现会在批量目录补齐后
        // 把 project-6 从如来佛祖换成玉皇大帝。
        let initial = store.projectIconContent(profileID: "mac-a", projectID: "project-6")
        let expanded = store.projectIconContents(
            profileID: "mac-a",
            projectIDs: ["project-5", "project-6"]
        )

        XCTAssertEqual(try XCTUnwrap(expanded["project-6"]), initial)
        let characterIDs = expanded.values.compactMap { content -> String? in
            guard case let .character(character) = content else { return nil }
            return character.id
        }
        XCTAssertEqual(Set(characterIDs).count, 2, "增量稳定后仍应优先避免项目头像重复")
    }

    func testProjectEmojiStaysStableWhenCollidingCatalogArrives() throws {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setStyle(.emoji, profileID: "mac-a")
        // project-2 / project-5 的默认 Emoji 都是 📮，用于覆盖首帧 fallback
        // 与工作区批量避碰结果不一致的真实路径。
        let initial = store.projectIconContent(profileID: "mac-a", projectID: "project-5")
        let expanded = store.projectIconContents(
            profileID: "mac-a",
            projectIDs: ["project-2", "project-5"]
        )

        XCTAssertEqual(try XCTUnwrap(expanded["project-5"]), initial)
        let emoji = expanded.values.compactMap { content -> String? in
            guard case let .emoji(value) = content else { return nil }
            return value
        }
        XCTAssertEqual(Set(emoji).count, 2)
    }

    func testCharacterAssignmentsStayUniqueWhilePoolHasCapacity() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = (0..<WorkspaceAppearanceStore.builtInCharacters.count)
            .map { "project-\($0)" }

        let assignments = store.characterAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments.count, projectIDs.count)
        XCTAssertEqual(
            Set(assignments.values.map(\.id)).count,
            WorkspaceAppearanceStore.builtInCharacters.count
        )
        XCTAssertEqual(
            store.characterAssignments(profileID: "mac-a", projectIDs: Array(projectIDs.reversed())),
            assignments,
            "项目输入顺序变化不应导致头像重新洗牌"
        )
    }

    func testRetiredWaterMarginAndDigimonPreferencesMigrateToOriginalThemes() throws {
        let legacyPreferences: [String: Any] = [
            "byProfileID": [
                "mac-water": [
                    "style": "waterMargin",
                    "characterIDsByStyleAndProject": [
                        "waterMargin": ["project-1": "water-wu-song"]
                    ]
                ],
                "mac-digimon": [
                    "style": "digimon",
                    "characterIDsByStyleAndProject": [
                        "digimon": ["project-1": "digimon-agumon"]
                    ]
                ]
            ]
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacyPreferences),
            forKey: "agentd.workspaceAppearancePreferences.v2"
        )

        let restored = WorkspaceAppearanceStore(defaults: defaults)

        XCTAssertEqual(restored.style(profileID: "mac-water"), .abstractGeometry)
        XCTAssertEqual(restored.style(profileID: "mac-digimon"), .solarSystem)
        XCTAssertTrue(
            restored.defaultCharacterID(
                style: .abstractGeometry,
                profileID: "mac-water",
                projectID: "project-1"
            ).hasPrefix("abstract-")
        )
        XCTAssertTrue(
            restored.defaultCharacterID(
                style: .solarSystem,
                profileID: "mac-digimon",
                projectID: "project-1"
            ).hasPrefix("solar-")
        )
    }

    func testCharacterAssignmentsReserveCustomChoiceBeforeAutomaticAllocation() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = (0..<10).map { "project-\($0)" }
        store.setCustomCharacterID(
            "sun-wukong",
            profileID: "mac-a",
            projectID: projectIDs[4]
        )

        let assignments = store.characterAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments[projectIDs[4]]?.id, "sun-wukong")
        XCTAssertEqual(Set(assignments.values.map(\.id)).count, projectIDs.count)
    }

    func testCharacterAssignmentsRepairDuplicateHistoricalCustomChoices() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = ["project-a", "project-b", "project-c"]
        store.setCustomCharacterID("red-boy", profileID: "mac-a", projectID: projectIDs[0])
        store.setCustomCharacterID("red-boy", profileID: "mac-a", projectID: projectIDs[1])

        let assignments = store.characterAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments[projectIDs[0]]?.id, "red-boy")
        XCTAssertNotEqual(assignments[projectIDs[1]]?.id, "red-boy")
        XCTAssertEqual(Set(assignments.values.map(\.id)).count, projectIDs.count)
    }

    func testCharacterAssignmentsRepeatOnlyAfterPoolIsExhausted() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = (0...WorkspaceAppearanceStore.builtInCharacters.count)
            .map { "project-\($0)" }

        let assignments = store.characterAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments.count, projectIDs.count)
        XCTAssertEqual(
            Set(assignments.values.map(\.id)).count,
            WorkspaceAppearanceStore.builtInCharacters.count
        )
    }

    func testEmojiAssignmentsStayUniqueWhilePoolHasCapacity() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = (0..<WorkspaceAppearanceStore.builtInEmoji.count)
            .map { "project-\($0)" }

        let assignments = store.emojiAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments.count, projectIDs.count)
        XCTAssertEqual(
            Set(assignments.values).count,
            WorkspaceAppearanceStore.builtInEmoji.count
        )
        XCTAssertEqual(
            store.emojiAssignments(profileID: "mac-a", projectIDs: Array(projectIDs.reversed())),
            assignments,
            "项目输入顺序变化不应导致 Emoji 重新洗牌"
        )
    }

    func testCustomCharacterPersistsAndStaysScopedToProfileAndProject() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setCustomCharacterID("red-boy", profileID: "mac-a", projectID: "project-1")

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(
            restored.character(profileID: "mac-a", projectID: "project-1").id,
            "red-boy"
        )
        XCTAssertNotEqual(
            restored.customCharacterID(profileID: "mac-b", projectID: "project-1"),
            "red-boy"
        )
        XCTAssertNil(restored.customCharacterID(profileID: "mac-a", projectID: "project-2"))

        restored.setCustomCharacterID(nil, profileID: "mac-a", projectID: "project-1")
        XCTAssertNil(restored.customCharacterID(profileID: "mac-a", projectID: "project-1"))
    }

    func testLegacyEndpointCharacterMigratesOnlyForUniqueProfile() throws {
        let key = "agentd.workspaceAppearancePreferences.v1"
        let legacy = [
            "byEndpoint": [
                "http://mac-a.local:8787": [
                    "project-1": "nezha"
                ]
            ]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: key)
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: "http://mac-a.local:8787",
            lastSuccessfulAt: nil
        )
        let store = WorkspaceAppearanceStore(defaults: defaults)

        store.migrateLegacyValueIfNeeded(
            profileID: profile.id,
            endpoint: profile.endpoint,
            profiles: [profile]
        )

        XCTAssertEqual(store.customCharacterID(profileID: profile.id, projectID: "project-1"), "nezha")
        XCTAssertNil(store.customCharacterID(profileID: "mac-b", projectID: "project-1"))
    }

    func testLegacyEndpointCharacterRetriesAfterAmbiguityResolves() throws {
        let key = "agentd.workspaceAppearancePreferences.v1"
        let endpoint = "http://shared-mac.local:8787"
        let legacy = [
            "byEndpoint": [
                endpoint: [
                    "project-1": "nezha"
                ]
            ]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: key)
        let current = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: endpoint,
            lastSuccessfulAt: nil
        )
        let duplicate = ConnectionProfile(
            id: "mac-b",
            displayName: "Mac B",
            endpoint: endpoint + "/",
            lastSuccessfulAt: nil
        )
        let store = WorkspaceAppearanceStore(defaults: defaults)

        store.migrateLegacyValueIfNeeded(
            profileID: current.id,
            endpoint: current.endpoint,
            profiles: [current, duplicate]
        )
        XCTAssertNil(store.customCharacterID(profileID: current.id, projectID: "project-1"))

        store.migrateLegacyValueIfNeeded(
            profileID: current.id,
            endpoint: current.endpoint,
            profiles: [current]
        )
        XCTAssertEqual(store.customCharacterID(profileID: current.id, projectID: "project-1"), "nezha")
    }

    func testCustomCharacterRejectsUnknownAssetID() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setCustomCharacterID("unknown-character", profileID: "mac-a", projectID: "project-1")
        XCTAssertNil(store.customCharacterID(profileID: "mac-a", projectID: "project-1"))
    }

    func testWorkspaceIdentityMigrationKeepsDestinationCustomPreferences() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let profileID = "mac-a"
        let oldID = "legacy-project"
        let newID = "ws_canonical"
        store.setCustomCharacterID("nezha", profileID: profileID, projectID: oldID)
        store.setCustomCharacterID("guanyin", profileID: profileID, projectID: newID)
        store.setCustomCharacterID(
            "three-guan-yu",
            style: .threeKingdoms,
            profileID: profileID,
            projectID: oldID
        )
        store.setCustomCharacterID(
            "three-zhuge-liang",
            style: .threeKingdoms,
            profileID: profileID,
            projectID: newID
        )
        store.setCustomEmoji("🐱", profileID: profileID, projectID: oldID)
        store.setCustomEmoji("🤖", profileID: profileID, projectID: newID)

        store.migrateProjectIdentity(
            profileID: profileID,
            from: oldID,
            to: newID
        )

        XCTAssertEqual(
            store.customCharacterID(style: .journey, profileID: profileID, projectID: newID),
            "guanyin"
        )
        XCTAssertEqual(
            store.customCharacterID(
                style: .threeKingdoms,
                profileID: profileID,
                projectID: newID
            ),
            "three-zhuge-liang"
        )
        XCTAssertEqual(store.customEmoji(profileID: profileID, projectID: newID), "🤖")
        XCTAssertNil(
            store.customCharacterID(style: .journey, profileID: profileID, projectID: oldID)
        )
        XCTAssertNil(
            store.customCharacterID(
                style: .threeKingdoms,
                profileID: profileID,
                projectID: oldID
            )
        )
        XCTAssertNil(store.customEmoji(profileID: profileID, projectID: oldID))
    }

    func testWorkspaceIdentityMigrationKeepsAutomaticIconDuringCurrentRun() throws {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let profileID = "mac-a"
        let oldID = "legacy-project"
        let oldDefaultID = store.defaultCharacterID(profileID: profileID, projectID: oldID)
        let newID = try XCTUnwrap(
            (0..<100)
                .map { "canonical-project-\($0)" }
                .first {
                    store.defaultCharacterID(profileID: profileID, projectID: $0) != oldDefaultID
                }
        )
        let initial = store.projectIconContent(profileID: profileID, projectID: oldID)

        store.migrateProjectIdentity(profileID: profileID, from: oldID, to: newID)

        XCTAssertEqual(store.projectIconContent(profileID: profileID, projectID: newID), initial)
    }
}
