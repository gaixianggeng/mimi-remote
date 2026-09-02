package tunnel

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

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
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return key.NewNode(), nil, nil
	}
	if err != nil {
		return key.NodePrivate{}, nil, fmt.Errorf("读取服务端身份：%w", err)
	}
	if err := requirePrivateFile(path); err != nil {
		return key.NodePrivate{}, nil, err
	}

	var stored hostIdentity
	if err := json.Unmarshal(data, &stored); err != nil {
		return key.NodePrivate{}, nil, fmt.Errorf("解析服务端身份：%w", err)
	}
	privateKey, err := parsePrivateKey(stored.PrivateKey)
	if err != nil {
		return key.NodePrivate{}, nil, err
	}
	info, err := tailcat.ParseConnBlob(tailcat.ConnBlob(stored.Address))
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

func saveHostIdentity(path string, privateKey key.NodePrivate, address tailcat.ConnBlob) error {
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
	return writePrivateFile(path, append(data, '\n'))
}

func LoadOrCreateClientIdentity(path string) (key.NodePrivate, error) {
	data, err := os.ReadFile(path)
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
	if err := requirePrivateFile(path); err != nil {
		return key.NodePrivate{}, err
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
	return writePrivateFile(path, append(data, '\n'))
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

func writePrivateFile(path string, data []byte) error {
	if path == "" {
		return errors.New("文件路径不能为空")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("创建身份目录：%w", err)
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".tailcat-*")
	if err != nil {
		return fmt.Errorf("创建临时文件：%w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return fmt.Errorf("设置临时文件权限：%w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return fmt.Errorf("写入临时文件：%w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return fmt.Errorf("同步临时文件：%w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("关闭临时文件：%w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("替换文件：%w", err)
	}
	return os.Chmod(path, 0o600)
}

func requirePrivateFile(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("检查身份文件权限：%w", err)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("身份文件 %s 的权限必须为 0600", path)
	}
	return nil
}
