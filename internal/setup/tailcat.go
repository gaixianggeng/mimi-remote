package setup

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

const PairingNetworkTailcat PairingNetwork = "tailcat"

type TailcatConfigurationResult struct {
	Enabled         bool `json:"enabled"`
	PreviousEnabled bool `json:"previous_enabled"`
	Changed         bool `json:"changed"`
}

type TailcatDERPConfigurationResult struct {
	DERPMapURL         string `json:"derp_map_url,omitempty"`
	PreviousDERPMapURL string `json:"previous_derp_map_url,omitempty"`
	Changed            bool   `json:"changed"`
}

// ConfigureTailcat 只修改 tailcat.enabled，并保留配置中的未知字段。
func ConfigureTailcat(configPath string, enabled bool) (TailcatConfigurationResult, error) {
	cfgPath, original, document, tailcatDocument, err := readTailcatConfiguration(configPath)
	if err != nil {
		return TailcatConfigurationResult{}, err
	}
	previousEnabled := false
	if raw := tailcatDocument["enabled"]; len(raw) > 0 {
		if err := json.Unmarshal(raw, &previousEnabled); err != nil {
			return TailcatConfigurationResult{}, fmt.Errorf("tailcat.enabled 必须是布尔值")
		}
	}
	encodedEnabled, _ := json.Marshal(enabled)
	tailcatDocument["enabled"] = encodedEnabled
	changed, err := commitTailcatConfiguration(cfgPath, original, document, tailcatDocument)
	if err != nil {
		return TailcatConfigurationResult{}, err
	}
	return TailcatConfigurationResult{
		Enabled:         enabled,
		PreviousEnabled: previousEnabled,
		Changed:         changed,
	}, nil
}

// ConfigureTailcatDERPMap 更新用户可见的自定义 DERP Map。空值会删除字段，
// 让 Tailcat 恢复默认中继；未知配置字段必须继续保留。
func ConfigureTailcatDERPMap(configPath, rawURL string) (TailcatDERPConfigurationResult, error) {
	normalized, err := config.NormalizeTailcatDERPMapURL(rawURL)
	if err != nil {
		return TailcatDERPConfigurationResult{}, err
	}
	cfgPath, original, document, tailcatDocument, err := readTailcatConfiguration(configPath)
	if err != nil {
		return TailcatDERPConfigurationResult{}, err
	}
	previous := ""
	if raw := tailcatDocument["derp_map_url"]; len(raw) > 0 {
		if err := json.Unmarshal(raw, &previous); err != nil {
			return TailcatDERPConfigurationResult{}, fmt.Errorf("tailcat.derp_map_url 必须是字符串")
		}
		previous = strings.TrimSpace(previous)
	}
	if normalized == "" {
		delete(tailcatDocument, "derp_map_url")
	} else {
		encoded, _ := json.Marshal(normalized)
		tailcatDocument["derp_map_url"] = encoded
	}
	changed, err := commitTailcatConfiguration(cfgPath, original, document, tailcatDocument)
	if err != nil {
		return TailcatDERPConfigurationResult{}, err
	}
	return TailcatDERPConfigurationResult{
		DERPMapURL:         normalized,
		PreviousDERPMapURL: previous,
		Changed:            changed,
	}, nil
}

func readTailcatConfiguration(configPath string) (
	string,
	[]byte,
	map[string]json.RawMessage,
	map[string]json.RawMessage,
	error,
) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return "", nil, nil, nil, err
	}
	original, err := os.ReadFile(cfgPath)
	if err != nil {
		return "", nil, nil, nil, fmt.Errorf("读取配置文件失败：%w", err)
	}
	var document map[string]json.RawMessage
	if err := json.Unmarshal(original, &document); err != nil || document == nil {
		return "", nil, nil, nil, fmt.Errorf("配置文件必须是 JSON object")
	}
	tailcatDocument := map[string]json.RawMessage{}
	if raw := document["tailcat"]; len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &tailcatDocument); err != nil {
			return "", nil, nil, nil, fmt.Errorf("tailcat 配置必须是 JSON object")
		}
	}
	return cfgPath, original, document, tailcatDocument, nil
}

func commitTailcatConfiguration(
	cfgPath string,
	original []byte,
	document map[string]json.RawMessage,
	tailcatDocument map[string]json.RawMessage,
) (bool, error) {
	encodedTailcat, err := json.Marshal(tailcatDocument)
	if err != nil {
		return false, err
	}
	document["tailcat"] = encodedTailcat
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return false, err
	}
	updated = append(updated, '\n')
	changed := string(updated) != string(original)
	if changed {
		if err := writePrivateFileAtomicallyCAS(cfgPath, original, updated); err != nil {
			return false, fmt.Errorf("原子更新 Tailcat 配置失败：%w", err)
		}
	}
	return changed, nil
}

func TailcatPair(configPath, pairAddress string) (Result, error) {
	return TailcatPairWithManagedHost(configPath, pairAddress, "", "")
}

// TailcatPairWithManagedHost 只把 Mac 的随机安装 ID 和稳定 Tailcat 公钥加入
// 二维码。两者都不是凭证；移动端仍需先取得订阅权益和短期配对授权。
func TailcatPairWithManagedHost(
	configPath string,
	pairAddress string,
	macInstallationID string,
	macTailcatPublicKey string,
) (Result, error) {
	pairAddress = strings.TrimSpace(pairAddress)
	if pairAddress == "" {
		return Result{}, fmt.Errorf("Tailcat 短期配对地址为空")
	}
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return Result{}, err
	}
	cfg, err := config.LoadForDoctor(cfgPath)
	if err != nil {
		return Result{}, err
	}
	now := time.Now().UTC()
	expiresAt := now.Add(defaultPairingURLTTL)
	endpoint := "http://127.0.0.1:8787"
	rawPairURL := pairingURL(endpoint, cfg.Auth.Token, now, expiresAt)
	parsed, err := url.Parse(rawPairURL)
	if err != nil {
		return Result{}, err
	}
	query := parsed.Query()
	query.Set("transport", "tailcat")
	query.Set("tailcat_pair_address", pairAddress)
	macInstallationID = strings.TrimSpace(macInstallationID)
	macTailcatPublicKey = strings.TrimSpace(macTailcatPublicKey)
	if (macInstallationID == "") != (macTailcatPublicKey == "") {
		return Result{}, fmt.Errorf("托管配对的 Mac 安装身份和 Tailcat 公钥必须同时提供")
	}
	if macInstallationID != "" {
		query.Set("managed_mac_installation_id", macInstallationID)
		query.Set("managed_mac_tailcat_public_key", macTailcatPublicKey)
	}
	parsed.RawQuery = query.Encode()
	return Result{
		ConfigPath:    cfgPath,
		Endpoint:      endpoint,
		Network:       PairingNetworkTailcat,
		PairURL:       parsed.String(),
		PairIssuedAt:  now.Format(time.RFC3339Nano),
		PairExpiresAt: expiresAt.Format(time.RFC3339Nano),
		Warnings: []string{
			"Tailcat 是邀请实验；二维码十分钟内有效，且不会包含长期访问码。",
		},
	}, nil
}
