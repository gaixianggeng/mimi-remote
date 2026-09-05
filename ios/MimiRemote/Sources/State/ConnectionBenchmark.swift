import Foundation

enum ConnectionBenchmarkScenario: String, CaseIterable, Codable, Identifiable {
    case cold
    case warm
    case networkRecovery = "network_recovery"

    var id: String { rawValue }
}

enum ConnectionBenchmarkPath: String, Codable, Equatable {
    case direct
    case peerRelay = "peer_relay"
    case derp
    case unknown
}

enum ConnectionBenchmarkPreparation: String, Codable, Equatable {
    case tailcatControlledRestart = "tailcat_controlled_restart"
    case tailcatReusedClient = "tailcat_reused_client"
    case tailscaleSystemManaged = "tailscale_system_managed"
}

enum ConnectionBenchmarkEndpointCandidate: String, Codable, Equatable {
    case localProxy = "local_proxy"
    case magicDNS = "magic_dns"
    case ipAddress = "ip_address"
    case unknown
}

struct ConnectionBenchmarkStage: Codable, Equatable {
    let kind: String
    let durationMillis: Int
    let succeeded: Bool
}

struct ConnectionBenchmarkSample: Codable, Equatable, Identifiable {
    let id: UUID
    let recordedAt: Date
    let route: ConnectionTestRoute
    let scenario: ConnectionBenchmarkScenario
    let preparation: ConnectionBenchmarkPreparation
    let preparationMillis: Int?
    let endpointCandidate: ConnectionBenchmarkEndpointCandidate
    let path: ConnectionBenchmarkPath
    let relayRegion: String?
    let pathProbeMillis: Int?
    let applicationMillis: Int
    let endToEndMillis: Int
    let stages: [ConnectionBenchmarkStage]
    let succeeded: Bool
    let failureStage: String?
    let recoverySucceeded: Bool?

    static func make(
        route: ConnectionTestRoute,
        scenario: ConnectionBenchmarkScenario,
        endpoint: String,
        report: ConnectionTestReport?,
        tailcatDiagnostic: TailcatPathDiagnostic?,
        preparation: ConnectionBenchmarkPreparation,
        preparationMillis: Int?,
        preparationSucceeded: Bool,
        recordedAt: Date = Date(),
        id: UUID = UUID()
    ) -> ConnectionBenchmarkSample {
        let pathEvidence = pathEvidence(
            route: route,
            report: report,
            tailcatDiagnostic: tailcatDiagnostic
        )
        let stages = report?.stages.map {
            ConnectionBenchmarkStage(
                kind: $0.kind.rawValue,
                durationMillis: max(0, $0.durationMillis),
                succeeded: !$0.status.isFailed
            )
        } ?? []
        let applicationMillis = max(0, report?.totalMillis ?? 0)
        let preparationDuration = max(0, preparationMillis ?? 0)
        let reportSucceeded = report.map { $0.failedStage == nil } ?? false
        let succeeded = preparationSucceeded && reportSucceeded
        let failureStage: String?
        if !preparationSucceeded {
            failureStage = "route_preparation"
        } else {
            failureStage = report?.failedStage?.kind.rawValue ?? (report == nil ? "connection_test" : nil)
        }

        return ConnectionBenchmarkSample(
            id: id,
            recordedAt: recordedAt,
            route: route,
            scenario: scenario,
            preparation: preparation,
            preparationMillis: preparationMillis.map { max(0, $0) },
            endpointCandidate: endpointCandidate(route: route, endpoint: endpoint),
            path: pathEvidence.path,
            relayRegion: sanitizedRegion(pathEvidence.region),
            pathProbeMillis: pathEvidence.probeMillis.map { max(0, $0) },
            applicationMillis: applicationMillis,
            endToEndMillis: preparationDuration + applicationMillis,
            stages: stages,
            succeeded: succeeded,
            failureStage: failureStage,
            recoverySucceeded: scenario == .networkRecovery ? succeeded : nil
        )
    }

    private static func pathEvidence(
        route: ConnectionTestRoute,
        report: ConnectionTestReport?,
        tailcatDiagnostic: TailcatPathDiagnostic?
    ) -> (path: ConnectionBenchmarkPath, region: String?, probeMillis: Int?) {
        switch route {
        case .tailscale:
            guard let networkPath = report?.tailscaleNetworkPath else {
                return (.unknown, nil, nil)
            }
            let path: ConnectionBenchmarkPath
            switch networkPath.kind {
            case .direct:
                path = .direct
            case .peerRelay:
                path = .peerRelay
            case .derp:
                path = .derp
            case .notTailscale, .unknown, .unavailable:
                path = .unknown
            }
            return (path, networkPath.relayRegion, nil)
        case .tailcat:
            guard let diagnostic = tailcatDiagnostic, diagnostic.succeeded else {
                return (.unknown, nil, nil)
            }
            let path: ConnectionBenchmarkPath
            switch diagnostic.path {
            case "direct":
                path = .direct
            case "peer-relay", "peer_relay":
                path = .peerRelay
            case "derp":
                path = .derp
            default:
                path = .unknown
            }
            return (path, diagnostic.derpRegionCode, diagnostic.latencyMillis)
        }
    }

    private static func endpointCandidate(
        route: ConnectionTestRoute,
        endpoint: String
    ) -> ConnectionBenchmarkEndpointCandidate {
        if route == .tailcat {
            return .localProxy
        }
        guard let host = URLComponents(string: endpoint)?.host?.lowercased(), !host.isEmpty else {
            return .unknown
        }
        let ipv4Like = host.split(separator: ".").count == 4 && host.allSatisfy {
            $0.isNumber || $0 == "."
        }
        if ipv4Like || host.contains(":") {
            return .ipAddress
        }
        return .magicDNS
    }

    private static func sanitizedRegion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !trimmed.isEmpty,
              trimmed.count <= 16,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return trimmed
    }
}

struct ConnectionBenchmarkStatistics: Codable, Equatable {
    let route: ConnectionTestRoute
    let scenario: ConnectionBenchmarkScenario
    let path: ConnectionBenchmarkPath?
    let relayRegion: String?
    let sampleCount: Int
    let successCount: Int
    let medianMillis: Int?
    let p95Millis: Int?
    let failureRate: Double
    let recoverySuccessRate: Double?

    static func make(
        samples: [ConnectionBenchmarkSample],
        route: ConnectionTestRoute,
        scenario: ConnectionBenchmarkScenario,
        path: ConnectionBenchmarkPath? = nil,
        relayRegion: String? = nil
    ) -> ConnectionBenchmarkStatistics {
        let filtered = samples.filter { sample in
            guard sample.route == route, sample.scenario == scenario else { return false }
            if let path, sample.path != path { return false }
            if let relayRegion, sample.relayRegion != relayRegion { return false }
            return true
        }
        let successfulDurations = filtered
            .filter(\.succeeded)
            .map(\.endToEndMillis)
            .sorted()
        let recoveryResults = filtered.compactMap(\.recoverySucceeded)
        return ConnectionBenchmarkStatistics(
            route: route,
            scenario: scenario,
            path: path,
            relayRegion: relayRegion,
            sampleCount: filtered.count,
            successCount: successfulDurations.count,
            medianMillis: median(successfulDurations),
            p95Millis: percentile(successfulDurations, percentile: 0.95),
            failureRate: filtered.isEmpty
                ? 0
                : Double(filtered.count - successfulDurations.count) / Double(filtered.count),
            recoverySuccessRate: recoveryResults.isEmpty
                ? nil
                : Double(recoveryResults.filter { $0 }.count) / Double(recoveryResults.count)
        )
    }

    private static func percentile(_ sortedValues: [Int], percentile: Double) -> Int? {
        guard !sortedValues.isEmpty else { return nil }
        // 使用 nearest-rank，确保小样本和导出后的离线复算口径一致。
        let rank = max(1, Int(ceil(percentile * Double(sortedValues.count))))
        return sortedValues[min(sortedValues.count - 1, rank - 1)]
    }

    private static func median(_ sortedValues: [Int]) -> Int? {
        guard !sortedValues.isEmpty else { return nil }
        let upperIndex = sortedValues.count / 2
        guard sortedValues.count.isMultiple(of: 2) else {
            return sortedValues[upperIndex]
        }
        let lower = sortedValues[upperIndex - 1]
        let upper = sortedValues[upperIndex]
        return lower + (upper - lower) / 2
    }
}

struct ConnectionBenchmarkMatchedPath: Codable, Equatable, Identifiable {
    let scenario: ConnectionBenchmarkScenario
    let path: ConnectionBenchmarkPath
    let relayRegion: String?
    let tailcat: ConnectionBenchmarkStatistics
    let tailscale: ConnectionBenchmarkStatistics

    var id: String {
        [scenario.rawValue, path.rawValue, relayRegion ?? "none"].joined(separator: ":")
    }
}

struct ConnectionBenchmarkDataset: Codable, Equatable {
    static let targetSampleCount = 20
    static let storageKey = "connection_benchmark_dataset_v1"

    let id: UUID
    let createdAt: Date
    private(set) var samples: [ConnectionBenchmarkSample]

    init(id: UUID = UUID(), createdAt: Date = Date(), samples: [ConnectionBenchmarkSample] = []) {
        self.id = id
        self.createdAt = createdAt
        self.samples = samples
    }

    mutating func append(_ sample: ConnectionBenchmarkSample) {
        samples.append(sample)
    }

    func sampleCount(route: ConnectionTestRoute, scenario: ConnectionBenchmarkScenario) -> Int {
        samples.filter { $0.route == route && $0.scenario == scenario }.count
    }

    func statistics(
        route: ConnectionTestRoute,
        scenario: ConnectionBenchmarkScenario
    ) -> ConnectionBenchmarkStatistics {
        ConnectionBenchmarkStatistics.make(samples: samples, route: route, scenario: scenario)
    }

    var matchedPaths: [ConnectionBenchmarkMatchedPath] {
        var keys = Set<MatchedPathKey>()
        for sample in samples where sample.path == .direct || sample.path == .derp {
            guard sample.path != .derp || sample.relayRegion != nil else { continue }
            keys.insert(MatchedPathKey(
                scenario: sample.scenario,
                path: sample.path,
                relayRegion: sample.path == .derp ? sample.relayRegion : nil
            ))
        }
        return keys.compactMap { key in
            let tailcat = ConnectionBenchmarkStatistics.make(
                samples: samples,
                route: .tailcat,
                scenario: key.scenario,
                path: key.path,
                relayRegion: key.relayRegion
            )
            let tailscale = ConnectionBenchmarkStatistics.make(
                samples: samples,
                route: .tailscale,
                scenario: key.scenario,
                path: key.path,
                relayRegion: key.relayRegion
            )
            guard tailcat.sampleCount > 0, tailscale.sampleCount > 0 else { return nil }
            return ConnectionBenchmarkMatchedPath(
                scenario: key.scenario,
                path: key.path,
                relayRegion: key.relayRegion,
                tailcat: tailcat,
                tailscale: tailscale
            )
        }.sorted { $0.id < $1.id }
    }

    func encodedExport(
        generatedAt: Date = Date(),
        appVersion: String,
        osVersion: String
    ) throws -> Data {
        let aggregate = ConnectionTestRoute.allCases.flatMap { route in
            ConnectionBenchmarkScenario.allCases.map { scenario in
                statistics(route: route, scenario: scenario)
            }
        }
        let payload = ConnectionBenchmarkExport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            appVersion: appVersion,
            osVersion: osVersion,
            datasetID: id,
            datasetCreatedAt: createdAt,
            targetSamplesPerRouteAndScenario: Self.targetSampleCount,
            samples: samples,
            aggregate: aggregate,
            matchedPaths: matchedPaths
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    static func load(defaults: UserDefaults = .standard) -> ConnectionBenchmarkDataset {
        guard let data = defaults.data(forKey: storageKey),
              let dataset = try? JSONDecoder().decode(ConnectionBenchmarkDataset.self, from: data)
        else {
            return ConnectionBenchmarkDataset()
        }
        return dataset
    }

    func persist(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func clear(defaults: UserDefaults = .standard) -> ConnectionBenchmarkDataset {
        defaults.removeObject(forKey: storageKey)
        return ConnectionBenchmarkDataset()
    }

    private struct MatchedPathKey: Hashable {
        let scenario: ConnectionBenchmarkScenario
        let path: ConnectionBenchmarkPath
        let relayRegion: String?
    }
}

private struct ConnectionBenchmarkExport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let appVersion: String
    let osVersion: String
    let datasetID: UUID
    let datasetCreatedAt: Date
    let targetSamplesPerRouteAndScenario: Int
    let samples: [ConnectionBenchmarkSample]
    let aggregate: [ConnectionBenchmarkStatistics]
    let matchedPaths: [ConnectionBenchmarkMatchedPath]
}
