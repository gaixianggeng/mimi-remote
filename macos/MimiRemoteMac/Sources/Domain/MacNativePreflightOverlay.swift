import Foundation

/// macOS 原生状态覆盖：仅在存在肯定原生证据时按同检查 ID 覆盖 `permission_*` 与
/// `service_daemon`（`SMAppService.agent.status == .requiresApproval` 将
/// `service_not_running` 覆盖为 `service_requires_approval`），并重算
/// `blocking`、`ok` 与 `recommended_next`。
struct MacNativePreflightEvidence: Equatable, Sendable {
    let agentRegistrationState: ServiceRegistrationState
    let mainAppRegistrationState: ServiceRegistrationState
    let photosAccessState: PhotosAccessState
    let localNetworkAccessDenied: Bool
}

enum MacNativePreflightOverlay {
    static func apply(
        to report: OnboardingPreflightReport,
        evidence: MacNativePreflightEvidence
    ) -> OnboardingPreflightReport {
        let usesHomebrew = report.checks.contains {
            $0.id == .serviceOwnerConflict && $0.code == "homebrew_service_active"
        }
        let overlaidChecks = report.checks.map { check in
            if usesHomebrew, check.id == .permissionPhotos {
                return check
            }
            return apply(to: check, stage: report.stage, evidence: evidence)
        }
        let firstBlocker = overlaidChecks.first(where: \.blocking)?.id
        let recomputedOK = firstBlocker == nil
        let recomputedNext: OnboardingCheckID = firstBlocker
            ?? (report.stage == .setup && !report.configured ? .configStore : .networkAny)
        return OnboardingPreflightReport(
            schema: report.schema,
            ok: recomputedOK,
            stage: report.stage,
            configured: report.configured,
            workspaceConfirmed: report.workspaceConfirmed,
            configPath: report.configPath,
            scanRoot: report.scanRoot,
            browseRoot: report.browseRoot,
            scanRootExists: report.scanRootExists,
            recommendedNext: recomputedNext,
            recommendedTransport: report.recommendedTransport,
            checks: overlaidChecks
        )
    }

    static func apply(
        to check: OnboardingCheck,
        stage: OnboardingStage,
        evidence: MacNativePreflightEvidence
    ) -> OnboardingCheck {
        switch check.id {
        case .serviceDaemon:
            if evidence.agentRegistrationState == .requiresApproval,
               check.code == "service_not_running"
            {
                return OnboardingCheck(
                    id: .serviceDaemon,
                    state: .actionNeeded,
                    detail: OnboardingCopyCatalog.localizedMessage(
                        code: "service_requires_approval",
                        step: .serviceDaemon
                    ),
                    blocking: stage == .pair,
                    code: "service_requires_approval",
                    fix: .openSettings(.loginItems)
                )
            }
            return check

        case .permissionLoginItem:
            switch evidence.mainAppRegistrationState {
            case .enabled:
                return OnboardingCheck(
                    id: .permissionLoginItem,
                    state: .ok,
                    detail: "已允许登录时启动。",
                    blocking: false
                )
            case .notRegistered, .requiresApproval:
                return OnboardingCheck(
                    id: .permissionLoginItem,
                    state: .optional,
                    detail: OnboardingCopyCatalog.localizedMessage(
                        code: "permission_login_item_disabled",
                        step: .permissionLoginItem
                    ),
                    blocking: false,
                    code: "permission_login_item_disabled",
                    fix: .openSettings(.loginItems)
                )
            case .notFound:
                return check
            }

        case .permissionPhotos:
            switch evidence.photosAccessState {
            case .authorized, .limited:
                return OnboardingCheck(
                    id: .permissionPhotos,
                    state: .ok,
                    detail: "已允许访问照片。",
                    blocking: false
                )
            case .denied, .restricted:
                return OnboardingCheck(
                    id: .permissionPhotos,
                    state: .optional,
                    detail: OnboardingCopyCatalog.localizedMessage(
                        code: "permission_photos_denied",
                        step: .permissionPhotos
                    ),
                    blocking: false,
                    code: "permission_photos_denied",
                    fix: .openSettings(.photos)
                )
            case .notDetermined:
                // 未知状态必须保持 optional（permission_unobserved），绝不主动弹窗或反推。
                return check
            }

        case .permissionLocalNetwork:
            if evidence.localNetworkAccessDenied {
                return OnboardingCheck(
                    id: .permissionLocalNetwork,
                    state: .actionNeeded,
                    detail: OnboardingCopyCatalog.localizedMessage(
                        code: "permission_local_network_denied",
                        step: .permissionLocalNetwork
                    ),
                    blocking: false,
                    code: "permission_local_network_denied",
                    fix: .openSettings(.localNetwork)
                )
            }
            return check

        default:
            return check
        }
    }
}
