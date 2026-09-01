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

// ConfigureTailcat 只修改 tailcat.enabled，并保留配置中的未知字段。
func ConfigureTailcat(configPath string, enabled bool) (TailcatConfigurationResult, error) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return TailcatConfigurationResult{}, err
	}
	original, err := os.ReadFile(cfgPath)
	if err != nil {
		return TailcatConfigurationResult{}, fmt.Errorf("读取配置文件失败：%w", err)
	}
	var document map[string]json.RawMessage
	if err := json.Unmarshal(original, &document); err != nil || document == nil {
		return TailcatConfigurationResult{}, fmt.Errorf("配置文件必须是 JSON object")
	}
	tailcatDocument := map[string]json.RawMessage{}
	if raw := document["tailcat"]; len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &tailcatDocument); err != nil {
			return TailcatConfigurationResult{}, fmt.Errorf("tailcat 配置必须是 JSON object")
		}
	}
	previousEnabled := false
	if raw := tailcatDocument["enabled"]; len(raw) > 0 {
		if err := json.Unmarshal(raw, &previousEnabled); err != nil {
			return TailcatConfigurationResult{}, fmt.Errorf("tailcat.enabled 必须是布尔值")
		}
	}
	encodedEnabled, _ := json.Marshal(enabled)
	tailcatDocument["enabled"] = encodedEnabled
	encodedTailcat, err := json.Marshal(tailcatDocument)
	if err != nil {
		return TailcatConfigurationResult{}, err
	}
	document["tailcat"] = encodedTailcat
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return TailcatConfigurationResult{}, err
	}
	updated = append(updated, '\n')
	changed := string(updated) != string(original)
	if changed {
		if err := writePrivateFileAtomicallyCAS(cfgPath, original, updated); err != nil {
			return TailcatConfigurationResult{}, fmt.Errorf("原子更新 Tailcat 配置失败：%w", err)
		}
	}
	return TailcatConfigurationResult{
		Enabled:         enabled,
		PreviousEnabled: previousEnabled,
		Changed:         changed,
	}, nil
}

func TailcatPair(configPath, pairAddress string) (Result, error) {
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
