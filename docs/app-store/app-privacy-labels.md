# Mimi 托管连接 App 隐私填写依据

更新日期：2026-10-21

## 目标

按 App Store Connect「App 隐私」问卷核对 Mimi 托管连接新增的数据。本页是提交依据，不代表已修改 App Store Connect，也不替代对已有推送服务的复核。全 App 不能继续填写“开发者不收集数据”。

## 方案

Apple 将“收集”定义为离开设备后可访问的时间超过实时处理该请求所需的时间。仅本地处理或仅实时处理的内容须与持久保存的数据区分。分类依据见 [Apple App 隐私说明](https://developer.apple.com/app-store/app-privacy-details/)。

以下用途均为「App 功能」（App Functionality），用于权益验证、设备授权、安全控制和连接排障。没有广告、营销、个性化或跨 App / 网站追踪用途。使用 Apple 交易标识或随机设备标识仍可关联订阅或设备，因此不能仅凭“无需 Mimi 账号”或“保存散列”就选择“不与身份关联”。诊断事件虽不保存订阅或设备编号，但通过设备凭据提交，暂按关联数据保守披露。

### 代码依据索引

以下路径均相对于本公开仓库；不公开控制服务的部署细节或内部接口。

- A：`ios/MimiRemote/Sources/Core/StoreKit/ManagedConnectionStoreKitClient.swift`，读取商品、签名 App 交易与订阅交易、试用资格，以及恢复购买。
- B：`ios/MimiRemote/Sources/Core/API/ManagedConnectionEntitlementAPIClient.swift` 与 `ios/MimiRemote/Sources/State/ManagedConnectionEntitlementStore.swift`，提交签名交易并核验权益，恢复时不导入电脑连接配置。
- C：`ios/MimiRemote/Sources/Core/API/ManagedConnectionDeviceAPIClient.swift` 与 `ios/MimiRemote/Sources/State/ManagedConnectionDeviceStore.swift`，登记安装编号和设备类型、提交配对公钥与授权、读取和移除设备。
- D：`ios/MimiRemote/Sources/Core/Security/ManagedConnectionMobileIdentityStore.swift`，生成随机安装编号与托管设备凭据，在 Keychain 保存并在撤销后轮换凭据。
- E：`internal/httpapi/tailcat_managed_pairing.go`，电脑提交安装编号、公钥和托管配对凭据，并按主机授权策略控制接入。
- F：`ios/MimiRemote/Sources/Core/API/ManagedConnectionEventAPIClient.swift` 与 `ios/MimiRemote/Sources/State/TailcatExperimentController.swift`，提交随机事件编号、连接路径、成败、耗时区间、粗粒度错误分类、中继区域与 App 版本。
- G：`experiments/tailcat/internal/tunnel/host.go`、`experiments/tailcat/internal/tunnel/forwarder.go` 与 `experiments/tailcat/internal/tunnel/identity.go`，在设备间建立 Tailcat 数据连接，私钥与完整连接地址留在设备。

### 应披露的新增数据

| 问卷数据类型 | 收集的数据 | 是否收集 | 是否与身份关联 | 是否用于追踪 | 用途 | 代码依据 |
| --- | --- | --- | --- | --- | --- | --- |
| 购买项目 → 购买历史记录（Purchases → Purchase History） | 签名交易所含的订阅商品、交易标识、购买与到期信息、试用及撤销状态；服务端保存核验后的权益状态 | 是 | 是，关联同一订阅 | 否 | App 功能：购买、恢复与续期核验 | A、B |
| 标识符 → 用户 ID（Identifiers → User ID） | 用于关联订阅的 App 交易标识散列与权益编号；无需另建 Mimi 账号 | 是 | 是 | 否 | App 功能：跨设备恢复与权益管理 | A、B、C |
| 标识符 → 设备 ID（Identifiers → Device ID） | 随机安装编号的散列、设备与主机编号、设备类型、稳定及临时连接公钥、托管设备凭据散列 | 是 | 是，关联订阅及设备 | 否 | App 功能：设备名额、节点准入与授权 | C、D、E |
| 使用数据 → 产品交互（Usage Data → Product Interaction） | 设备登记、配对、授权关系和移除所产生的记录及时间 | 是 | 是 | 否 | App 功能：维护接入关系、释放名额与撤销访问 | C、E |
| 诊断 → 性能数据（Diagnostics → Performance Data） | 连接路径、成败、耗时区间、适用时的中继区域代码及事件时间 | 是 | 是，保守披露 | 否 | App 功能：连接可用性和性能排障 | F |
| 诊断 → 其他诊断数据（Diagnostics → Other Diagnostic Data） | 随机事件编号、粗粒度错误分类与 App 版本；服务错误另有错误日志 | 是 | 是，保守披露 | 否 | App 功能：错误诊断与服务运行 | F；生产错误日志仍需按下文复核 |
| 其他数据 → 其他数据类型（Other Data → Other Data Types） | 配对请求与会话编号、授权凭据散列、授权到期及完成记录；授权策略相关状态 | 是 | 是 | 否 | App 功能：配对、防重放与授权策略 | B、C、E |

购买和设备记录的保存字段、Apple 订阅通知处理、散列存储、撤销行为与保留期已与控制服务代码只读核对；此处的公开代码依据说明客户端实际提交和使用的数据。完整保留说明见[隐私政策](../privacy-policy.md)：连接结果按 30 天窗口每日清理，其他控制服务历史记录没有自动删除期限。移除设备是撤销授权，取消续费或凭据到期均不等于删除历史记录。

### 未新增收集的数据类型

以下仅说明托管连接的开发者服务，不代表用户自己的电脑或模型提供方的数据处理。

| 问卷数据类型 | 是否新增收集 | 是否与身份关联 | 是否用于追踪 | 用途与代码依据 |
| --- | --- | --- | --- | --- |
| 联系信息：姓名、邮箱、电话号码、实际地址、其他联系信息 | 否 | 不适用 | 否 | 无需 Mimi 账号；购买和接入请求不要求这些字段，见 A–E |
| 健康与健身：健康、健身 | 否 | 不适用 | 否 | 托管请求和事件无此类字段，见 B、C、E、F |
| 财务信息：付款信息、信用信息、其他财务信息 | 否 | 不适用 | 否 | Apple 处理付款；托管接口不要求银行卡等支付资料，见 A–C。购买历史另行披露 |
| 位置：精确位置、大致位置 | 未发现新增采集设备位置的代码 | 不适用 | 否 | 中继区域是中继位置；不据此申报用户位置。见 F；IP 的生产处理需另核对 |
| 敏感信息 | 否 | 不适用 | 否 | 托管请求和事件无此类字段，见 B、C、E、F |
| 通讯录 | 否 | 不适用 | 否 | 托管请求和事件无此类字段，见 B、C、E、F |
| 用户内容：电子邮件或短信、照片或视频、音频、游戏内容、客服支持、其他用户内容 | 否，托管连接不新增收集可读工作内容 | 不适用 | 否 | 工作内容经端到端加密传输；控制面请求不含此类内容，见 B、C、E、F、G。用户主动发送支持邮件需按支持流程另行复核 |
| 浏览历史记录、搜索历史记录 | 否 | 不适用 | 否 | 托管请求和事件无此类字段，见 B、C、E、F |
| 使用数据：广告数据、其他使用数据 | 未发现上述产品交互之外的新增字段 | 不适用 | 否 | 见 B、C、E、F；生产日志需另核对 |
| 诊断：崩溃数据 | 未发现新增上传 | 不适用 | 否 | F 仅发送粗粒度连接事件，不是崩溃堆栈 |
| 周围环境、身体：环境扫描、手部、头部 | 否 | 不适用 | 否 | 托管请求和事件无此类字段，见 B、C、E、F |

### 网络元数据与生产日志的边界

中继会处理双方 IP、公钥、连接时间和流量大小。公钥已在设备 ID 中披露；连接诊断已单列。不能从客户端代码推断生产中继、反向代理或日志平台是否长期保留原始 IP、连接时间与字节计数，也不能据此声称“IP 从不落盘”。

若确认仅为实时转发而短暂处理，按 Apple 的收集定义判断；若生产环境保留 IP 或更细网络记录，应按实际用途补入设备 ID、诊断或相应位置类型，并核对身份关联、用途和保留期。未确认前，不把“仅实时处理、不需披露”作为提交结论。

## 实现

- 提交前由维护者逐项核对生产服务和日志配置，再将本页结论填入 App Store Connect。
- 同时复核已有消息通知与实时活动的 APNs 路由数据、撤销记录、错误日志与指标，不能只填写托管连接差量。
- 核对购买界面、商店描述、[隐私政策](../privacy-policy.md)及[使用条款](../terms-of-use.md)的一致性。

## 风险与优化

诊断数据的身份关联目前按保守口径披露。若要改为“不关联”，须先证明收集前已去标识且不会重新关联。生产日志、备份保留期与完整删除流程尚需维护者确认，不能从凭据有效期推导数据保留期，也不能承诺取消订阅即清空记录。
