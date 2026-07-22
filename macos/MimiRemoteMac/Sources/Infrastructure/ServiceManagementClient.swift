import ServiceManagement

struct ServiceManagementClient {
    var agentStatus: @MainActor () -> ServiceRegistrationState
    var registerAgent: @MainActor () throws -> Void
    var unregisterAgent: @MainActor () async throws -> Void
    var mainAppStatus: @MainActor () -> ServiceRegistrationState
    var registerMainApp: @MainActor () throws -> Void
    var unregisterMainApp: @MainActor () async throws -> Void
    var openLoginItemsSettings: @MainActor () -> Void
}

extension ServiceManagementClient {
    @MainActor
    static var live: ServiceManagementClient {
        ServiceManagementClient(
            agentStatus: {
                registrationState(for: agentService.status)
            },
            registerAgent: {
                let service = agentService
                if service.status != .enabled {
                    try service.register()
                }
            },
            unregisterAgent: {
                let service = agentService
                guard service.status != .notRegistered, service.status != .notFound else { return }
                try service.unregister()
            },
            mainAppStatus: {
                registrationState(for: SMAppService.mainApp.status)
            },
            registerMainApp: {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            },
            unregisterMainApp: {
                guard SMAppService.mainApp.status != .notRegistered,
                      SMAppService.mainApp.status != .notFound
                else { return }
                try SMAppService.mainApp.unregister()
            },
            openLoginItemsSettings: {
                SMAppService.openSystemSettingsLoginItems()
            }
        )
    }

    @MainActor
    private static var agentService: SMAppService {
        SMAppService.agent(plistName: "com.gaixianggeng.mimi.mac.agentd.plist")
    }

    @MainActor
    private static func registrationState(for status: SMAppService.Status) -> ServiceRegistrationState {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}
