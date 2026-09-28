import Foundation

/// 主机探测结果回写连接档案的可变元数据。
///
/// 这里只处理展示与路由元数据（设备名、平台、MagicDNS 名称）：它们都不参与身份、
/// 凭据或数据分区判断。身份边界始终是 `installation_id`，任何一次刷新都必须先核对
/// 档案 revision 与 installation_id 未变化，避免迟到探测覆盖用户刚改过的连接。
extension AppStore {
    /// 平台只在服务端明确返回时覆盖，异常与旧服务端的空值继续沿用旧档案。
    static func resolvedHostPlatform(
        _ candidate: HostPlatform,
        fallback: HostPlatform
    ) -> HostPlatform {
        candidate == .unknown ? fallback : candidate
    }

    /// 主机探活可在不切换连接的情况下补齐平台元数据。
    ///
    /// 平台不参与凭据或路由身份，因此不递增 revision；但仍核对探测开始时的 revision，
    /// 防止旧请求在用户编辑连接地址后覆盖新档案。
    func rememberHostPlatform(
        _ hostPlatform: HostPlatform,
        profileID: String,
        expectedRevision: UInt64
    ) {
        guard hostPlatform != .unknown,
              let profileIndex = connectionProfiles.firstIndex(where: {
                  $0.id == profileID && $0.revision == expectedRevision
              }),
              connectionProfiles[profileIndex].hostPlatform != hostPlatform else {
            return
        }

        var nextProfiles = connectionProfiles
        nextProfiles[profileIndex].hostPlatform = hostPlatform
        if profileID != ephemeralLocalProfileID {
            guard let encodedProfiles = try? JSONEncoder().encode(nextProfiles) else {
                return
            }
            persistProfiles(encodedProfiles)
        }
        replaceConnectionProfiles(nextProfiles)
    }

    /// 探测结果只有在 Profile revision 与 installation_id 都未变化时才能刷新可变名称。
    /// DNSName 只改变下一次路由候选；设备名只改变默认显示名。两者都不会合并档案，
    /// 也不会改写稳定身份，用户自定义名字始终优先。
    @discardableResult
    func refreshConnectionProfileHostMetadata(
        profileID: String,
        expectedRevision: UInt64,
        version: VersionResponse
    ) -> ConnectionProfile? {
        guard let index = connectionProfiles.firstIndex(where: { $0.id == profileID }),
              connectionProfiles[index].revision == expectedRevision,
              let expectedInstallationID = Self.normalizedInstallationID(
                  connectionProfiles[index].installationID
              ),
              Self.normalizedInstallationID(version.installationID) == expectedInstallationID else {
            return nil
        }
        // MagicDNS 元数据只有 Tailscale 地址档案才接受；设备名对所有路由都有效，
        // 旧 agentd 缺失该字段时保留已存值，不能把名字擦成地址。
        let acceptsTailscaleMetadata = ConnectionProfile.isTailscaleIPEndpoint(
            connectionProfiles[index].endpoint
        )
        let dnsName = acceptsTailscaleMetadata
            ? (ConnectionProfile.normalizedTailscaleDNSName(version.tailscaleDNSName)
                ?? connectionProfiles[index].tailscaleDNSName)
            : nil
        let deviceName = acceptsTailscaleMetadata
            ? (ConnectionProfile.normalizedTailscaleDeviceName(
                version.tailscaleDeviceName,
                dnsName: dnsName
            ) ?? connectionProfiles[index].tailscaleDeviceName)
            : nil
        let hostDeviceName = ConnectionProfile.normalizedHostDeviceName(version.deviceName)
            ?? connectionProfiles[index].hostDeviceName
        var updated = connectionProfiles[index]
        // 设备名优先于 Tailscale 名称：宿主系统里的「电脑名称」是用户在设置里认得的名字，
        // 主机名或 MagicDNS 名称只在读不到电脑名时才作为默认名。
        let nextDisplayName = updated.isDisplayNameCustomized
            ? updated.displayName
            : (hostDeviceName
                ?? deviceName
                ?? ConnectionProfile.fallbackDisplayName(endpoint: updated.endpoint))
        guard updated.tailscaleDNSName != dnsName ||
                updated.tailscaleDeviceName != deviceName ||
                updated.hostDeviceName != hostDeviceName ||
                updated.displayName != nextDisplayName else {
            return updated
        }
        updated.tailscaleDNSName = dnsName
        updated.tailscaleDeviceName = deviceName
        updated.hostDeviceName = hostDeviceName
        updated.displayName = nextDisplayName
        updated.revision &+= 1

        var nextProfiles = connectionProfiles
        nextProfiles[index] = updated
        if profileID != ephemeralLocalProfileID {
            guard let encoded = try? JSONEncoder().encode(nextProfiles) else {
                return nil
            }
            persistProfiles(encoded)
        }
        replaceConnectionProfiles(nextProfiles)
        if profileID == activeConnectionProfileID {
            replaceActiveHostDisplayName(updated.displayName)
        }
        return updated
    }
}
