# 自建中转

手机和电脑使用内置连接（Tailcat）时，会先尝试直连；直连不通就经中转服务器转发。默认使用 Tailcat 自带的公共中转，不需要任何配置。

如果你有自己的公网服务器，并且希望线路由自己掌握，可以部署自建中转。使用 Tailscale 或局域网连接时不经过这里，无需部署。

代码和对话全程端到端加密，中转服务器只转发密文，看不到内容。

## 需要准备

- 一台有公网 IP 的服务器。
- 一个解析到这台服务器的域名，下文用 `relay.example.com` 代替。
- 服务器防火墙放行 `443/TCP`、`80/TCP`（申请证书）和 `3478/UDP`（探测网络）。

## 第一步：部署 derper

derper 是 Tailscale 开源的中转程序。安装时使用下面的版本，它与 Mimi 内置的 Tailcat 保持一致：

```bash
go install tailscale.com/cmd/derper@v1.103.0-pre.0.20260916030321-a2263542f260
```

这条命令需要先安装 Go，所需的 Go 版本会自动下载。把生成的 `derper` 放到 `/usr/local/bin/`，再创建 `/etc/systemd/system/derper.service`：

```ini
[Unit]
Description=Mimi self-hosted relay
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/derper --hostname=relay.example.com --certdir=/var/lib/derper/certs --c=/var/lib/derper/derper.key
StateDirectory=derper
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
```

启动并验证：

```bash
sudo systemctl enable --now derper
curl -I https://relay.example.com/derp/probe
```

返回 `200` 说明服务正常，证书由 Let's Encrypt 自动申请。

**已有证书或 443 端口被占用时**，可以手动指定：

```bash
derper --hostname=relay.example.com --a=:8443 --http-port=-1 --certmode=manual --certdir=/path/to/certs --c=/path/to/derper.key
```

`--certmode=manual` 会读取证书目录里的 `relay.example.com.crt` 和 `relay.example.com.key`。证书必须被手机和电脑信任。

**不要开启 `--verify-clients`**：它依赖本机的 Tailscale 客户端校验，Tailcat 设备不在你的 tailnet 里，开启后会连不上。

因此，知道地址的人都可以使用这台中转。他们看不到你的内容，但会消耗你的流量，可以用 `--accept-connection-limit` 和 `--accept-connection-burst` 限制新连接速率。

## 第二步：发布 DERP Map

DERP Map 是一份 JSON 文件，告诉 Tailcat 中转服务器在哪里：

```json
{
  "Regions": {
    "900": {
      "RegionID": 900,
      "RegionCode": "my",
      "RegionName": "My Relay",
      "Nodes": [
        {
          "Name": "900a",
          "RegionID": 900,
          "HostName": "relay.example.com"
        }
      ]
    }
  }
}
```

- 把 `relay.example.com` 换成你的域名，其余字段可以保持不变。
- 如果 derper 不在 `443` 端口，在节点里加上 `"DERPPort": 8443`。
- 自定义中转的区域编号建议使用 `900` 到 `999`。

把这份文件放到任意 HTTPS 地址，例如 Nginx、对象存储或静态托管服务。这个地址要求：

- 必须是完整的 HTTPS 地址，例如 `https://relay.example.com/derpmap.json`。
- 不能包含用户名、密码或 `#` 片段，长度不超过 2048 个字符。

电脑需要能访问这个地址；手机和电脑都需要能访问 derper。

## 第三步：在电脑上使用

**Mac**：打开配对窗口选择“内置连接”，或打开“设置”，把“中转服务”切换为“自建中转”，填入 DERP Map 地址。

**Windows**：打开控制面板，点击“中转服务”，选择“自建中转”，填入地址后点击“使用此中转”。

**Linux 或命令行**：

```bash
agentd tailcat configure --derp-map-url=https://relay.example.com/derpmap.json
```

## 第四步：手机重新扫码

更换中转后，电脑的连接地址会变化，手机需要扫描电脑上的新二维码。扫码后，可以在 App 的“设备 → 中转服务”看到当前使用自建中转。

如果切换失败，电脑会自动恢复原来的中转，已有连接不受影响。

## 改回默认

在电脑上把“中转服务”切换为“默认 Tailcat 自带”，然后让手机重新扫码。命令行的写法是：

```bash
agentd tailcat configure --derp-map-url=
```

## 常见问题

| 现象 | 先检查 |
| --- | --- |
| 电脑提示地址无效 | 是否为完整的 HTTPS 地址，是否包含用户名、密码或 `#` |
| 切换后立刻恢复原中转 | 电脑能否打开 DERP Map 地址，内容是否为上面格式的 JSON |
| `curl` 证书报错 | 域名是否已解析到服务器，`80` 和 `443` 端口是否放行 |
| 手机扫码后连不上 | 手机所在网络能否访问 `https://relay.example.com/derp/probe` |
| 能连上但只有经中转才通 | 这是正常情况；放行 `3478/UDP` 有助于建立直连 |

Mimi 中转不能这样配置：它的官方地址只接受已开通的设备，请直接在“中转服务”里选择“Mimi 中转”。
