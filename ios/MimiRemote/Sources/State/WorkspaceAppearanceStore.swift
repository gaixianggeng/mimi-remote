import Combine
import CryptoKit
import Foundation

enum WorkspaceIconStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case journey
    case threeKingdoms
    case waterMargin
    case abstractGeometry
    case classicCharacters
    case redChamber
    case greekMythology
    case sherlockHolmes
    case aliceWonderland
    case onePiece
    case naruto
    case digimon
    case solarSystem
    case classicAlbums
    case worldArt
    case emoji

    var id: String { rawValue }

    /// 默认只展示当前主推风格；已下架风格继续保留枚举与数据，避免破坏历史选择。
    static let visibleStyles: [WorkspaceIconStyle] = [
        .journey,
        .threeKingdoms,
        .classicCharacters,
        .redChamber,
        .onePiece,
        .naruto,
        .worldArt,
        .emoji
    ]

    static func selectableStyles(currentStyle: WorkspaceIconStyle) -> [WorkspaceIconStyle] {
        let currentStyle = currentStyle.availableStyle
        guard !visibleStyles.contains(currentStyle) else {
            return visibleStyles
        }
        // 历史用户仍能看到当前已选风格；切换后，下架风格自然从选择器消失。
        return visibleStyles + [currentStyle]
    }

    /// 已下架风格保留 raw value 只为解码旧偏好。读取和写入时直接落到对应替代主题，
    /// 避免升级后选中不存在的素材；旧角色 ID 不复用，新主题会稳定分配自己的默认图标。
    var availableStyle: WorkspaceIconStyle {
        switch self {
        case .waterMargin, .abstractGeometry, .digimon, .solarSystem:
            return .classicCharacters
        case .classicAlbums:
            return .worldArt
        default:
            return self
        }
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
        case .abstractGeometry:
            return "ui.workspace_icon_style_abstract_geometry"
        case .classicCharacters:
            return "ui.workspace_icon_style_classic_characters"
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
        case .solarSystem:
            return "ui.workspace_icon_style_solar_system"
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
        case .abstractGeometry:
            return "ui.workspace_icon_style_compact_abstract_geometry"
        case .classicCharacters:
            return "ui.workspace_icon_style_compact_classic_characters"
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
        case .solarSystem:
            return "ui.workspace_icon_style_compact_solar_system"
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
            return nil
        case .abstractGeometry:
            return nil
        case .classicCharacters:
            return "WorkspaceCharacterClassicGoku"
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
            return nil
        case .solarSystem:
            return nil
        case .classicAlbums:
            return nil
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
        style = try container.decodeIfPresent(WorkspaceIconStyle.self, forKey: .style)?.availableStyle
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
            style = legacy.style?.availableStyle
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

    /// 七龙珠人物使用统一的编辑插画语法：粗手绘线、暖灰底和胸像裁切；
    /// 同时保留发型、服装与标志性配件，确保在工作区小头像里仍能一眼识别。
    /// 保留 `classicCharacters` 持久化标识，避免已选择该主题的用户升级后丢失偏好。
    static let classicCharacterIcons = [
        WorkspaceCharacterIcon(id: "classic-goku", assetName: "WorkspaceCharacterClassicGoku", nameKey: "ui.workspace_character_classic_goku"),
        WorkspaceCharacterIcon(id: "classic-vegeta", assetName: "WorkspaceCharacterClassicVegeta", nameKey: "ui.workspace_character_classic_vegeta"),
        WorkspaceCharacterIcon(id: "classic-piccolo", assetName: "WorkspaceCharacterClassicPiccolo", nameKey: "ui.workspace_character_classic_piccolo"),
        WorkspaceCharacterIcon(id: "classic-master-roshi", assetName: "WorkspaceCharacterClassicMasterRoshi", nameKey: "ui.workspace_character_classic_master_roshi"),
        WorkspaceCharacterIcon(id: "classic-krillin", assetName: "WorkspaceCharacterClassicKrillin", nameKey: "ui.workspace_character_classic_krillin"),
        WorkspaceCharacterIcon(id: "classic-frieza", assetName: "WorkspaceCharacterClassicFrieza", nameKey: "ui.workspace_character_classic_frieza"),
        WorkspaceCharacterIcon(id: "classic-majin-buu", assetName: "WorkspaceCharacterClassicMajinBuu", nameKey: "ui.workspace_character_classic_majin_buu"),
        WorkspaceCharacterIcon(id: "classic-future-trunks", assetName: "WorkspaceCharacterClassicFutureTrunks", nameKey: "ui.workspace_character_classic_future_trunks"),
        WorkspaceCharacterIcon(id: "classic-android-18", assetName: "WorkspaceCharacterClassicAndroid18", nameKey: "ui.workspace_character_classic_android_18"),
        WorkspaceCharacterIcon(id: "classic-perfect-cell", assetName: "WorkspaceCharacterClassicPerfectCell", nameKey: "ui.workspace_character_classic_perfect_cell")
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

    /// “画作”主题优先使用公共领域馆藏，并预裁成稳定的方形构图，避免圆形与 MeeGo 蒙版
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
        .classicCharacters: classicCharacterIcons,
        .redChamber: redChamberCharacters,
        .greekMythology: greekMythologyCharacters,
        .sherlockHolmes: sherlockHolmesCharacters,
        .aliceWonderland: aliceWonderlandCharacters,
        .onePiece: onePieceCharacters,
        .naruto: narutoCharacters,
        .worldArt: worldArtCharacters
    ]

    private typealias Storage = ProfileScopedStorage<WorkspaceAppearancePreferences>
    private typealias LegacyStorage = ProfileScopedStorage<[String: String]>

    @Published private var storage: Storage

    private let defaults: UserDefaults
    private let key: String

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
        (preferences(profileID: profileID)?.style ?? .journey).availableStyle
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

    /// 与工作区胶囊使用同一份有序项目列表，确保各页面采用相同的固定图标顺序。
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
        let style = style.availableStyle
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

    /// 按项目目录中的展示位置分配角色。角色池本身按主题中的产品顺序排列，
    /// 因此第一个项目始终使用第一位角色，超过角色数量后再从头循环。
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
        let orderedProjectIDs = Self.orderedUniqueProjectIDs(projectIDs)
        guard !orderedProjectIDs.isEmpty, !pool.isEmpty else {
            return [:]
        }

        var assignments: [String: WorkspaceCharacterIcon] = [:]
        assignments.reserveCapacity(orderedProjectIDs.count)
        for (index, projectID) in orderedProjectIDs.enumerated() {
            if let customID = customCharacterID(
                style: style,
                profileID: profileID,
                projectID: projectID
            ),
               let character = Self.character(id: customID, style: style) {
                // 手动选择只覆盖当前项目，不改变其他项目按位置得到的角色。
                assignments[projectID] = character
            } else {
                assignments[projectID] = pool[index % pool.count]
            }
        }

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
        profileID _: String,
        projectID _: String
    ) -> String {
        let pool = Self.characters(for: style)
        guard !pool.isEmpty else {
            return Self.builtInCharacters[0].id
        }
        return pool[0].id
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
        save(preferences, profileKey: profileKey)
    }

    func emoji(profileID: String, projectID: String) -> String {
        emojiAssignments(profileID: profileID, projectIDs: [projectID])[projectID]
            ?? Self.builtInEmoji[0]
    }

    func emojiAssignments(profileID: String, projectIDs: [String]) -> [String: String] {
        let orderedProjectIDs = Self.orderedUniqueProjectIDs(projectIDs)
        guard !orderedProjectIDs.isEmpty, !Self.builtInEmoji.isEmpty else {
            return [:]
        }

        var assignments: [String: String] = [:]
        assignments.reserveCapacity(orderedProjectIDs.count)
        for (index, projectID) in orderedProjectIDs.enumerated() {
            assignments[projectID] = customEmoji(profileID: profileID, projectID: projectID)
                ?? Self.builtInEmoji[index % Self.builtInEmoji.count]
        }

        return assignments
    }

    func customEmoji(profileID: String, projectID: String) -> String? {
        guard let storedValue = preferences(profileID: profileID)?.emojiByProject[projectID] else {
            return nil
        }
        return Self.normalizedEmoji(storedValue)
    }

    func defaultEmoji(profileID _: String, projectID _: String) -> String {
        Self.builtInEmoji[0]
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
        save(preferences, profileKey: profileKey)
    }

    /// 同一路径的旧 workspace ID 被稳定 ID 替代时迁移本机自定义头像。
    ///
    /// 新 ID 上已经存在的明确选择优先；否则复制旧 ID 的选择，随后删除旧键。
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
        if storage.byProfileID.removeValue(forKey: profileKey) != nil {
            persist()
        }
    }

    static func characters(for style: WorkspaceIconStyle) -> [WorkspaceCharacterIcon] {
        builtInCharactersByStyle[style] ?? []
    }

    static func character(id: String, style: WorkspaceIconStyle) -> WorkspaceCharacterIcon? {
        characters(for: style).first { $0.id == id }
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

    private static func orderedUniqueProjectIDs(_ projectIDs: [String]) -> [String] {
        var seen = Set<String>()
        return projectIDs.filter { seen.insert($0).inserted }
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
