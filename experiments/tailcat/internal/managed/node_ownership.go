package managed

import (
	"encoding/json"
	"errors"
	"net/http"
)

type nodeOwnershipRequest struct {
	ChallengeID                string `json:"challengeId"`
	ChallengePublicKey         string `json:"challengePublicKey"`
	MacTailcatPublicKey        string `json:"macTailcatPublicKey"`
	PairingMacTailcatPublicKey string `json:"pairingMacTailcatPublicKey"`
}

func (m *Manager) nodeOwnershipHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var payload nodeOwnershipRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 4096)).Decode(&payload); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "设备证明请求无效"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	proof := func(host managedHost, expected string) (string, error) {
		prover, ok := host.(interface {
			NodeOwnershipProof(string, string) (string, error)
		})
		if !ok || expected == "" || host.PublicKey() != expected {
			return "", errors.New("连接身份已变化，请重新启用")
		}
		return prover.NodeOwnershipProof(payload.ChallengeID, payload.ChallengePublicKey)
	}
	mac, err := proof(m.host, payload.MacTailcatPublicKey)
	if err != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	pairingMac, err := proof(m.pairHost, payload.PairingMacTailcatPublicKey)
	if err != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"mac": mac, "pairingMac": pairingMac})
}
