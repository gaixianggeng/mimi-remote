import Combine
import CryptoKit
import Foundation

enum WorkspaceIconStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case journey
    case threeKingdoms
    case waterMargin
    case redChamber
    case greekMythology
    case sherlockHolmes
    case aliceWonderland
    case onePiece
    case naruto
    case digimon
    case classicAlbums
    case worldArt
    case emoji

    var id: String { rawValue }

    /// 默认只展示当前主推风格；已下架风格继续保留枚举与数据，避免破坏历史选择。
    static let visibleStyles: [WorkspaceIconStyle] = [
        .journey,
        .threeKingdoms,
        .waterMargin,
        .redChamber,
        .onePiece,
        .naruto,
        .digimon,
        .classicAlbums,
        .worldArt,
        .emoji
    ]

    static func selectableStyles(currentStyle: WorkspaceIconStyle) -> [WorkspaceIconStyle] {
        guard !visibleStyles.contains(currentStyle) else {
            return visibleStyles
        }
        // 历史用户仍能看到当前已选风格；切换后，下架风格自然从选择器消失。
        return visibleStyles + [currentStyle]
    }

    var usesCharacters: Bool {
        self != .emoji
    }

    var titleKey: String {
        switch self {
        case .journey:
            return "ui.journey_to_the_west"
        case .threeKingdoms:
            return "ui.workspace_icon_style_three_kingdoms"
        case .waterMargin:
            return "ui.workspace_icon_style_water_margin"
        case .redChamber:
            return "ui.workspace_icon_style_red_chamber"
        case .greekMythology:
            return "ui.workspace_icon_style_greek_mythology"
        case .sherlockHolmes:
            return "ui.workspace_icon_style_sherlock_holmes"
        case .aliceWonderland:
            return "ui.workspace_icon_style_alice_wonderland"
        case .onePiece:
            return "ui.workspace_icon_style_one_piece"
        case .naruto:
            return "ui.workspace_icon_style_naruto"
        case .digimon:
            return "ui.workspace_icon_style_digimon"
        case .classicAlbums:
            return "ui.workspace_icon_style_classic_albums"
        case .worldArt:
            return "ui.workspace_icon_style_world_art"
        case .emoji:
            return "ui.emoji"
        }
    }

    var title: String {
        L10n.text(titleKey)
    }

    var compactTitleKey: String {
        switch self {
        case .journey:
            return "ui.workspace_icon_style_compact_journey"
        case .threeKingdoms:
            return "ui.workspace_icon_style_compact_three_kingdoms"
        case .waterMargin:
            return "ui.workspace_icon_style_compact_water_margin"
        case .redChamber:
            return "ui.workspace_icon_style_compact_red_chamber"
        case .greekMythology:
            return "ui.workspace_icon_style_compact_greek_mythology"
        case .sherlockHolmes:
            return "ui.workspace_icon_style_compact_sherlock_holmes"
        case .aliceWonderland:
            return "ui.workspace_icon_style_compact_alice_wonderland"
        case .onePiece:
            return "ui.workspace_icon_style_compact_one_piece"
        case .naruto:
            return "ui.workspace_icon_style_compact_naruto"
        case .digimon:
            return "ui.workspace_icon_style_compact_digimon"
        case .classicAlbums:
            return "ui.workspace_icon_style_compact_classic_albums"
        case .worldArt:
            return "ui.workspace_icon_style_compact_world_art"
        case .emoji:
            return "ui.workspace_icon_style_compact_emoji"
        }
    }

    /// 网格显示一行完整作品名；辅助功能同样使用 `title` 朗读完整作品名。
    var compactTitle: String {
        L10n.text(compactTitleKey)
    }

    var representativeAssetName: String? {
        switch self {
        case .journey:
            return "WorkspaceCharacterSunWukong"
        case .threeKingdoms:
            return "WorkspaceCharacterThreeGuanYu"
        case .waterMargin:
            return "WorkspaceCharacterWaterLuZhishen"
        case .redChamber:
            return "WorkspaceCharacterRedLinDaiyu"
        case .greekMythology:
            return "WorkspaceCharacterGreekAthena"
        case .sherlockHolmes:
            return "WorkspaceCharacterSherlockHolmes"
        case .aliceWonderland:
            return "WorkspaceCharacterAliceAlice"
        case .onePiece:
            return "WorkspaceCharacterOnePieceLuffy"
        case .naruto:
            return "WorkspaceCharacterNarutoNaruto"
        case .digimon:
            return "WorkspaceCharacterDigimonAgumon"
        case .classicAlbums:
            return "WorkspaceAlbumAtomHeartMother"
        case .worldArt:
            return "WorkspaceArtVanGoghSelfPortrait"
        case .emoji:
            return nil
        }
    }
}

struct WorkspaceCharacterIcon: Identifiable, Equatable, Sendable {
    let id: String
    let assetName: String
    let nameKey: String

    /// 角色 ID 和资源名需要保持稳定，展示名则跟随 App 当前语言动态解析。
    var name: String {
        L10n.text(nameKey)
    }
}

/// 工作区、会话列表和侧栏共享同一份项目图标内容，避免同一个项目在不同页面
/// 分别落成角色图、Emoji 或运行时品牌图标，造成身份识别不一致。
enum WorkspaceProjectIconContent: Equatable, Sendable {
    case character(WorkspaceCharacterIcon)
    case emoji(String)
}

private struct WorkspaceAppearancePreferences: Codable {
    var style: WorkspaceIconStyle?
    var characterIDsByProject: [String: String] = [:]
    var emojiByProject: [String: String] = [:]
    var characterIDsByStyleAndProject: [String: [String: String]] = [:]

    private enum CodingKeys: String, CodingKey {
        case style
        case characterIDsByProject
        case emojiByProject
        case characterIDsByStyleAndProject
    }

    init(
        style: WorkspaceIconStyle? = nil,
        characterIDsByProject: [String: String] = [:],
        emojiByProject: [String: String] = [:],
        characterIDsByStyleAndProject: [String: [String: String]] = [:]
    ) {
        self.style = style
        self.characterIDsByProject = characterIDsByProject
        self.emojiByProject = emojiByProject
        self.characterIDsByStyleAndProject = characterIDsByStyleAndProject
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(WorkspaceIconStyle.self, forKey: .style)
        characterIDsByProject = try container.decodeIfPresent(
            [String: String].self,
            forKey: .characterIDsByProject
        ) ?? [:]
        emojiByProject = try container.decodeIfPresent(
            [String: String].self,
            forKey: .emojiByProject
        ) ?? [:]
        // v2 已发布数据没有该字段；decodeIfPresent 可原地兼容，不需要更换 UserDefaults 键。
        characterIDsByStyleAndProject = try container.decodeIfPresent(
            [String: [String: String]].self,
            forKey: .characterIDsByStyleAndProject
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(style, forKey: .style)
        try container.encode(characterIDsByProject, forKey: .characterIDsByProject)
        try container.encode(emojiByProject, forKey: .emojiByProject)
        try container.encode(
            characterIDsByStyleAndProject,
            forKey: .characterIDsByStyleAndProject
        )
    }

    var isEmpty: Bool {
        style == nil
            && characterIDsByProject.isEmpty
            && emojiByProject.isEmpty
            && characterIDsByStyleAndProject.values.allSatisfy(\.isEmpty)
    }

    mutating func mergeMissingValues(from legacy: Self) {
        if style == nil {
            style = legacy.style
        }
        for (projectID, characterID) in legacy.characterIDsByProject
            where characterIDsByProject[projectID] == nil {
            characterIDsByProject[projectID] = characterID
        }
        for (projectID, emoji) in legacy.emojiByProject where emojiByProject[projectID] == nil {
            emojiByProject[projectID] = emoji
        }
        for (styleID, legacyChoices) in legacy.characterIDsByStyleAndProject {
            var choices = characterIDsByStyleAndProject[styleID] ?? [:]
            for (projectID, characterID) in legacyChoices where choices[projectID] == nil {
                choices[projectID] = characterID
            }
            characterIDsByStyleAndProject[styleID] = choices
        }
    }
}

/// 工作区图标是当前设备的展示偏好，不属于远端项目配置，也不参与会话状态同步。
@MainActor
final class WorkspaceAppearanceStore: ObservableObject {
    static let builtInEmoji = ["🐱", "🤖", "🦧", "🌻", "🍔", "⚾️", "🌍", "🌓", "🌈", "🚕", "🌋", "🍍", "📮"]

    static let builtInCharacters = [
        WorkspaceCharacterIcon(id: "sun-wukong", assetName: "WorkspaceCharacterSunWukong", nameKey: "ui.workspace_character_sun_wukong"),
        WorkspaceCharacterIcon(id: "tang-sanzang", assetName: "WorkspaceCharacterTangSanzang", nameKey: "ui.workspace_character_tang_sanzang"),
        WorkspaceCharacterIcon(id: "zhu-bajie", assetName: "WorkspaceCharacterZhuBajie", nameKey: "ui.workspace_character_zhu_bajie"),
        WorkspaceCharacterIcon(id: "sha-wujing", assetName: "WorkspaceCharacterShaWujing", nameKey: "ui.workspace_character_sha_wujing"),
        WorkspaceCharacterIcon(id: "white-dragon-horse", assetName: "WorkspaceCharacterWhiteDragonHorse", nameKey: "ui.workspace_character_white_dragon_horse"),
        WorkspaceCharacterIcon(id: "guanyin", assetName: "WorkspaceCharacterGuanyin", nameKey: "ui.workspace_character_guanyin"),
        WorkspaceCharacterIcon(id: "tathagata", assetName: "WorkspaceCharacterTathagata", nameKey: "ui.workspace_character_tathagata"),
        WorkspaceCharacterIcon(id: "jade-emperor", assetName: "WorkspaceCharacterJadeEmperor", nameKey: "ui.workspace_character_jade_emperor"),
        WorkspaceCharacterIcon(id: "taishang-laojun", assetName: "WorkspaceCharacterTaishangLaojun", nameKey: "ui.workspace_character_taishang_laojun"),
        WorkspaceCharacterIcon(id: "nezha", assetName: "WorkspaceCharacterNezha", nameKey: "ui.workspace_character_nezha"),
        WorkspaceCharacterIcon(id: "erlang-shen", assetName: "WorkspaceCharacterErlangShen", nameKey: "ui.workspace_character_erlang_shen"),
        WorkspaceCharacterIcon(id: "bull-demon-king", assetName: "WorkspaceCharacterBullDemonKing", nameKey: "ui.workspace_character_bull_demon_king"),
        WorkspaceCharacterIcon(id: "princess-iron-fan", assetName: "WorkspaceCharacterPrincessIronFan", nameKey: "ui.workspace_character_princess_iron_fan"),
        WorkspaceCharacterIcon(id: "red-boy", assetName: "WorkspaceCharacterRedBoy", nameKey: "ui.workspace_character_red_boy"),
        WorkspaceCharacterIcon(id: "white-bone-demon", assetName: "WorkspaceCharacterWhiteBoneDemon", nameKey: "ui.workspace_character_white_bone_demon"),
        WorkspaceCharacterIcon(id: "spider-demon", assetName: "WorkspaceCharacterSpiderDemon", nameKey: "ui.workspace_character_spider_demon"),
        WorkspaceCharacterIcon(id: "yellow-robed-demon", assetName: "WorkspaceCharacterYellowRobedDemon", nameKey: "ui.workspace_character_yellow_robed_demon"),
        WorkspaceCharacterIcon(id: "golden-horn-king", assetName: "WorkspaceCharacterGoldenHornKing", nameKey: "ui.workspace_character_golden_horn_king"),
        WorkspaceCharacterIcon(id: "silver-horn-king", assetName: "WorkspaceCharacterSilverHornKing", nameKey: "ui.workspace_character_silver_horn_king"),
        WorkspaceCharacterIcon(id: "queen-womens-kingdom", assetName: "WorkspaceCharacterQueenWomensKingdom", nameKey: "ui.workspace_character_queen_womens_kingdom")
    ]

    static let threeKingdomsCharacters = [
        WorkspaceCharacterIcon(id: "three-liu-bei", assetName: "WorkspaceCharacterThreeLiuBei", nameKey: "ui.workspace_character_three_liu_bei"),
        WorkspaceCharacterIcon(id: "three-guan-yu", assetName: "WorkspaceCharacterThreeGuanYu", nameKey: "ui.workspace_character_three_guan_yu"),
        WorkspaceCharacterIcon(id: "three-zhang-fei", assetName: "WorkspaceCharacterThreeZhangFei", nameKey: "ui.workspace_character_three_zhang_fei"),
        WorkspaceCharacterIcon(id: "three-zhuge-liang", assetName: "WorkspaceCharacterThreeZhugeLiang", nameKey: "ui.workspace_character_three_zhuge_liang"),
        WorkspaceCharacterIcon(id: "three-cao-cao", assetName: "WorkspaceCharacterThreeCaoCao", nameKey: "ui.workspace_character_three_cao_cao"),
        WorkspaceCharacterIcon(id: "three-sun-quan", assetName: "WorkspaceCharacterThreeSunQuan", nameKey: "ui.workspace_character_three_sun_quan"),
        WorkspaceCharacterIcon(id: "three-zhao-yun", assetName: "WorkspaceCharacterThreeZhaoYun", nameKey: "ui.workspace_character_three_zhao_yun"),
        WorkspaceCharacterIcon(id: "three-lu-bu", assetName: "WorkspaceCharacterThreeLuBu", nameKey: "ui.workspace_character_three_lu_bu"),
        WorkspaceCharacterIcon(id: "three-diaochan", assetName: "WorkspaceCharacterThreeDiaochan", nameKey: "ui.workspace_character_three_diaochan"),
        WorkspaceCharacterIcon(id: "three-sima-yi", assetName: "WorkspaceCharacterThreeSimaYi", nameKey: "ui.workspace_character_three_sima_yi")
    ]

    static let waterMarginCharacters = [
        WorkspaceCharacterIcon(id: "water-song-jiang", assetName: "WorkspaceCharacterWaterSongJiang", nameKey: "ui.workspace_character_water_song_jiang"),
        WorkspaceCharacterIcon(id: "water-lin-chong", assetName: "WorkspaceCharacterWaterLinChong", nameKey: "ui.workspace_character_water_lin_chong"),
        WorkspaceCharacterIcon(id: "water-lu-zhishen", assetName: "WorkspaceCharacterWaterLuZhishen", nameKey: "ui.workspace_character_water_lu_zhishen"),
        WorkspaceCharacterIcon(id: "water-wu-song", assetName: "WorkspaceCharacterWaterWuSong", nameKey: "ui.workspace_character_water_wu_song"),
        WorkspaceCharacterIcon(id: "water-li-kui", assetName: "WorkspaceCharacterWaterLiKui", nameKey: "ui.workspace_character_water_li_kui"),
        WorkspaceCharacterIcon(id: "water-wu-yong", assetName: "WorkspaceCharacterWaterWuYong", nameKey: "ui.workspace_character_water_wu_yong"),
        WorkspaceCharacterIcon(id: "water-lu-junyi", assetName: "WorkspaceCharacterWaterLuJunyi", nameKey: "ui.workspace_character_water_lu_junyi"),
        WorkspaceCharacterIcon(id: "water-yan-qing", assetName: "WorkspaceCharacterWaterYanQing", nameKey: "ui.workspace_character_water_yan_qing"),
        WorkspaceCharacterIcon(id: "water-hu-sanniang", assetName: "WorkspaceCharacterWaterHuSanniang", nameKey: "ui.workspace_character_water_hu_sanniang"),
        WorkspaceCharacterIcon(id: "water-sun-erniang", assetName: "WorkspaceCharacterWaterSunErniang", nameKey: "ui.workspace_character_water_sun_erniang")
    ]

    static let redChamberCharacters = [
        WorkspaceCharacterIcon(id: "red-jia-baoyu", assetName: "WorkspaceCharacterRedJiaBaoyu", nameKey: "ui.workspace_character_red_jia_baoyu"),
        WorkspaceCharacterIcon(id: "red-lin-daiyu", assetName: "WorkspaceCharacterRedLinDaiyu", nameKey: "ui.workspace_character_red_lin_daiyu"),
        WorkspaceCharacterIcon(id: "red-xue-baochai", assetName: "WorkspaceCharacterRedXueBaochai", nameKey: "ui.workspace_character_red_xue_baochai"),
        WorkspaceCharacterIcon(id: "red-wang-xifeng", assetName: "WorkspaceCharacterRedWangXifeng", nameKey: "ui.workspace_character_red_wang_xifeng"),
        WorkspaceCharacterIcon(id: "red-shi-xiangyun", assetName: "WorkspaceCharacterRedShiXiangyun", nameKey: "ui.workspace_character_red_shi_xiangyun"),
        WorkspaceCharacterIcon(id: "red-miaoyu", assetName: "WorkspaceCharacterRedMiaoyu", nameKey: "ui.workspace_character_red_miaoyu"),
        WorkspaceCharacterIcon(id: "red-jia-tanchun", assetName: "WorkspaceCharacterRedJiaTanchun", nameKey: "ui.workspace_character_red_jia_tanchun"),
        WorkspaceCharacterIcon(id: "red-qingwen", assetName: "WorkspaceCharacterRedQingwen", nameKey: "ui.workspace_character_red_qingwen"),
        WorkspaceCharacterIcon(id: "red-xiangling", assetName: "WorkspaceCharacterRedXiangling", nameKey: "ui.workspace_character_red_xiangling"),
        WorkspaceCharacterIcon(id: "red-grandmother-jia", assetName: "WorkspaceCharacterRedGrandmotherJia", nameKey: "ui.workspace_character_red_grandmother_jia")
    ]

    static let greekMythologyCharacters = [
        WorkspaceCharacterIcon(id: "greek-zeus", assetName: "WorkspaceCharacterGreekZeus", nameKey: "ui.workspace_character_greek_zeus"),
        WorkspaceCharacterIcon(id: "greek-hera", assetName: "WorkspaceCharacterGreekHera", nameKey: "ui.workspace_character_greek_hera"),
        WorkspaceCharacterIcon(id: "greek-poseidon", assetName: "WorkspaceCharacterGreekPoseidon", nameKey: "ui.workspace_character_greek_poseidon"),
        WorkspaceCharacterIcon(id: "greek-athena", assetName: "WorkspaceCharacterGreekAthena", nameKey: "ui.workspace_character_greek_athena"),
        WorkspaceCharacterIcon(id: "greek-apollo", assetName: "WorkspaceCharacterGreekApollo", nameKey: "ui.workspace_character_greek_apollo"),
        WorkspaceCharacterIcon(id: "greek-artemis", assetName: "WorkspaceCharacterGreekArtemis", nameKey: "ui.workspace_character_greek_artemis"),
        WorkspaceCharacterIcon(id: "greek-hermes", assetName: "WorkspaceCharacterGreekHermes", nameKey: "ui.workspace_character_greek_hermes"),
        WorkspaceCharacterIcon(id: "greek-aphrodite", assetName: "WorkspaceCharacterGreekAphrodite", nameKey: "ui.workspace_character_greek_aphrodite"),
        WorkspaceCharacterIcon(id: "greek-ares", assetName: "WorkspaceCharacterGreekAres", nameKey: "ui.workspace_character_greek_ares"),
        WorkspaceCharacterIcon(id: "greek-hades", assetName: "WorkspaceCharacterGreekHades", nameKey: "ui.workspace_character_greek_hades")
    ]

    static let sherlockHolmesCharacters = [
        WorkspaceCharacterIcon(id: "sherlock-holmes", assetName: "WorkspaceCharacterSherlockHolmes", nameKey: "ui.workspace_character_sherlock_holmes"),
        WorkspaceCharacterIcon(id: "sherlock-watson", assetName: "WorkspaceCharacterSherlockWatson", nameKey: "ui.workspace_character_sherlock_watson"),
        WorkspaceCharacterIcon(id: "sherlock-irene-adler", assetName: "WorkspaceCharacterSherlockIreneAdler", nameKey: "ui.workspace_character_sherlock_irene_adler"),
        WorkspaceCharacterIcon(id: "sherlock-moriarty", assetName: "WorkspaceCharacterSherlockMoriarty", nameKey: "ui.workspace_character_sherlock_moriarty"),
        WorkspaceCharacterIcon(id: "sherlock-mycroft", assetName: "WorkspaceCharacterSherlockMycroft", nameKey: "ui.workspace_character_sherlock_mycroft"),
        WorkspaceCharacterIcon(id: "sherlock-lestrade", assetName: "WorkspaceCharacterSherlockLestrade", nameKey: "ui.workspace_character_sherlock_lestrade"),
        WorkspaceCharacterIcon(id: "sherlock-hudson", assetName: "WorkspaceCharacterSherlockHudson", nameKey: "ui.workspace_character_sherlock_hudson"),
        WorkspaceCharacterIcon(id: "sherlock-morstan", assetName: "WorkspaceCharacterSherlockMorstan", nameKey: "ui.workspace_character_sherlock_morstan"),
        WorkspaceCharacterIcon(id: "sherlock-gregson", assetName: "WorkspaceCharacterSherlockGregson", nameKey: "ui.workspace_character_sherlock_gregson"),
        WorkspaceCharacterIcon(id: "sherlock-moran", assetName: "WorkspaceCharacterSherlockMoran", nameKey: "ui.workspace_character_sherlock_moran")
    ]

    static let aliceWonderlandCharacters = [
        WorkspaceCharacterIcon(id: "alice-alice", assetName: "WorkspaceCharacterAliceAlice", nameKey: "ui.workspace_character_alice_alice"),
        WorkspaceCharacterIcon(id: "alice-white-rabbit", assetName: "WorkspaceCharacterAliceWhiteRabbit", nameKey: "ui.workspace_character_alice_white_rabbit"),
        WorkspaceCharacterIcon(id: "alice-mad-hatter", assetName: "WorkspaceCharacterAliceMadHatter", nameKey: "ui.workspace_character_alice_mad_hatter"),
        WorkspaceCharacterIcon(id: "alice-cheshire-cat", assetName: "WorkspaceCharacterAliceCheshireCat", nameKey: "ui.workspace_character_alice_cheshire_cat"),
        WorkspaceCharacterIcon(id: "alice-queen-of-hearts", assetName: "WorkspaceCharacterAliceQueenOfHearts", nameKey: "ui.workspace_character_alice_queen_of_hearts"),
        WorkspaceCharacterIcon(id: "alice-king-of-hearts", assetName: "WorkspaceCharacterAliceKingOfHearts", nameKey: "ui.workspace_character_alice_king_of_hearts"),
        WorkspaceCharacterIcon(id: "alice-march-hare", assetName: "WorkspaceCharacterAliceMarchHare", nameKey: "ui.workspace_character_alice_march_hare"),
        WorkspaceCharacterIcon(id: "alice-dormouse", assetName: "WorkspaceCharacterAliceDormouse", nameKey: "ui.workspace_character_alice_dormouse"),
        WorkspaceCharacterIcon(id: "alice-caterpillar", assetName: "WorkspaceCharacterAliceCaterpillar", nameKey: "ui.workspace_character_alice_caterpillar"),
        WorkspaceCharacterIcon(id: "alice-duchess", assetName: "WorkspaceCharacterAliceDuchess", nameKey: "ui.workspace_character_alice_duchess")
    ]

    static let onePieceCharacters = [
        WorkspaceCharacterIcon(id: "one-piece-luffy", assetName: "WorkspaceCharacterOnePieceLuffy", nameKey: "ui.workspace_character_one_piece_luffy"),
        WorkspaceCharacterIcon(id: "one-piece-zoro", assetName: "WorkspaceCharacterOnePieceZoro", nameKey: "ui.workspace_character_one_piece_zoro"),
        WorkspaceCharacterIcon(id: "one-piece-nami", assetName: "WorkspaceCharacterOnePieceNami", nameKey: "ui.workspace_character_one_piece_nami"),
        WorkspaceCharacterIcon(id: "one-piece-usopp", assetName: "WorkspaceCharacterOnePieceUsopp", nameKey: "ui.workspace_character_one_piece_usopp"),
        WorkspaceCharacterIcon(id: "one-piece-sanji", assetName: "WorkspaceCharacterOnePieceSanji", nameKey: "ui.workspace_character_one_piece_sanji"),
        WorkspaceCharacterIcon(id: "one-piece-chopper", assetName: "WorkspaceCharacterOnePieceChopper", nameKey: "ui.workspace_character_one_piece_chopper"),
        WorkspaceCharacterIcon(id: "one-piece-robin", assetName: "WorkspaceCharacterOnePieceRobin", nameKey: "ui.workspace_character_one_piece_robin"),
        WorkspaceCharacterIcon(id: "one-piece-franky", assetName: "WorkspaceCharacterOnePieceFranky", nameKey: "ui.workspace_character_one_piece_franky"),
        WorkspaceCharacterIcon(id: "one-piece-brook", assetName: "WorkspaceCharacterOnePieceBrook", nameKey: "ui.workspace_character_one_piece_brook"),
        WorkspaceCharacterIcon(id: "one-piece-jinbe", assetName: "WorkspaceCharacterOnePieceJinbe", nameKey: "ui.workspace_character_one_piece_jinbe")
    ]

    static let narutoCharacters = [
        WorkspaceCharacterIcon(id: "naruto-naruto", assetName: "WorkspaceCharacterNarutoNaruto", nameKey: "ui.workspace_character_naruto_naruto"),
        WorkspaceCharacterIcon(id: "naruto-sasuke", assetName: "WorkspaceCharacterNarutoSasuke", nameKey: "ui.workspace_character_naruto_sasuke"),
        WorkspaceCharacterIcon(id: "naruto-sakura", assetName: "WorkspaceCharacterNarutoSakura", nameKey: "ui.workspace_character_naruto_sakura"),
        WorkspaceCharacterIcon(id: "naruto-kakashi", assetName: "WorkspaceCharacterNarutoKakashi", nameKey: "ui.workspace_character_naruto_kakashi"),
        WorkspaceCharacterIcon(id: "naruto-hinata", assetName: "WorkspaceCharacterNarutoHinata", nameKey: "ui.workspace_character_naruto_hinata"),
        WorkspaceCharacterIcon(id: "naruto-gaara", assetName: "WorkspaceCharacterNarutoGaara", nameKey: "ui.workspace_character_naruto_gaara"),
        WorkspaceCharacterIcon(id: "naruto-itachi", assetName: "WorkspaceCharacterNarutoItachi", nameKey: "ui.workspace_character_naruto_itachi"),
        WorkspaceCharacterIcon(id: "naruto-jiraiya", assetName: "WorkspaceCharacterNarutoJiraiya", nameKey: "ui.workspace_character_naruto_jiraiya"),
        WorkspaceCharacterIcon(id: "naruto-shikamaru", assetName: "WorkspaceCharacterNarutoShikamaru", nameKey: "ui.workspace_character_naruto_shikamaru"),
        WorkspaceCharacterIcon(id: "naruto-tsunade", assetName: "WorkspaceCharacterNarutoTsunade", nameKey: "ui.workspace_character_naruto_tsunade")
    ]

    static let digimonCharacters = [
        WorkspaceCharacterIcon(id: "digimon-agumon", assetName: "WorkspaceCharacterDigimonAgumon", nameKey: "ui.workspace_character_digimon_agumon"),
        WorkspaceCharacterIcon(id: "digimon-gabumon", assetName: "WorkspaceCharacterDigimonGabumon", nameKey: "ui.workspace_character_digimon_gabumon"),
        WorkspaceCharacterIcon(id: "digimon-patamon", assetName: "WorkspaceCharacterDigimonPatamon", nameKey: "ui.workspace_character_digimon_patamon"),
        WorkspaceCharacterIcon(id: "digimon-gatomon", assetName: "WorkspaceCharacterDigimonGatomon", nameKey: "ui.workspace_character_digimon_gatomon"),
        WorkspaceCharacterIcon(id: "digimon-biyomon", assetName: "WorkspaceCharacterDigimonBiyomon", nameKey: "ui.workspace_character_digimon_biyomon"),
        WorkspaceCharacterIcon(id: "digimon-tentomon", assetName: "WorkspaceCharacterDigimonTentomon", nameKey: "ui.workspace_character_digimon_tentomon"),
        WorkspaceCharacterIcon(id: "digimon-gomamon", assetName: "WorkspaceCharacterDigimonGomamon", nameKey: "ui.workspace_character_digimon_gomamon"),
        WorkspaceCharacterIcon(id: "digimon-palmon", assetName: "WorkspaceCharacterDigimonPalmon", nameKey: "ui.workspace_character_digimon_palmon"),
        WorkspaceCharacterIcon(id: "digimon-veemon", assetName: "WorkspaceCharacterDigimonVeemon", nameKey: "ui.workspace_character_digimon_veemon"),
        WorkspaceCharacterIcon(id: "digimon-guilmon", assetName: "WorkspaceCharacterDigimonGuilmon", nameKey: "ui.workspace_character_digimon_guilmon")
    ]

    /// 经典专辑复用角色图标链路，以保持现有按 style 分桶的持久化和跨页面展示一致。
    static let classicAlbumsCharacters = [
        WorkspaceCharacterIcon(id: "album-dark-side-of-the-moon", assetName: "WorkspaceAlbumDarkSideOfTheMoon", nameKey: "ui.workspace_album_dark_side_of_the_moon"),
        WorkspaceCharacterIcon(id: "album-rumours", assetName: "WorkspaceAlbumRumours", nameKey: "ui.workspace_album_rumours"),
        WorkspaceCharacterIcon(id: "album-atom-heart-mother", assetName: "WorkspaceAlbumAtomHeartMother", nameKey: "ui.workspace_album_atom_heart_mother"),
        WorkspaceCharacterIcon(id: "album-ziggy-stardust", assetName: "WorkspaceAlbumZiggyStardust", nameKey: "ui.workspace_album_ziggy_stardust"),
        WorkspaceCharacterIcon(id: "album-abbey-road", assetName: "WorkspaceAlbumAbbeyRoad", nameKey: "ui.workspace_album_abbey_road"),
        WorkspaceCharacterIcon(id: "album-thriller", assetName: "WorkspaceAlbumThriller", nameKey: "ui.workspace_album_thriller"),
        WorkspaceCharacterIcon(id: "album-morning-glory", assetName: "WorkspaceAlbumMorningGlory", nameKey: "ui.workspace_album_morning_glory"),
        WorkspaceCharacterIcon(id: "album-velvet-underground-nico", assetName: "WorkspaceAlbumVelvetUndergroundNico", nameKey: "ui.workspace_album_velvet_underground_nico"),
        WorkspaceCharacterIcon(id: "album-nevermind", assetName: "WorkspaceAlbumNevermind", nameKey: "ui.workspace_album_nevermind"),
        WorkspaceCharacterIcon(id: "album-ok-computer", assetName: "WorkspaceAlbumOKComputer", nameKey: "ui.workspace_album_ok_computer")
    ]

    /// 世界名画优先使用公共领域馆藏，并预裁成稳定的方形构图，避免圆形与 MeeGo 蒙版
    /// 再次截掉主体；作品来源和公共领域状态记录在 THIRD_PARTY_NOTICES.md。
    static let worldArtCharacters = [
        WorkspaceCharacterIcon(id: "art-van-gogh-self-portrait", assetName: "WorkspaceArtVanGoghSelfPortrait", nameKey: "ui.workspace_art_van_gogh_self_portrait"),
        WorkspaceCharacterIcon(id: "art-great-wave", assetName: "WorkspaceArtGreatWave", nameKey: "ui.workspace_art_great_wave"),
        WorkspaceCharacterIcon(id: "art-manet-boating", assetName: "WorkspaceArtManetBoating", nameKey: "ui.workspace_art_manet_boating"),
        WorkspaceCharacterIcon(id: "art-degas-dancing-class", assetName: "WorkspaceArtDegasDancingClass", nameKey: "ui.workspace_art_degas_dancing_class"),
        WorkspaceCharacterIcon(id: "art-view-of-toledo", assetName: "WorkspaceArtViewOfToledo", nameKey: "ui.workspace_art_view_of_toledo"),
        WorkspaceCharacterIcon(id: "art-death-of-socrates", assetName: "WorkspaceArtDeathOfSocrates", nameKey: "ui.workspace_art_death_of_socrates"),
        WorkspaceCharacterIcon(id: "art-vermeer-water-pitcher", assetName: "WorkspaceArtVermeerWaterPitcher", nameKey: "ui.workspace_art_vermeer_water_pitcher"),
        WorkspaceCharacterIcon(id: "art-madame-x", assetName: "WorkspaceArtMadameX", nameKey: "ui.workspace_art_madame_x"),
        WorkspaceCharacterIcon(id: "art-washington-crossing-delaware", assetName: "WorkspaceArtWashingtonCrossing", nameKey: "ui.workspace_art_washington_crossing_delaware"),
        WorkspaceCharacterIcon(id: "art-springtime", assetName: "WorkspaceArtSpringtime", nameKey: "ui.workspace_art_springtime")
    ]

    static let builtInCharactersByStyle: [WorkspaceIconStyle: [WorkspaceCharacterIcon]] = [
        .journey: builtInCharacters,
        .threeKingdoms: threeKingdomsCharacters,
        .waterMargin: waterMarginCharacters,
        .redChamber: redChamberCharacters,
        .greekMythology: greekMythologyCharacters,
        .sherlockHolmes: sherlockHolmesCharacters,
        .aliceWonderland: aliceWonderlandCharacters,
        .onePiece: onePieceCharacters,
        .naruto: narutoCharacters,
        .digimon: digimonCharacters,
        .classicAlbums: classicAlbumsCharacters,
        .worldArt: worldArtCharacters
    ]

    /// 已发布的专辑 ID 不直接删除：显式选择过旧封面的用户升级后落到同位置的新专辑，
    /// 避免偏好静默失效；下一次主动选择时会自然写入新的规范 ID。
    private static let legacyCharacterIDAliasesByStyle: [WorkspaceIconStyle: [String: String]] = [
        .classicAlbums: [
            "album-wish-you-were-here": "album-rumours",
            "album-sos": "album-ziggy-stardust",
            "album-21": "album-thriller",
            "album-norman-fucking-rockwell": "album-nevermind",
            "album-cities": "album-ok-computer"
        ]
    ]

    private typealias Storage = ProfileScopedStorage<WorkspaceAppearancePreferences>
    private typealias LegacyStorage = ProfileScopedStorage<[String: String]>

    private struct CharacterAssignmentScope: Hashable {
        let profileID: String
        let styleID: String
    }

    @Published private var storage: Storage

    private let defaults: UserDefaults
    private let key: String
    // 自动头像不能只依赖“这一次传进来的项目集合”：项目目录异步补齐时，
    // 碰撞避让会让已经显示的角色突然换人。缓存采用增量分配，单项 fallback
    // 与工作区批量展示共享同一结果，同时继续在角色池足够时避免重复。
    private var automaticCharacterIDsByScope: [CharacterAssignmentScope: [String: String]] = [:]
    private var automaticEmojiByProfile: [String: [String: String]] = [:]

    init(
        defaults: UserDefaults = .standard,
        key: String = "agentd.workspaceAppearancePreferences.v2",
        legacyKey: String = "agentd.workspaceAppearancePreferences.v1"
    ) {
        self.defaults = defaults
        self.key = key

        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else if let legacyData = defaults.data(forKey: legacyKey),
                  let legacy = try? JSONDecoder().decode(LegacyStorage.self, from: legacyData) {
            // v1 的单一字典可能同时残留 Emoji 和新版角色 ID。首次读取时分类复制到 v2，
            // 旧键保持只读，确保升级失败也不会破坏用户原来的选择。
            let migrated = Self.migratedStorage(from: legacy)
            storage = migrated
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: key)
            }
        } else {
            storage = Storage()
        }
    }

    /// endpoint 旧值只在唯一匹配的 Profile 上迁移一次；地址只是路由，不能继续作为偏好主键。
    func migrateLegacyValueIfNeeded(
        profileID: String,
        endpoint: String,
        profiles: [ConnectionProfile]
    ) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        let endpointKey = AgentAPIClient.normalizedEndpoint(endpoint)
        guard !storage.migratedLegacyEndpoints.contains(endpointKey),
              ProfileScopedPersistence.isUniqueEndpointMatch(
                  profileID: profileKey,
                  normalizedEndpoint: endpointKey,
                  profiles: profiles
              ),
              let legacyPreferences = storage.byEndpoint[endpointKey]
        else {
            return
        }

        var preferences = storage.byProfileID[profileKey] ?? WorkspaceAppearancePreferences()
        preferences.mergeMissingValues(from: legacyPreferences)
        storage.byProfileID[profileKey] = preferences
        storage.migratedLegacyEndpoints.insert(endpointKey)
        persist()
    }

    func style(profileID: String) -> WorkspaceIconStyle {
        preferences(profileID: profileID)?.style ?? .journey
    }

    func projectIconContent(profileID: String, projectID: String) -> WorkspaceProjectIconContent {
        let iconStyle = style(profileID: profileID)
        if iconStyle.usesCharacters {
            return .character(
                character(
                    style: iconStyle,
                    profileID: profileID,
                    projectID: projectID
                )
            )
        }
        return .emoji(emoji(profileID: profileID, projectID: projectID))
    }

    /// 与工作区胶囊相同，整组分配后再取单个项目，确保自动头像在发生哈希碰撞时
    /// 仍与工作区页显示一致，而不是只在当前会话列表里重新计算。
    func projectIconContents(
        profileID: String,
        projectIDs: [String]
    ) -> [String: WorkspaceProjectIconContent] {
        let iconStyle = style(profileID: profileID)
        if iconStyle.usesCharacters {
            return characterAssignments(
                style: iconStyle,
                profileID: profileID,
                projectIDs: projectIDs
            ).mapValues { .character($0) }
        }
        return emojiAssignments(
            profileID: profileID,
            projectIDs: projectIDs
        ).mapValues { .emoji($0) }
    }

    func setStyle(_ style: WorkspaceIconStyle, profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var preferences = storage.byProfileID[profileKey] ?? WorkspaceAppearancePreferences()
        guard preferences.style != style else { return }
        preferences.style = style
        storage.byProfileID[profileKey] = preferences
        persist()
    }

    func character(profileID: String, projectID: String) -> WorkspaceCharacterIcon {
        character(
            style: effectiveCharacterStyle(profileID: profileID),
            profileID: profileID,
            projectID: projectID
        )
    }

    func character(
        style: WorkspaceIconStyle,
        profileID: String,
        projectID: String
    ) -> WorkspaceCharacterIcon {
        let pool = Self.characters(for: style)
        guard let fallback = pool.first else {
            return Self.builtInCharacters[0]
        }
        return characterAssignments(
            style: style,
            profileID: profileID,
            projectIDs: [projectID]
        )[projectID] ?? fallback
    }

    /// 为同一 Profile 下的项目增量分配角色。
    ///
    /// 单独对哈希取模无法避免碰撞；这里先保留用户手动选择和已经展示过的自动结果，
    /// 新项目再从稳定哈希起点向后寻找空位。这样目录异步扩张不会洗牌，角色数足够时
    /// 仍不会重复，项目超过角色池容量后才允许复用。
    func characterAssignments(
        profileID: String,
        projectIDs: [String]
    ) -> [String: WorkspaceCharacterIcon] {
        characterAssignments(
            style: effectiveCharacterStyle(profileID: profileID),
            profileID: profileID,
            projectIDs: projectIDs
        )
    }

    func characterAssignments(
        style: WorkspaceIconStyle,
        profileID: String,
        projectIDs: [String]
    ) -> [String: WorkspaceCharacterIcon] {
        let pool = Self.characters(for: style)
        let uniqueProjectIDs = Array(Set(projectIDs)).sorted()
        guard !uniqueProjectIDs.isEmpty, !pool.isEmpty else {
            return [:]
        }

        let scope = CharacterAssignmentScope(
            profileID: assignmentProfileKey(profileID),
            styleID: style.rawValue
        )
        let validCharacterIDs = Set(pool.map(\.id))
        var cachedCharacterIDs = (automaticCharacterIDsByScope[scope] ?? [:])
            .filter { validCharacterIDs.contains($0.value) }
        var assignments: [String: WorkspaceCharacterIcon] = [:]
        var usedCharacterIDs = Set<String>()

        // 显式选择优先。若它占用了旧自动缓存的角色，后者在下次展示时
        // 重新寻找空位；只有用户主动改头像时才允许发生这种可解释的变化。
        for projectID in uniqueProjectIDs {
            guard let customID = customCharacterID(
                style: style,
                profileID: profileID,
                projectID: projectID
            ),
                  let character = Self.character(id: customID, style: style),
                  !usedCharacterIDs.contains(character.id) else {
                continue
            }
            assignments[projectID] = character
            usedCharacterIDs.insert(character.id)
        }

        let customProjectIDs = Set(assignments.keys)
        cachedCharacterIDs = cachedCharacterIDs.filter { projectID, characterID in
            !customProjectIDs.contains(projectID)
                && !usedCharacterIDs.contains(characterID)
        }
        usedCharacterIDs.formUnion(cachedCharacterIDs.values)

        for projectID in uniqueProjectIDs where assignments[projectID] == nil {
            if let cachedID = cachedCharacterIDs[projectID],
               let cachedCharacter = Self.character(id: cachedID, style: style) {
                assignments[projectID] = cachedCharacter
                continue
            }

            let startIndex = defaultCharacterIndex(
                style: style,
                profileID: profileID,
                projectID: projectID
            )
            let availableCharacter = (0..<pool.count)
                .lazy
                .map { pool[(startIndex + $0) % pool.count] }
                .first { !usedCharacterIDs.contains($0.id) }

            let character = availableCharacter ?? pool[startIndex]
            assignments[projectID] = character
            cachedCharacterIDs[projectID] = character.id
            usedCharacterIDs.insert(character.id)
        }

        automaticCharacterIDsByScope[scope] = cachedCharacterIDs
        return assignments
    }

    func customCharacterID(profileID: String, projectID: String) -> String? {
        customCharacterID(
            style: effectiveCharacterStyle(profileID: profileID),
            profileID: profileID,
            projectID: projectID
        )
    }

    func customCharacterID(
        style: WorkspaceIconStyle,
        profileID: String,
        projectID: String
    ) -> String? {
        guard style.usesCharacters,
              let preferences = preferences(profileID: profileID)
        else {
            return nil
        }
        let storedValue: String?
        if style == .journey {
            storedValue = preferences.characterIDsByProject[projectID]
        } else {
            storedValue = preferences.characterIDsByStyleAndProject[style.rawValue]?[projectID]
        }
        guard let storedValue,
              let character = Self.character(id: storedValue, style: style) else {
            return nil
        }
        return character.id
    }

    func defaultCharacterID(profileID: String, projectID: String) -> String {
        defaultCharacterID(
            style: effectiveCharacterStyle(profileID: profileID),
            profileID: profileID,
            projectID: projectID
        )
    }

    func defaultCharacterID(
        style: WorkspaceIconStyle,
        profileID: String,
        projectID: String
    ) -> String {
        let pool = Self.characters(for: style)
        guard !pool.isEmpty else {
            return Self.builtInCharacters[0].id
        }
        return pool[
            defaultCharacterIndex(style: style, profileID: profileID, projectID: projectID)
        ].id
    }

    func setCustomCharacterID(_ characterID: String?, profileID: String, projectID: String) {
        setCustomCharacterID(
            characterID,
            style: effectiveCharacterStyle(profileID: profileID),
            profileID: profileID,
            projectID: projectID
        )
    }

    func setCustomCharacterID(
        _ characterID: String?,
        style: WorkspaceIconStyle,
        profileID: String,
        projectID: String
    ) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var preferences = storage.byProfileID[profileKey] ?? WorkspaceAppearancePreferences()
        guard style.usesCharacters else { return }
        if let characterID {
            guard Self.character(id: characterID, style: style) != nil else { return }
            if style == .journey {
                preferences.characterIDsByProject[projectID] = characterID
            } else {
                var choices = preferences.characterIDsByStyleAndProject[style.rawValue] ?? [:]
                choices[projectID] = characterID
                preferences.characterIDsByStyleAndProject[style.rawValue] = choices
            }
        } else {
            if style == .journey {
                preferences.characterIDsByProject.removeValue(forKey: projectID)
            } else {
                var choices = preferences.characterIDsByStyleAndProject[style.rawValue] ?? [:]
                choices.removeValue(forKey: projectID)
                preferences.characterIDsByStyleAndProject[style.rawValue] =
                    choices.isEmpty ? nil : choices
            }
        }
        let scope = CharacterAssignmentScope(profileID: profileKey, styleID: style.rawValue)
        var cachedCharacterIDs = automaticCharacterIDsByScope[scope] ?? [:]
        cachedCharacterIDs.removeValue(forKey: projectID)
        if let characterID {
            // 用户选择优先于自动占位；只释放发生冲突的项目，避免其它头像一起洗牌。
            cachedCharacterIDs = cachedCharacterIDs.filter { $0.value != characterID }
        }
        automaticCharacterIDsByScope[scope] = cachedCharacterIDs
        save(preferences, profileKey: profileKey)
    }

    func emoji(profileID: String, projectID: String) -> String {
        emojiAssignments(profileID: profileID, projectIDs: [projectID])[projectID]
            ?? Self.builtInEmoji[0]
    }

    func emojiAssignments(profileID: String, projectIDs: [String]) -> [String: String] {
        let uniqueProjectIDs = Array(Set(projectIDs)).sorted()
        guard !uniqueProjectIDs.isEmpty, !Self.builtInEmoji.isEmpty else {
            return [:]
        }

        let profileKey = assignmentProfileKey(profileID)
        let validEmoji = Set(Self.builtInEmoji)
        var cachedEmoji = (automaticEmojiByProfile[profileKey] ?? [:])
            .filter { validEmoji.contains($0.value) }
        var assignments: [String: String] = [:]
        var usedEmoji = Set<String>()

        // 保留不冲突的历史手动选择；旧数据里已经重复的项目回到稳定自动分配。
        for projectID in uniqueProjectIDs {
            guard let custom = customEmoji(profileID: profileID, projectID: projectID),
                  !usedEmoji.contains(custom) else {
                continue
            }
            assignments[projectID] = custom
            usedEmoji.insert(custom)
        }

        let customProjectIDs = Set(assignments.keys)
        cachedEmoji = cachedEmoji.filter { projectID, emoji in
            !customProjectIDs.contains(projectID) && !usedEmoji.contains(emoji)
        }
        usedEmoji.formUnion(cachedEmoji.values)

        for projectID in uniqueProjectIDs where assignments[projectID] == nil {
            if let cached = cachedEmoji[projectID] {
                assignments[projectID] = cached
                continue
            }

            let startIndex = defaultEmojiIndex(profileID: profileID, projectID: projectID)
            let availableEmoji = (0..<Self.builtInEmoji.count)
                .lazy
                .map { Self.builtInEmoji[(startIndex + $0) % Self.builtInEmoji.count] }
                .first { !usedEmoji.contains($0) }
            let emoji = availableEmoji ?? Self.builtInEmoji[startIndex]
            assignments[projectID] = emoji
            cachedEmoji[projectID] = emoji
            usedEmoji.insert(emoji)
        }

        automaticEmojiByProfile[profileKey] = cachedEmoji
        return assignments
    }

    func customEmoji(profileID: String, projectID: String) -> String? {
        guard let storedValue = preferences(profileID: profileID)?.emojiByProject[projectID] else {
            return nil
        }
        return Self.normalizedEmoji(storedValue)
    }

    func defaultEmoji(profileID: String, projectID: String) -> String {
        Self.builtInEmoji[defaultEmojiIndex(profileID: profileID, projectID: projectID)]
    }

    func setCustomEmoji(_ emoji: String?, profileID: String, projectID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var preferences = storage.byProfileID[profileKey] ?? WorkspaceAppearancePreferences()
        if let emoji {
            guard let normalized = Self.normalizedEmoji(emoji) else { return }
            preferences.emojiByProject[projectID] = normalized
        } else {
            preferences.emojiByProject.removeValue(forKey: projectID)
        }
        var cachedEmoji = automaticEmojiByProfile[profileKey] ?? [:]
        cachedEmoji.removeValue(forKey: projectID)
        if let emoji = preferences.emojiByProject[projectID] {
            cachedEmoji = cachedEmoji.filter { $0.value != emoji }
        }
        automaticEmojiByProfile[profileKey] = cachedEmoji
        save(preferences, profileKey: profileKey)
    }

    /// 同一路径的旧 workspace ID 被稳定 ID 替代时迁移本机自定义头像。
    ///
    /// 新 ID 上已经存在的明确选择优先；否则复制旧 ID 的选择，随后删除旧键。
    /// 自动分配值不落盘，但进程内缓存需要跟随稳定 ID，避免同一路径换 ID 时闪变。
    func migrateProjectIdentity(
        profileID: String,
        from oldProjectID: String,
        to newProjectID: String
    ) {
        guard oldProjectID != newProjectID,
              let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID)
        else {
            return
        }

        for scope in Array(automaticCharacterIDsByScope.keys) where scope.profileID == profileKey {
            var assignments = automaticCharacterIDsByScope[scope] ?? [:]
            if assignments[newProjectID] == nil {
                assignments[newProjectID] = assignments[oldProjectID]
            }
            assignments.removeValue(forKey: oldProjectID)
            automaticCharacterIDsByScope[scope] = assignments
        }
        var emojiAssignments = automaticEmojiByProfile[profileKey] ?? [:]
        if emojiAssignments[newProjectID] == nil {
            emojiAssignments[newProjectID] = emojiAssignments[oldProjectID]
        }
        emojiAssignments.removeValue(forKey: oldProjectID)
        automaticEmojiByProfile[profileKey] = emojiAssignments

        guard var preferences = storage.byProfileID[profileKey] else {
            return
        }

        if preferences.characterIDsByProject[newProjectID] == nil {
            preferences.characterIDsByProject[newProjectID] =
                preferences.characterIDsByProject[oldProjectID]
        }
        preferences.characterIDsByProject.removeValue(forKey: oldProjectID)

        if preferences.emojiByProject[newProjectID] == nil {
            preferences.emojiByProject[newProjectID] = preferences.emojiByProject[oldProjectID]
        }
        preferences.emojiByProject.removeValue(forKey: oldProjectID)

        for styleID in Array(preferences.characterIDsByStyleAndProject.keys) {
            var choices = preferences.characterIDsByStyleAndProject[styleID] ?? [:]
            if choices[newProjectID] == nil {
                choices[newProjectID] = choices[oldProjectID]
            }
            choices.removeValue(forKey: oldProjectID)
            preferences.characterIDsByStyleAndProject[styleID] =
                choices.isEmpty ? nil : choices
        }
        save(preferences, profileKey: profileKey)
    }

    func remove(profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        automaticCharacterIDsByScope = automaticCharacterIDsByScope.filter {
            $0.key.profileID != profileKey
        }
        automaticEmojiByProfile.removeValue(forKey: profileKey)
        if storage.byProfileID.removeValue(forKey: profileKey) != nil {
            persist()
        }
    }

    static func characters(for style: WorkspaceIconStyle) -> [WorkspaceCharacterIcon] {
        builtInCharactersByStyle[style] ?? []
    }

    static func character(id: String, style: WorkspaceIconStyle) -> WorkspaceCharacterIcon? {
        let canonicalID = legacyCharacterIDAliasesByStyle[style]?[id] ?? id
        return characters(for: style).first { $0.id == canonicalID }
    }

    static func character(id: String) -> WorkspaceCharacterIcon? {
        builtInCharactersByStyle.values.lazy
            .flatMap { $0 }
            .first { $0.id == id }
    }

    static func normalizedEmoji(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 1 else { return nil }

        let scalars = Array(value.unicodeScalars)
        let hasPresentationEmoji = scalars.contains { $0.properties.isEmojiPresentation }
        let hasEmojiWithPresentationSelector = scalars.contains { $0.properties.isEmoji }
            && scalars.contains { $0.value == 0xFE0F }
        guard hasPresentationEmoji || hasEmojiWithPresentationSelector else {
            return nil
        }
        return value
    }

    static func tintIndex(for emoji: String, count: Int) -> Int {
        stableIndex(for: emoji, count: count)
    }

    private func preferences(profileID: String) -> WorkspaceAppearancePreferences? {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return nil
        }
        return storage.byProfileID[profileKey]
    }

    private func effectiveCharacterStyle(profileID: String) -> WorkspaceIconStyle {
        let selectedStyle = style(profileID: profileID)
        return selectedStyle.usesCharacters ? selectedStyle : .journey
    }

    private func defaultCharacterIndex(
        style: WorkspaceIconStyle,
        profileID: String,
        projectID: String
    ) -> Int {
        Self.stableIndex(
            for: stableIdentity(profileID: profileID, projectID: projectID),
            count: Self.characters(for: style).count
        )
    }

    private func defaultEmojiIndex(profileID: String, projectID: String) -> Int {
        Self.stableIndex(
            for: stableIdentity(profileID: profileID, projectID: projectID),
            count: Self.builtInEmoji.count
        )
    }

    private func stableIdentity(profileID: String, projectID: String) -> String {
        let profileKey = assignmentProfileKey(profileID)
        return "\(profileKey)\n\(projectID)"
    }

    private func assignmentProfileKey(_ profileID: String) -> String {
        ProfileScopedPersistence.normalizedProfileID(profileID) ?? "legacy"
    }

    private func save(_ preferences: WorkspaceAppearancePreferences, profileKey: String) {
        if preferences.isEmpty {
            storage.byProfileID.removeValue(forKey: profileKey)
        } else {
            storage.byProfileID[profileKey] = preferences
        }
        persist()
    }

    private static func migratedStorage(from legacy: LegacyStorage) -> Storage {
        var migrated = Storage()
        migrated.byEndpoint = legacy.byEndpoint.mapValues(migratedPreferences)
        migrated.byProfileID = legacy.byProfileID.mapValues(migratedPreferences)
        migrated.migratedLegacyEndpoints = legacy.migratedLegacyEndpoints
        return migrated
    }

    private static func migratedPreferences(
        from legacyValues: [String: String]
    ) -> WorkspaceAppearancePreferences {
        var preferences = WorkspaceAppearancePreferences()
        for (projectID, value) in legacyValues {
            if character(id: value, style: .journey) != nil {
                preferences.characterIDsByProject[projectID] = value
            } else if let emoji = normalizedEmoji(value) {
                preferences.emojiByProject[projectID] = emoji
            }
        }

        // 兼容老用户优先：只要存在历史 Emoji 就继续展示 Emoji；完全没有历史选择时
        // style 保持 nil，由读取逻辑使用《西游记》作为新用户默认值。
        if !preferences.emojiByProject.isEmpty {
            preferences.style = .emoji
        } else if !preferences.characterIDsByProject.isEmpty {
            preferences.style = .journey
        }
        return preferences
    }

    private static func stableIndex(for value: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let digest = SHA256.hash(data: Data(value.utf8))
        var prefix: UInt64 = 0
        for byte in digest.prefix(8) {
            prefix = (prefix << 8) | UInt64(byte)
        }
        return Int(prefix % UInt64(count))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: key)
    }
}
