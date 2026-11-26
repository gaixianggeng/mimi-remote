package tunnel

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/tailscale/tailcat"
	"tailscale.com/types/key"
)

type hostIdentity struct {
	PrivateKey string `json:"private_key"`
	Address    string `json:"address"`
}

type clientIdentity struct {
	PrivateKey string `json:"private_key"`
	PublicKey  string `json:"public_key"`
}

func loadOrCreateHostIdentity(path string) (key.NodePrivate, *tailcat.ConnInfo, error) {
	data, err := config.ReadPrivatePreflightFile(path, 4<<20)
	if errors.Is(err, os.ErrNotExist) {
		return key.NewNode(), nil, nil
	}
	if err != nil {
		return key.NodePrivate{}, nil, fmt.Errorf("读取服务端身份：%w", err)
	}
	var stored hostIdentity
	if err := json.Unmarshal(data, &stored); err != nil {
		return key.NodePrivate{}, nil, fmt.Errorf("解析服务端身份：%w", err)
	}
	privateKey, err := parsePrivateKey(stored.PrivateKey)
	if err != nil {
		return key.NodePrivate{}, nil, err
	}
	info, err := tailcat.ParseAddr(tailcat.Addr(stored.Address))
	if err != nil {
		return key.NodePrivate{}, nil, fmt.Errorf("解析已保存的 Tailcat 地址：%w", err)
	}
	if info.ServerPublic.NodePublic != privateKey.Public() {
		return key.NodePrivate{}, nil, errors.New("服务端身份中的私钥与 Tailcat 地址不匹配")
	}
	if len(info.Region) != 1 {
		return key.NodePrivate{}, nil, fmt.Errorf("服务端身份包含 %d 个 DERP 区域，预期为 1 个", len(info.Region))
	}
	return privateKey, &info, nil
}

func saveHostIdentity(path string, privateKey key.NodePrivate, address tailcat.Addr) error {
	privateText, err := privateKey.MarshalText()
	if err != nil {
		return fmt.Errorf("序列化服务端私钥：%w", err)
	}
	data, err := json.MarshalIndent(hostIdentity{
		PrivateKey: string(privateText),
		Address:    string(address),
	}, "", "  ")
	if err != nil {
		return fmt.Errorf("序列化服务端身份：%w", err)
	}
	return config.WritePrivateFile(path, append(data, '\n'))
}

func LoadOrCreateClientIdentity(path string) (key.NodePrivate, error) {
	data, err := config.ReadPrivatePreflightFile(path, 4<<20)
	if errors.Is(err, os.ErrNotExist) {
		privateKey := key.NewNode()
		if err := saveClientIdentity(path, privateKey); err != nil {
			return key.NodePrivate{}, err
		}
		return privateKey, nil
	}
	if err != nil {
		return key.NodePrivate{}, fmt.Errorf("读取客户端身份：%w", err)
	}
	var stored clientIdentity
	if err := json.Unmarshal(data, &stored); err != nil {
		return key.NodePrivate{}, fmt.Errorf("解析客户端身份：%w", err)
	}
	privateKey, err := parsePrivateKey(stored.PrivateKey)
	if err != nil {
		return key.NodePrivate{}, err
	}
	if stored.PublicKey != privateKey.Public().String() {
		return key.NodePrivate{}, errors.New("客户端身份中的公钥与私钥不匹配")
	}
	return privateKey, nil
}

func saveClientIdentity(path string, privateKey key.NodePrivate) error {
	privateText, err := privateKey.MarshalText()
	if err != nil {
		return fmt.Errorf("序列化客户端私钥：%w", err)
	}
	data, err := json.MarshalIndent(clientIdentity{
		PrivateKey: string(privateText),
		PublicKey:  privateKey.Public().String(),
	}, "", "  ")
	if err != nil {
		return fmt.Errorf("序列化客户端身份：%w", err)
	}
	return config.WritePrivateFile(path, append(data, '\n'))
}

func ParsePublicKey(value string) (key.NodePublic, error) {
	var publicKey key.NodePublic
	if err := publicKey.UnmarshalText([]byte(strings.TrimSpace(value))); err != nil {
		return key.NodePublic{}, fmt.Errorf("解析客户端公钥：%w", err)
	}
	if publicKey.IsZero() {
		return key.NodePublic{}, errors.New("客户端公钥不能为空")
	}
	return publicKey, nil
}

func NewClientPrivateKey() (string, error) {
	privateText, err := key.NewNode().MarshalText()
	if err != nil {
		return "", fmt.Errorf("序列化客户端私钥：%w", err)
	}
	return string(privateText), nil
}

func ClientPublicKey(privateText string) (string, error) {
	privateKey, err := parsePrivateKey(privateText)
	if err != nil {
		return "", err
	}
	return privateKey.Public().String(), nil
}

func parsePrivateKey(value string) (key.NodePrivate, error) {
	var privateKey key.NodePrivate
	if err := privateKey.UnmarshalText([]byte(strings.TrimSpace(value))); err != nil {
		return key.NodePrivate{}, fmt.Errorf("解析节点私钥：%w", err)
	}
	if privateKey.IsZero() {
		return key.NodePrivate{}, errors.New("节点私钥不能为空")
	}
	return privateKey, nil
}
