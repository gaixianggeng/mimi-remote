import Foundation

extension SessionStore {
    func diagnosticTraceKey(sessionID: SessionID) -> String {
        "profile:\(appStore.activeHostScope.profileID):session:\(sessionID)"
    }

    func diagnosticCorrelation(sessionID: SessionID) -> AppDiagnosticCorrelation? {
        guard AppDiagnostics.isDetailedLoggingEnabled else { return nil }
        return AppDiagnosticTraceRegistry.shared.correlation(key: diagnosticTraceKey(sessionID: sessionID))
    }

    func beginTurnDiagnostics(sessionID: SessionID) -> AppDiagnosticCorrelation? {
        guard AppDiagnostics.isDetailedLoggingEnabled else { return nil }
        return AppDiagnosticTraceRegistry.shared.begin(key: diagnosticTraceKey(sessionID: sessionID))
    }

    func recordRuntimeDiagnostic(_ event: AgentEvent, fallbackSessionID: SessionID) {
        let metadata = metadata(for: event)
        let sessionID = metadata?.sessionID ?? fallbackSessionID
        let key = diagnosticTraceKey(sessionID: sessionID)

        if case .error = event {
            AppDiagnostics.record(
                stage: .failure,
                result: .failed,
                reason: .server,
                correlation: diagnosticCorrelation(sessionID: sessionID)
            )
            return
        }
        if case .turnCompleted(let metadata) = event {
            let correlation = AppDiagnostics.isDetailedLoggingEnabled
                ? AppDiagnosticTraceRegistry.shared.end(key: key)
                : nil
            switch metadata.turnLifecycle {
            case .failed:
                AppDiagnostics.record(stage: .completion, result: .failed, reason: .server, correlation: correlation)
            case .interrupted:
                AppDiagnostics.record(stage: .interrupt, result: .succeeded, correlation: correlation)
            default:
                AppDiagnostics.record(stage: .completion, result: .succeeded, correlation: correlation)
            }
            return
        }
        guard AppDiagnostics.isDetailedLoggingEnabled else { return }

        switch event {
        case .turnStarted:
            let correlation = AppDiagnosticTraceRegistry.shared.markTurnStarted(key: key)
            AppDiagnostics.record(
                stage: .messageAcknowledgement,
                result: .received,
                correlation: correlation
            )
        case .messageCompleted(let message, _):
            guard message.role == .assistant,
                  let correlation = AppDiagnosticTraceRegistry.shared.takeFirstResponse(key: key) else { return }
            AppDiagnostics.record(
                stage: .firstResponse,
                result: .received,
                correlation: correlation
            )
        case .approvalRequest:
            AppDiagnostics.record(
                stage: .approval,
                result: .received,
                correlation: AppDiagnosticTraceRegistry.shared.correlation(key: key)
            )
        case .approvalResolved:
            AppDiagnostics.record(
                stage: .approval,
                result: .succeeded,
                correlation: AppDiagnosticTraceRegistry.shared.correlation(key: key)
            )
        default:
            break
        }
    }
}
