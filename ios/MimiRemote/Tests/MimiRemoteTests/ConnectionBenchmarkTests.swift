import XCTest
@testable import MimiRemote

final class ConnectionBenchmarkTests: XCTestCase {
    func testSampleSeparatesControlledTailcatPreparationFromApplicationStages() {
        let report = makeReport(route: .tailcat, totalMillis: 600)
        let diagnostic = TailcatPathDiagnostic(
            id: UUID(),
            checkedAt: Date(timeIntervalSince1970: 10),
            path: "derp",
            latencyMillis: 72,
            derpRegionCode: "tok",
            succeeded: true,
            requestLatencyMillis: nil,
            requestSucceeded: nil
        )

        let sample = ConnectionBenchmarkSample.make(
            route: .tailcat,
            scenario: .cold,
            endpoint: "http://127.0.0.1:49152",
            report: report,
            tailcatDiagnostic: diagnostic,
            preparation: .tailcatControlledRestart,
            preparationMillis: 400,
            preparationSucceeded: true
        )

        XCTAssertEqual(sample.endpointCandidate, .localProxy)
        XCTAssertEqual(sample.path, .derp)
        XCTAssertEqual(sample.relayRegion, "TOK")
        XCTAssertEqual(sample.pathProbeMillis, 72)
        XCTAssertEqual(sample.applicationMillis, 600)
        XCTAssertEqual(sample.endToEndMillis, 1_000)
        XCTAssertTrue(sample.succeeded)
        XCTAssertNil(sample.failureStage)
    }

    func testTailscaleSampleRecordsCandidateClassWithoutEndpoint() throws {
        let networkPath = try decodeNetworkPath(kind: "direct", region: nil)
        let report = makeReport(
            route: .tailscale,
            totalMillis: 300,
            tailscaleNetworkPath: networkPath
        )

        let magicDNSSample = ConnectionBenchmarkSample.make(
            route: .tailscale,
            scenario: .cold,
            endpoint: "https://macbook.example.ts.net:8787",
            report: report,
            tailcatDiagnostic: nil,
            preparation: .tailscaleSystemManaged,
            preparationMillis: nil,
            preparationSucceeded: true
        )
        let ipSample = ConnectionBenchmarkSample.make(
            route: .tailscale,
            scenario: .warm,
            endpoint: "https://100.101.102.103:8787",
            report: report,
            tailcatDiagnostic: nil,
            preparation: .tailscaleSystemManaged,
            preparationMillis: nil,
            preparationSucceeded: true
        )

        XCTAssertEqual(magicDNSSample.endpointCandidate, .magicDNS)
        XCTAssertEqual(ipSample.endpointCandidate, .ipAddress)
        XCTAssertEqual(magicDNSSample.path, .direct)
    }

    func testPreparationFailureProducesARecordWithoutRawError() {
        let sample = ConnectionBenchmarkSample.make(
            route: .tailcat,
            scenario: .cold,
            endpoint: "http://127.0.0.1:49152",
            report: nil,
            tailcatDiagnostic: nil,
            preparation: .tailcatControlledRestart,
            preparationMillis: 250,
            preparationSucceeded: false
        )

        XCTAssertFalse(sample.succeeded)
        XCTAssertEqual(sample.failureStage, "route_preparation")
        XCTAssertEqual(sample.endToEndMillis, 250)
        XCTAssertEqual(sample.path, .unknown)
    }

    func testStatisticsUseSuccessfulSamplesForNearestRankLatency() {
        var samples = (1...20).map { index in
            makeSample(
                route: .tailcat,
                scenario: .warm,
                path: .direct,
                milliseconds: index * 100,
                succeeded: true
            )
        }
        samples.append(makeSample(
            route: .tailcat,
            scenario: .warm,
            path: .unknown,
            milliseconds: 9_999,
            succeeded: false
        ))

        let statistics = ConnectionBenchmarkStatistics.make(
            samples: samples,
            route: .tailcat,
            scenario: .warm
        )

        XCTAssertEqual(statistics.sampleCount, 21)
        XCTAssertEqual(statistics.successCount, 20)
        XCTAssertEqual(statistics.medianMillis, 1_000)
        XCTAssertEqual(statistics.p95Millis, 1_900)
        XCTAssertEqual(statistics.failureRate, 1.0 / 21.0, accuracy: 0.000_001)
    }

    func testRecoveryRateUsesOnlyRecoverySamples() throws {
        let samples = [
            makeSample(route: .tailcat, scenario: .networkRecovery, path: .direct, milliseconds: 500, succeeded: true),
            makeSample(route: .tailcat, scenario: .networkRecovery, path: .unknown, milliseconds: 1_000, succeeded: false),
            makeSample(route: .tailcat, scenario: .networkRecovery, path: .derp, milliseconds: 700, succeeded: true)
        ]

        let statistics = ConnectionBenchmarkStatistics.make(
            samples: samples,
            route: .tailcat,
            scenario: .networkRecovery
        )

        XCTAssertEqual(try XCTUnwrap(statistics.recoverySuccessRate), 2.0 / 3.0, accuracy: 0.000_001)
    }

    func testMatchedPathsRequireBothRoutesAndSameDERPRegion() {
        let samples = [
            makeSample(route: .tailcat, scenario: .warm, path: .direct, milliseconds: 100, succeeded: true),
            makeSample(route: .tailscale, scenario: .warm, path: .direct, milliseconds: 200, succeeded: true),
            makeSample(route: .tailcat, scenario: .cold, path: .derp, region: "TOK", milliseconds: 300, succeeded: true),
            makeSample(route: .tailscale, scenario: .cold, path: .derp, region: "SFO", milliseconds: 400, succeeded: true)
        ]
        var dataset = ConnectionBenchmarkDataset(samples: samples)

        XCTAssertEqual(dataset.matchedPaths.count, 1)
        XCTAssertEqual(dataset.matchedPaths.first?.path, .direct)

        dataset.append(makeSample(
            route: .tailscale,
            scenario: .cold,
            path: .derp,
            region: "TOK",
            milliseconds: 350,
            succeeded: true
        ))
        XCTAssertEqual(dataset.matchedPaths.count, 2)
        XCTAssertEqual(dataset.matchedPaths.first(where: { $0.path == .derp })?.relayRegion, "TOK")
    }

    func testExportContainsOnlyWhitelistedEvidence() throws {
        let secretEndpoint = "https://100.101.102.103:8787"
        let secretError = "token=do-not-export"
        let report = ConnectionTestReport(
            route: .tailscale,
            startedAt: Date(timeIntervalSince1970: 1),
            totalMillis: 123,
            stages: [
                ConnectionTestStageTiming(
                    kind: .health,
                    durationMillis: 123,
                    status: .failed(secretError)
                )
            ]
        )
        let sample = ConnectionBenchmarkSample.make(
            route: .tailscale,
            scenario: .warm,
            endpoint: secretEndpoint,
            report: report,
            tailcatDiagnostic: nil,
            preparation: .tailscaleSystemManaged,
            preparationMillis: nil,
            preparationSucceeded: true
        )
        let dataset = ConnectionBenchmarkDataset(samples: [sample])

        let data = try dataset.encodedExport(
            generatedAt: Date(timeIntervalSince1970: 2),
            appVersion: "1.0 (1)",
            osVersion: "iOS 26"
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(text.contains(secretEndpoint))
        XCTAssertFalse(text.contains("100.101.102.103"))
        XCTAssertFalse(text.contains(secretError))
        XCTAssertFalse(text.lowercased().contains("token"))
        XCTAssertTrue(text.contains("\"endpointCandidate\" : \"ip_address\""))
        XCTAssertTrue(text.contains("\"failureStage\" : \"health\""))
    }

    func testInvalidRegionIsDiscardedInsteadOfPartiallyExported() {
        let diagnostic = TailcatPathDiagnostic(
            id: UUID(),
            checkedAt: Date(),
            path: "derp",
            latencyMillis: 10,
            derpRegionCode: "tok/private-data",
            succeeded: true,
            requestLatencyMillis: nil,
            requestSucceeded: nil
        )
        let sample = ConnectionBenchmarkSample.make(
            route: .tailcat,
            scenario: .warm,
            endpoint: "http://127.0.0.1:40000",
            report: makeReport(route: .tailcat, totalMillis: 100),
            tailcatDiagnostic: diagnostic,
            preparation: .tailcatReusedClient,
            preparationMillis: nil,
            preparationSucceeded: true
        )

        XCTAssertNil(sample.relayRegion)
    }

    func testDatasetPersistsAndClearsInDedicatedDefaultsKey() throws {
        let suiteName = "ConnectionBenchmarkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sample = makeSample(
            route: .tailcat,
            scenario: .warm,
            path: .direct,
            milliseconds: 100,
            succeeded: true
        )
        let dataset = ConnectionBenchmarkDataset(samples: [sample])

        dataset.persist(defaults: defaults)
        XCTAssertEqual(ConnectionBenchmarkDataset.load(defaults: defaults), dataset)

        let cleared = ConnectionBenchmarkDataset.clear(defaults: defaults)
        XCTAssertTrue(cleared.samples.isEmpty)
        XCTAssertTrue(ConnectionBenchmarkDataset.load(defaults: defaults).samples.isEmpty)
    }

    private func makeReport(
        route: ConnectionTestRoute,
        totalMillis: Int,
        tailscaleNetworkPath: TailscaleNetworkPathResponse? = nil
    ) -> ConnectionTestReport {
        ConnectionTestReport(
            route: route,
            startedAt: Date(timeIntervalSince1970: 1),
            totalMillis: totalMillis,
            stages: [
                ConnectionTestStageTiming(kind: .health, durationMillis: totalMillis, status: .succeeded)
            ],
            tailscaleNetworkPath: tailscaleNetworkPath
        )
    }

    private func decodeNetworkPath(kind: String, region: String?) throws -> TailscaleNetworkPathResponse {
        let regionJSON = region.map { "\"\($0)\"" } ?? "null"
        let data = Data("{\"kind\":\"\(kind)\",\"observed_at\":0,\"relay_region\":\(regionJSON)}".utf8)
        return try JSONDecoder().decode(TailscaleNetworkPathResponse.self, from: data)
    }

    private func makeSample(
        route: ConnectionTestRoute,
        scenario: ConnectionBenchmarkScenario,
        path: ConnectionBenchmarkPath,
        region: String? = nil,
        milliseconds: Int,
        succeeded: Bool
    ) -> ConnectionBenchmarkSample {
        ConnectionBenchmarkSample(
            id: UUID(),
            recordedAt: Date(),
            route: route,
            scenario: scenario,
            preparation: route == .tailcat ? .tailcatReusedClient : .tailscaleSystemManaged,
            preparationMillis: nil,
            endpointCandidate: route == .tailcat ? .localProxy : .magicDNS,
            path: path,
            relayRegion: region,
            pathProbeMillis: nil,
            applicationMillis: milliseconds,
            endToEndMillis: milliseconds,
            stages: [],
            succeeded: succeeded,
            failureStage: succeeded ? nil : "health",
            recoverySucceeded: scenario == .networkRecovery ? succeeded : nil
        )
    }
}
