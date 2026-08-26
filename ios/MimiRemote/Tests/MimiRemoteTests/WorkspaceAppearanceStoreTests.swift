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
            .classicCharacters,
            .redChamber,
            .greekMythology,
            .sherlockHolmes,
            .aliceWonderland,
            .onePiece,
            .naruto,
            .worldArt
        ]
        let curatedIcons = tenIconStyles.flatMap {
            WorkspaceAppearanceStore.characters(for: $0)
        }

        for style in tenIconStyles {
            XCTAssertEqual(
                WorkspaceAppearanceStore.characters(for: style).count,
                10,
                "\(style.rawValue) 应提供 10 个图标"
            )
        }
        XCTAssertEqual(Set(curatedIcons.map(\.id)).count, 90)
        XCTAssertEqual(Set(curatedIcons.map(\.assetName)).count, 90)
        XCTAssertTrue(WorkspaceAppearanceStore.characters(for: .emoji).isEmpty)
    }

    func testRetiredStylesKeepOnlyPersistenceIdentifiersAndMigrate() {
        XCTAssertEqual(WorkspaceIconStyle.waterMargin.availableStyle, .classicCharacters)
        XCTAssertEqual(WorkspaceIconStyle.abstractGeometry.availableStyle, .classicCharacters)
        XCTAssertEqual(WorkspaceIconStyle.digimon.availableStyle, .classicCharacters)
        XCTAssertEqual(WorkspaceIconStyle.solarSystem.availableStyle, .classicCharacters)
        XCTAssertEqual(WorkspaceIconStyle.classicAlbums.availableStyle, .worldArt)
        XCTAssertFalse(WorkspaceIconStyle.visibleStyles.contains(.waterMargin))
        XCTAssertFalse(WorkspaceIconStyle.visibleStyles.contains(.abstractGeometry))
        XCTAssertFalse(WorkspaceIconStyle.visibleStyles.contains(.digimon))
        XCTAssertFalse(WorkspaceIconStyle.visibleStyles.contains(.solarSystem))
        XCTAssertFalse(WorkspaceIconStyle.visibleStyles.contains(.classicAlbums))
        XCTAssertNil(WorkspaceIconStyle.waterMargin.representativeAssetName)
        XCTAssertNil(WorkspaceIconStyle.digimon.representativeAssetName)
        XCTAssertNil(WorkspaceIconStyle.classicAlbums.representativeAssetName)
        XCTAssertTrue(WorkspaceAppearanceStore.characters(for: .waterMargin).isEmpty)
        XCTAssertTrue(WorkspaceAppearanceStore.characters(for: .abstractGeometry).isEmpty)
        XCTAssertTrue(WorkspaceAppearanceStore.characters(for: .digimon).isEmpty)
        XCTAssertTrue(WorkspaceAppearanceStore.characters(for: .solarSystem).isEmpty)
        XCTAssertTrue(WorkspaceAppearanceStore.characters(for: .classicAlbums).isEmpty)
    }

    func testCuratedCharacterPoolsKeepDesignedPopularityOrder() {
        let expectedOrders: [(WorkspaceIconStyle, [String])] = [
            (
                .threeKingdoms,
                [
                    "three-guan-yu", "three-zhuge-liang", "three-cao-cao", "three-liu-bei",
                    "three-zhao-yun", "three-zhang-fei", "three-lu-bu", "three-diaochan",
                    "three-sima-yi", "three-sun-quan"
                ]
            ),
            (
                .classicCharacters,
                [
                    "classic-goku", "classic-vegeta", "classic-piccolo",
                    "classic-future-trunks", "classic-android-18", "classic-perfect-cell",
                    "classic-frieza", "classic-krillin", "classic-majin-buu",
                    "classic-master-roshi"
                ]
            ),
            (
                .redChamber,
                [
                    "red-lin-daiyu", "red-jia-baoyu", "red-xue-baochai", "red-wang-xifeng",
                    "red-shi-xiangyun", "red-grandmother-jia", "red-qingwen",
                    "red-jia-tanchun", "red-miaoyu", "red-xiangling"
                ]
            ),
            (
                .greekMythology,
                [
                    "greek-zeus", "greek-athena", "greek-poseidon", "greek-hades",
                    "greek-aphrodite", "greek-apollo", "greek-artemis", "greek-hera",
                    "greek-hermes", "greek-ares"
                ]
            ),
            (
                .sherlockHolmes,
                [
                    "sherlock-holmes", "sherlock-watson", "sherlock-moriarty",
                    "sherlock-irene-adler", "sherlock-mycroft", "sherlock-lestrade",
                    "sherlock-hudson", "sherlock-morstan", "sherlock-moran",
                    "sherlock-gregson"
                ]
            ),
            (
                .aliceWonderland,
                [
                    "alice-alice", "alice-cheshire-cat", "alice-mad-hatter",
                    "alice-white-rabbit", "alice-queen-of-hearts", "alice-caterpillar",
                    "alice-march-hare", "alice-dormouse", "alice-king-of-hearts",
                    "alice-duchess"
                ]
            ),
            (
                .onePiece,
                [
                    "one-piece-luffy", "one-piece-zoro", "one-piece-sanji", "one-piece-nami",
                    "one-piece-robin", "one-piece-chopper", "one-piece-usopp",
                    "one-piece-brook", "one-piece-jinbe", "one-piece-franky"
                ]
            ),
            (
                .naruto,
                [
                    "naruto-naruto", "naruto-sasuke", "naruto-kakashi", "naruto-itachi",
                    "naruto-sakura", "naruto-hinata", "naruto-jiraiya", "naruto-gaara",
                    "naruto-shikamaru", "naruto-tsunade"
                ]
            )
        ]

        for (style, expectedOrder) in expectedOrders {
            XCTAssertEqual(
                WorkspaceAppearanceStore.characters(for: style).map(\.id),
                expectedOrder,
                "\(style.rawValue) 的角色顺序不应意外变化"
            )
        }

        XCTAssertEqual(
            WorkspaceIconStyle.classicCharacters.representativeAssetName,
            "WorkspaceCharacterClassicGoku"
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

    func testEveryCuratedStyleAssignsProjectsInProductOrder() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let curatedStyles: [WorkspaceIconStyle] = [
            .threeKingdoms,
            .classicCharacters,
            .redChamber,
            .greekMythology,
            .sherlockHolmes,
            .aliceWonderland,
            .onePiece,
            .naruto,
            .worldArt
        ]

        for style in curatedStyles {
            let icons = WorkspaceAppearanceStore.characters(for: style)
            let iconCount = icons.count
            let projectIDs = (0..<iconCount).map { "project-\($0)" }
            let assignments = store.characterAssignments(
                style: style,
                profileID: "mac-a",
                projectIDs: projectIDs
            )

            XCTAssertEqual(assignments.count, iconCount)
            XCTAssertEqual(Set(assignments.values.map(\.id)).count, iconCount)
            for (index, projectID) in projectIDs.enumerated() {
                XCTAssertEqual(assignments[projectID]?.id, icons[index].id)
            }

            let reversedProjectIDs = Array(projectIDs.reversed())
            let reversedAssignments = store.characterAssignments(
                style: style,
                profileID: "mac-a",
                projectIDs: reversedProjectIDs
            )
            for (index, projectID) in reversedProjectIDs.enumerated() {
                XCTAssertEqual(reversedAssignments[projectID]?.id, icons[index].id)
            }
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
                .classicCharacters,
                .redChamber,
                .onePiece,
                .naruto,
                .worldArt,
                .emoji
            ]
        )
        XCTAssertEqual(WorkspaceIconStyle.visibleStyles.count, 8)
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

    func testWorkspaceIconStylePickerUsesScrollableSingleRowForWideContainers() {
        XCTAssertFalse(
            WorkspaceIconStylePickerLayout.usesSingleRow(
                viewportWidth: 479,
                itemCount: 8,
                isAccessibilitySize: false
            )
        )
        XCTAssertTrue(
            WorkspaceIconStylePickerLayout.usesSingleRow(
                viewportWidth: 480,
                itemCount: 8,
                isAccessibilitySize: false
            ),
            "宽布局不要求 8 项一次放下，超出部分应由横向滚动承接"
        )
        XCTAssertFalse(
            WorkspaceIconStylePickerLayout.usesSingleRow(
                viewportWidth: 720,
                itemCount: 8,
                isAccessibilitySize: true
            ),
            "辅助功能字号不应为了铺满一行而压缩头像和标题"
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
            "classic-future-trunks",
            style: .classicCharacters,
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
                style: .classicCharacters,
                profileID: "mac-a",
                projectID: "project-1"
            ),
            "classic-future-trunks"
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

    func testDefaultCharacterUsesFirstRoleInSelectedTheme() {
        let store = WorkspaceAppearanceStore(defaults: defaults)

        XCTAssertEqual(
            store.defaultCharacterID(profileID: "mac-a", projectID: "project-1"),
            "sun-wukong"
        )
        XCTAssertEqual(
            store.defaultCharacterID(
                style: .threeKingdoms,
                profileID: "mac-b",
                projectID: "another-project"
            ),
            "three-liu-bei"
        )
    }

    func testProjectCharacterIconsFollowDirectoryOrder() throws {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let assignments = store.projectIconContents(
            profileID: "mac-a",
            projectIDs: ["project-z", "project-a", "project-b"]
        )

        let characterIDs = try ["project-z", "project-a", "project-b"].map { projectID in
            let content = try XCTUnwrap(assignments[projectID])
            guard case let .character(character) = content else {
                XCTFail("项目应使用角色图标")
                return ""
            }
            return character.id
        }
        XCTAssertEqual(characterIDs, ["sun-wukong", "tang-sanzang", "zhu-bajie"])
    }

    func testProjectEmojiFollowsDirectoryOrder() throws {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setStyle(.emoji, profileID: "mac-a")
        let assignments = store.projectIconContents(
            profileID: "mac-a",
            projectIDs: ["project-z", "project-a", "project-b"]
        )

        let emoji = try ["project-z", "project-a", "project-b"].map { projectID in
            let content = try XCTUnwrap(assignments[projectID])
            guard case let .emoji(value) = content else {
                XCTFail("Emoji 主题应使用 Emoji 图标")
                return ""
            }
            return value
        }
        XCTAssertEqual(emoji, Array(WorkspaceAppearanceStore.builtInEmoji.prefix(3)))
    }

    func testCharacterAssignmentsFollowInputOrderWhilePoolHasCapacity() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let icons = WorkspaceAppearanceStore.builtInCharacters
        let projectIDs = (0..<icons.count)
            .map { "project-\($0)" }

        let assignments = store.characterAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments.count, projectIDs.count)
        for (index, projectID) in projectIDs.enumerated() {
            XCTAssertEqual(assignments[projectID]?.id, icons[index].id)
        }

        let reversedProjectIDs = Array(projectIDs.reversed())
        let reversedAssignments = store.characterAssignments(
            profileID: "mac-a",
            projectIDs: reversedProjectIDs
        )
        for (index, projectID) in reversedProjectIDs.enumerated() {
            XCTAssertEqual(reversedAssignments[projectID]?.id, icons[index].id)
        }
    }

    func testRetiredStylesMigrateToCurrentReplacementThemes() throws {
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

        XCTAssertEqual(restored.style(profileID: "mac-water"), .classicCharacters)
        XCTAssertEqual(restored.style(profileID: "mac-digimon"), .classicCharacters)
        XCTAssertTrue(
            restored.defaultCharacterID(
                style: .classicCharacters,
                profileID: "mac-water",
                projectID: "project-1"
            ).hasPrefix("classic-")
        )
        XCTAssertTrue(
            restored.defaultCharacterID(
                style: .classicCharacters,
                profileID: "mac-digimon",
                projectID: "project-1"
            ).hasPrefix("classic-")
        )
    }

    func testCustomCharacterDoesNotShiftAutomaticOrder() {
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
        XCTAssertEqual(assignments[projectIDs[0]]?.id, "sun-wukong")
        XCTAssertEqual(assignments[projectIDs[1]]?.id, "tang-sanzang")
        XCTAssertEqual(assignments[projectIDs[5]]?.id, "guanyin")
    }

    func testCharacterAssignmentsPreserveDuplicateHistoricalCustomChoices() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = ["project-a", "project-b", "project-c"]
        store.setCustomCharacterID("red-boy", profileID: "mac-a", projectID: projectIDs[0])
        store.setCustomCharacterID("red-boy", profileID: "mac-a", projectID: projectIDs[1])

        let assignments = store.characterAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments[projectIDs[0]]?.id, "red-boy")
        XCTAssertEqual(assignments[projectIDs[1]]?.id, "red-boy")
        XCTAssertEqual(assignments[projectIDs[2]]?.id, "zhu-bajie")
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
        XCTAssertEqual(
            assignments[projectIDs[WorkspaceAppearanceStore.builtInCharacters.count]]?.id,
            "sun-wukong"
        )
    }

    func testEmojiAssignmentsFollowInputOrderWhilePoolHasCapacity() {
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
        for (index, projectID) in projectIDs.enumerated() {
            XCTAssertEqual(assignments[projectID], WorkspaceAppearanceStore.builtInEmoji[index])
        }

        let reversedProjectIDs = Array(projectIDs.reversed())
        let reversedAssignments = store.emojiAssignments(
            profileID: "mac-a",
            projectIDs: reversedProjectIDs
        )
        for (index, projectID) in reversedProjectIDs.enumerated() {
            XCTAssertEqual(
                reversedAssignments[projectID],
                WorkspaceAppearanceStore.builtInEmoji[index]
            )
        }
    }

    func testCustomEmojiDoesNotShiftAutomaticOrder() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = ["project-a", "project-b", "project-c"]
        store.setCustomEmoji("🌈", profileID: "mac-a", projectID: projectIDs[1])

        let assignments = store.emojiAssignments(profileID: "mac-a", projectIDs: projectIDs)

        XCTAssertEqual(assignments[projectIDs[0]], "🐱")
        XCTAssertEqual(assignments[projectIDs[1]], "🌈")
        XCTAssertEqual(assignments[projectIDs[2]], "🦧")
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

    func testWorkspaceIdentityMigrationKeepsPositionBasedAutomaticIcon() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let profileID = "mac-a"
        let oldID = "legacy-project"
        let newID = "canonical-project"

        store.migrateProjectIdentity(profileID: profileID, from: oldID, to: newID)

        let assignments = store.characterAssignments(
            profileID: profileID,
            projectIDs: [newID, "second-project"]
        )
        XCTAssertEqual(assignments[newID]?.id, "sun-wukong")
        XCTAssertEqual(assignments["second-project"]?.id, "tang-sanzang")
    }
}
