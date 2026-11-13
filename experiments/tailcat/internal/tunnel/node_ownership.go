package tunnel

import (
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"

	"regexp"
)

// NodeOwnershipProof 只证明当前节点持有私钥。域分离和服务端的一次性挑战阻止证明被挪作连接授权。
func (h *Host) NodeOwnershipProof(challengeID, challengePublicKey string) (string, error) {
	if h == nil || h.server == nil {
		return "", errors.New("连接节点未启动")
	}
	if !regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`).MatchString(challengeID) {
		return "", errors.New("设备证明挑战无效")
	}
	raw, err := base64.RawURLEncoding.DecodeString(challengePublicKey)
	if err != nil || len(raw) != 32 {
		return "", errors.New("设备证明公钥无效")
	}
	publicKey, err := ecdh.X25519().NewPublicKey(raw)
	if err != nil {
		return "", err
	}
	privateRaw := h.server.Key.Raw32()
	privateKey, err := ecdh.X25519().NewPrivateKey(privateRaw[:])
	if err != nil {
		return "", err
	}
	shared, err := privateKey.ECDH(publicKey)
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, shared)
	mac.Write([]byte("mimi-node-ownership-v1\n" + challengeID + "\n" + h.PublicKey()))
	return hex.EncodeToString(mac.Sum(nil)), nil
}
