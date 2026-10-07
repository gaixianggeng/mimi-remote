package appserver

// SharedLocalSessionRepairResult 是一次后台 shared App Server 释放尝试的结果。
type SharedLocalSessionRepairResult struct {
	Released bool   `json:"released"`
	Message  string `json:"message"`
}
