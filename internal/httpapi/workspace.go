package httpapi

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

type workspaceResolveRequest struct {
	Path string `json:"path"`
}

type workspaceResolveResponse struct {
	Workspace workspaceDescriptor `json:"workspace"`
}

type workspaceDescriptor struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	Path            string `json:"path"`
	RootProjectID   string `json:"root_project_id"`
	RootProjectName string `json:"root_project_name"`
	RootProjectPath string `json:"root_project_path"`
	Trusted         bool   `json:"trusted"`
	CanStartSession bool   `json:"can_start_session"`
}

func (r *Router) workspaceResolveHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload workspaceResolveRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	path := strings.TrimSpace(payload.Path)
	if path == "" {
		writeError(w, http.StatusBadRequest, "path 不能为空")
		return
	}
	scope, ok := r.gatewayScopeForPath(path)
	if !ok {
		// 不区分“不存在”和“不在 allowlist 内”，避免把 resolve 变成远程文件系统探测接口。
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	realPath := scope.realPath
	stat, err := os.Stat(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	if !stat.IsDir() {
		writeError(w, http.StatusBadRequest, "路径不是目录")
		return
	}

	workspaceID := workspaceIDForRealPath(realPath)
	rootProjectID := scope.project.ID
	rootProjectName := scope.project.Name
	rootProjectPath := scope.project.Path
	if scope.browse {
		// browse workspace 不挂在任何项目下：root 字段自指，让客户端把它当独立工作区，
		// gateway 侧按 canonical cwd 精确绑定线程。
		rootProjectID = workspaceID
		rootProjectName = filepath.Base(realPath)
		rootProjectPath = realPath
	}

	writeJSON(w, http.StatusOK, workspaceResolveResponse{
		Workspace: workspaceDescriptor{
			ID:              workspaceID,
			Name:            filepath.Base(realPath),
			Path:            realPath,
			RootProjectID:   rootProjectID,
			RootProjectName: rootProjectName,
			RootProjectPath: rootProjectPath,
			Trusted:         true,
			CanStartSession: true,
		},
	})
}

func workspaceIDForRealPath(realPath string) string {
	sum := sha256.Sum256([]byte(filepath.Clean(realPath)))
	return "ws_" + hex.EncodeToString(sum[:])[:16]
}
