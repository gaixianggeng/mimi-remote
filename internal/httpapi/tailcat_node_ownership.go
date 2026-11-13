package httpapi

import (
	"context"
	"net/http"
)

type tailcatNodeOwnershipRequest struct {
	ChallengeID                string `json:"challengeId"`
	ChallengePublicKey         string `json:"challengePublicKey"`
	MacTailcatPublicKey        string `json:"macTailcatPublicKey"`
	PairingMacTailcatPublicKey string `json:"pairingMacTailcatPublicKey"`
}

type tailcatNodeOwnershipProof struct {
	Mac        string `json:"mac"`
	PairingMac string `json:"pairingMac"`
}

func (s *tailcatSidecarSupervisor) NodeOwnershipProof(ctx context.Context, payload tailcatNodeOwnershipRequest) (tailcatNodeOwnershipProof, error) {
	var proof tailcatNodeOwnershipProof
	err := s.call(ctx, s.controlCallTimeout(), http.MethodPost, "/node-ownership-proof", payload, &proof)
	return proof, err
}

// 和远程启用一样只接受电脑 Bearer。被撤销访问、只有二维码或只有订阅的设备不能取走电脑证明。
func (r *Router) tailcatNodeOwnershipHandler(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var payload tailcatNodeOwnershipRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	prover, ok := r.tailcat.(interface {
		NodeOwnershipProof(context.Context, tailcatNodeOwnershipRequest) (tailcatNodeOwnershipProof, error)
	})
	if !ok {
		writeError(w, http.StatusServiceUnavailable, "请更新电脑端 Mimi 后重新启用")
		return
	}
	proof, err := prover.NodeOwnershipProof(req.Context(), payload)
	if err != nil {
		writeError(w, http.StatusConflict, "设备证明未完成，请在电脑上重新生成配对并重试")
		return
	}
	writeJSON(w, http.StatusOK, proof)
}
