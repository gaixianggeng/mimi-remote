package httpapi

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
	"github.com/gaixianggeng/mimi-remote/internal/session"
)

func messagesFromAppServerThread(thread appServerThread) []codexhistory.Message {
	messages := make([]codexhistory.Message, 0, len(thread.Turns)*2)
	for _, turn := range thread.Turns {
		for _, item := range turn.Items {
			switch item.Type {
			case "userMessage":
				content := textFromUserInputs(item.Content)
				if strings.TrimSpace(content) == "" {
					continue
				}
				messages = append(messages, codexhistory.Message{
					ID:              appServerMessageID(turn.ID, item.ID),
					Role:            "user",
					Content:         content,
					CreatedAt:       turnTime(turn, false),
					ClientMessageID: strings.TrimSpace(item.ClientID),
					Revision:        len(messages) + 1,
				})
			case "agentMessage":
				content := strings.TrimSpace(item.Text)
				if content == "" {
					continue
				}
				messages = append(messages, codexhistory.Message{
					ID:        appServerMessageID(turn.ID, item.ID),
					Role:      "assistant",
					Content:   content,
					CreatedAt: turnTime(turn, true),
					Revision:  len(messages) + 1,
				})
			}
		}
	}
	return messages
}

func textFromUserInputs(inputs []appServerUserInput) string {
	parts := make([]string, 0, len(inputs))
	for _, input := range inputs {
		if input.Type == "text" && strings.TrimSpace(input.Text) != "" {
			parts = append(parts, input.Text)
		}
	}
	return strings.Join(parts, "\n")
}

func turnTime(turn appServerTurn, preferCompleted bool) time.Time {
	if preferCompleted && turn.CompletedAt != nil && *turn.CompletedAt > 0 {
		return unixTime(*turn.CompletedAt)
	}
	if turn.StartedAt != nil && *turn.StartedAt > 0 {
		return unixTime(*turn.StartedAt)
	}
	if turn.CompletedAt != nil && *turn.CompletedAt > 0 {
		return unixTime(*turn.CompletedAt)
	}
	return time.Time{}
}

func appServerMessageID(turnID string, itemID string) string {
	return "appserver:" + strings.TrimSpace(turnID) + ":" + strings.TrimSpace(itemID)
}

func runtimeMessageID(turnID string, itemID string) string {
	turnID = strings.TrimSpace(turnID)
	itemID = strings.TrimSpace(itemID)
	if turnID == "" || itemID == "" {
		return itemID
	}
	return appServerMessageID(turnID, itemID)
}

type appServerMessageCursor struct {
	Index int `json:"index"`
}

func paginateAppServerMessages(messages []codexhistory.Message, before string, limit int) codexhistory.MessagePage {
	if limit <= 0 {
		limit = defaultRuntimeMessagePage
	}
	end := decodeAppServerMessageCursor(before, len(messages))
	if end < 0 || end > len(messages) {
		end = len(messages)
	}
	start := end - limit
	if start < 0 {
		start = 0
	}
	page := append([]codexhistory.Message(nil), messages[start:end]...)
	previousCursor := ""
	hasMore := start > 0
	if hasMore {
		previousCursor = encodeAppServerMessageCursor(start)
	}
	if page == nil {
		page = []codexhistory.Message{}
	}
	return codexhistory.MessagePage{Messages: page, PreviousCursor: previousCursor, HasMoreBefore: hasMore}
}

func decodeAppServerMessageCursor(raw string, fallback int) int {
	if strings.TrimSpace(raw) == "" {
		return fallback
	}
	data, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return fallback
	}
	var cursor appServerMessageCursor
	if err := json.Unmarshal(data, &cursor); err != nil {
		return fallback
	}
	return cursor.Index
}

func encodeAppServerMessageCursor(index int) string {
	data, err := json.Marshal(appServerMessageCursor{Index: index})
	if err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(data)
}

func diffSummaryFromParams(params map[string]any) map[string]any {
	files := []map[string]any{}
	if rawChanges, ok := params["changes"].([]any); ok {
		for _, raw := range rawChanges {
			change, ok := asStringAnyMap(raw)
			if !ok {
				continue
			}
			path := stringParam(change, "path")
			if path == "" {
				continue
			}
			files = append(files, map[string]any{
				"path":   path,
				"status": firstNonEmpty(stringParam(change, "kind"), "updated"),
			})
		}
	}
	if len(files) == 1 {
		return map[string]any{
			"path":   files[0]["path"],
			"status": files[0]["status"],
			"files":  files,
		}
	}
	if len(files) > 1 {
		return map[string]any{
			"path":   "workspace",
			"status": "updated",
			"files":  files,
		}
	}
	return map[string]any{
		"path":   firstNonEmpty(stringParam(params, "path"), nestedStringParam(params, "fileChange", "path"), "workspace"),
		"status": firstNonEmpty(stringParam(params, "status"), "updated"),
	}
}

func unixTime(seconds int64) time.Time {
	if seconds <= 0 {
		return time.Time{}
	}
	return time.Unix(seconds, 0).UTC()
}

func stringParam(params map[string]any, key string) string {
	value, ok := params[key]
	if !ok || value == nil {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	default:
		return strings.TrimSpace(fmt.Sprint(typed))
	}
}

func rawStringParam(params map[string]any, key string) string {
	value, ok := params[key]
	if !ok || value == nil {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return typed
	default:
		return fmt.Sprint(typed)
	}
}

func mapParam(params map[string]any, key string) map[string]any {
	value, ok := params[key]
	if !ok {
		return nil
	}
	out, _ := asStringAnyMap(value)
	return out
}

func asStringAnyMap(value any) (map[string]any, bool) {
	switch typed := value.(type) {
	case map[string]any:
		return typed, true
	default:
		return nil, false
	}
}

func int64Param(params map[string]any, key string) int64 {
	value, ok := params[key]
	if !ok || value == nil {
		return 0
	}
	switch typed := value.(type) {
	case int:
		return int64(typed)
	case int64:
		return typed
	case float64:
		return int64(typed)
	case json.Number:
		n, _ := typed.Int64()
		return n
	default:
		return 0
	}
}

func int64PtrParam(params map[string]any, key string) *int64 {
	if params == nil || params[key] == nil {
		return nil
	}
	value := int64Param(params, key)
	return &value
}

func float64PtrParam(params map[string]any, key string) *float64 {
	value, ok := params[key]
	if !ok || value == nil {
		return nil
	}
	var out float64
	switch typed := value.(type) {
	case int:
		out = float64(typed)
	case int64:
		out = float64(typed)
	case float64:
		out = typed
	case json.Number:
		parsed, err := typed.Float64()
		if err != nil {
			return nil
		}
		out = parsed
	default:
		return nil
	}
	return &out
}

func boolPtrParam(params map[string]any, key string) *bool {
	value, ok := params[key]
	if !ok || value == nil {
		return nil
	}
	typed, ok := value.(bool)
	if !ok {
		return nil
	}
	return &typed
}

func usageSummaryFromPayload(params map[string]any) *session.UsageSummary {
	usage := mapParam(params, "tokenUsage")
	if usage == nil {
		usage = params
	}
	total := mapParam(usage, "total")
	if total == nil {
		total = usage
	}
	summary := &session.UsageSummary{
		InputTokens:  int64Param(total, "inputTokens"),
		OutputTokens: int64Param(total, "outputTokens"),
		TotalTokens:  int64Param(total, "totalTokens"),
	}
	if summary.InputTokens == 0 && summary.OutputTokens == 0 && summary.TotalTokens == 0 {
		return nil
	}
	return summary
}

func rateLimitSummaryFromPayload(params map[string]any) *session.RateLimitSummary {
	if byLimitID := mapParam(params, "rateLimitsByLimitId"); byLimitID != nil {
		if codex, ok := asStringAnyMap(byLimitID["codex"]); ok {
			if summary := rateLimitSummaryFromSnapshot(codex); summary != nil {
				return summary
			}
		}
		for _, value := range byLimitID {
			if item, ok := asStringAnyMap(value); ok {
				if summary := rateLimitSummaryFromSnapshot(item); summary != nil {
					return summary
				}
			}
		}
	}
	if rateLimits := mapParam(params, "rateLimits"); rateLimits != nil {
		return rateLimitSummaryFromSnapshot(rateLimits)
	}
	return rateLimitSummaryFromSnapshot(params)
}

func rateLimitSummaryFromSnapshot(snapshot map[string]any) *session.RateLimitSummary {
	if snapshot == nil {
		return nil
	}
	primary := mapParam(snapshot, "primary")
	secondary := mapParam(snapshot, "secondary")
	credits := mapParam(snapshot, "credits")
	summary := &session.RateLimitSummary{
		LimitID:              stringParam(snapshot, "limitId"),
		LimitName:            stringParam(snapshot, "limitName"),
		PlanType:             stringParam(snapshot, "planType"),
		ReachedType:          stringParam(snapshot, "rateLimitReachedType"),
		PrimaryUsedPercent:   float64PtrParam(primary, "usedPercent"),
		SecondaryUsedPercent: float64PtrParam(secondary, "usedPercent"),
		PrimaryResetsAt:      int64PtrParam(primary, "resetsAt"),
		SecondaryResetsAt:    int64PtrParam(secondary, "resetsAt"),
		HasCredits:           boolPtrParam(credits, "hasCredits"),
		CreditsUnlimited:     boolPtrParam(credits, "unlimited"),
		CreditBalance:        stringParam(credits, "balance"),
	}
	if summary.LimitID == "" && summary.LimitName == "" && summary.PlanType == "" &&
		summary.PrimaryUsedPercent == nil && summary.SecondaryUsedPercent == nil &&
		summary.HasCredits == nil && summary.CreditBalance == "" {
		return nil
	}
	return summary
}

func approvalSummaryFromEvent(payload map[string]any) *session.ApprovalSummary {
	if payload == nil {
		return nil
	}
	id := firstNonEmpty(stringParam(payload, "id"), stringParam(payload, "approval_id"))
	title := stringParam(payload, "title")
	kind := stringParam(payload, "kind")
	if id == "" || title == "" {
		return nil
	}
	return &session.ApprovalSummary{ID: id, Title: title, Kind: kind, Count: 1}
}

func cloneUsageSummary(in *session.UsageSummary) *session.UsageSummary {
	if in == nil {
		return nil
	}
	out := *in
	if in.CostUSD != nil {
		cost := *in.CostUSD
		out.CostUSD = &cost
	}
	return &out
}

func cloneApprovalSummary(in *session.ApprovalSummary) *session.ApprovalSummary {
	if in == nil {
		return nil
	}
	out := *in
	return &out
}

func cloneRateLimitSummary(in *session.RateLimitSummary) *session.RateLimitSummary {
	if in == nil {
		return nil
	}
	out := *in
	if in.PrimaryUsedPercent != nil {
		value := *in.PrimaryUsedPercent
		out.PrimaryUsedPercent = &value
	}
	if in.SecondaryUsedPercent != nil {
		value := *in.SecondaryUsedPercent
		out.SecondaryUsedPercent = &value
	}
	if in.PrimaryResetsAt != nil {
		value := *in.PrimaryResetsAt
		out.PrimaryResetsAt = &value
	}
	if in.SecondaryResetsAt != nil {
		value := *in.SecondaryResetsAt
		out.SecondaryResetsAt = &value
	}
	if in.HasCredits != nil {
		value := *in.HasCredits
		out.HasCredits = &value
	}
	if in.CreditsUnlimited != nil {
		value := *in.CreditsUnlimited
		out.CreditsUnlimited = &value
	}
	return &out
}

func cloneContextSnapshot(in *session.ContextSnapshot) *session.ContextSnapshot {
	if in == nil {
		return nil
	}
	out := *in
	if in.Status != nil {
		status := *in.Status
		status.ActiveFlags = append([]string(nil), in.Status.ActiveFlags...)
		out.Status = &status
	}
	if in.Environment != nil {
		environment := *in.Environment
		out.Environment = &environment
	}
	if in.Git != nil {
		git := *in.Git
		out.Git = &git
	}
	out.Tasks = append([]session.ContextTask(nil), in.Tasks...)
	out.Sources = append([]session.ContextSource(nil), in.Sources...)
	out.Subagents = append([]session.ContextSubagent(nil), in.Subagents...)
	return &out
}

func mergeContextSnapshots(base *session.ContextSnapshot, update *session.ContextSnapshot) *session.ContextSnapshot {
	if base == nil {
		return cloneContextSnapshot(update)
	}
	if update == nil {
		return cloneContextSnapshot(base)
	}
	out := cloneContextSnapshot(base)
	out.SessionID = firstNonEmpty(update.SessionID, out.SessionID)
	out.ThreadID = firstNonEmpty(update.ThreadID, out.ThreadID)
	if update.Status != nil {
		status := *update.Status
		status.ActiveFlags = append([]string(nil), update.Status.ActiveFlags...)
		out.Status = &status
	}
	if update.Environment != nil {
		environment := *update.Environment
		if out.Environment != nil {
			environment.ID = firstNonEmpty(environment.ID, out.Environment.ID)
			environment.Kind = firstNonEmpty(environment.Kind, out.Environment.Kind)
			environment.Label = firstNonEmpty(environment.Label, out.Environment.Label)
			environment.CWD = firstNonEmpty(environment.CWD, out.Environment.CWD)
			environment.Provider = firstNonEmpty(environment.Provider, out.Environment.Provider)
		}
		out.Environment = &environment
	}
	if update.Git != nil {
		git := *update.Git
		out.Git = &git
	}
	out.Tasks = mergeContextTasks(out.Tasks, update.Tasks, maxContextTasks)
	out.Sources = mergeContextSources(out.Sources, update.Sources)
	out.Subagents = mergeContextSubagents(out.Subagents, update.Subagents)
	out.UpdatedAt = update.UpdatedAt
	if out.UpdatedAt.IsZero() {
		out.UpdatedAt = time.Now().UTC()
	}
	return out
}

func mergeContextTasks(base []session.ContextTask, update []session.ContextTask, limit int) []session.ContextTask {
	if len(update) == 0 {
		return append([]session.ContextTask(nil), base...)
	}
	out := make([]session.ContextTask, 0, len(base)+len(update))
	seen := map[string]struct{}{}
	add := func(task session.ContextTask) {
		key := firstNonEmpty(task.ID, task.Kind+":"+task.Title)
		if strings.TrimSpace(key) == "" {
			return
		}
		if _, ok := seen[key]; ok {
			return
		}
		seen[key] = struct{}{}
		out = append(out, task)
	}
	for _, task := range update {
		add(task)
	}
	for _, task := range base {
		add(task)
	}
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

func mergeContextSources(base []session.ContextSource, update []session.ContextSource) []session.ContextSource {
	out := make([]session.ContextSource, 0, len(base)+len(update))
	seen := map[string]struct{}{}
	for _, source := range append(append([]session.ContextSource(nil), update...), base...) {
		key := firstNonEmpty(source.ID, source.Kind+":"+source.Label)
		if key == "" {
			continue
		}
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, source)
	}
	return out
}

func mergeContextSubagents(base []session.ContextSubagent, update []session.ContextSubagent) []session.ContextSubagent {
	out := make([]session.ContextSubagent, 0, len(base)+len(update))
	seen := map[string]struct{}{}
	for _, subagent := range append(append([]session.ContextSubagent(nil), update...), base...) {
		key := firstNonEmpty(subagent.ID, subagent.Nickname+":"+subagent.Role)
		if key == "" {
			continue
		}
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, subagent)
	}
	return out
}

func statusTypeFromSessionStatus(status string) string {
	switch strings.TrimSpace(status) {
	case "waiting_for_approval", "waiting_for_input", "running":
		return "active"
	case "failed":
		return "systemError"
	case "history":
		return "notLoaded"
	case "closed":
		return "idle"
	default:
		return strings.TrimSpace(status)
	}
}

func nestedStringParam(params map[string]any, objectKey string, valueKey string) string {
	object, ok := params[objectKey].(map[string]any)
	if !ok {
		return ""
	}
	return stringParam(object, valueKey)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func firstNonEmptyRaw(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func stringSliceParam(params map[string]any, key string) []string {
	raw, ok := params[key].([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(raw))
	for _, value := range raw {
		text := strings.TrimSpace(fmt.Sprint(value))
		if text != "" {
			out = append(out, text)
		}
	}
	return out
}

func appServerStatusParam(params map[string]any) string {
	status := params["status"]
	switch typed := status.(type) {
	case string:
		return appServerThreadStatusToSessionStatus(typed)
	case map[string]any:
		return appServerThreadStatusValueToSessionStatus(appServerThreadStatus{
			Type:        stringParam(typed, "type"),
			ActiveFlags: stringSliceParam(typed, "activeFlags"),
		})
	default:
		return appServerThreadStatusToSessionStatus(nestedStringParam(params, "thread", "status"))
	}
}

func trimRuntimeRunes(value string, limit int) string {
	if limit <= 0 {
		return ""
	}
	runes := []rune(strings.TrimSpace(value))
	if len(runes) <= limit {
		return string(runes)
	}
	return string(runes[:limit]) + "..."
}

type appServerThreadListResponse struct {
	Data       []appServerThread `json:"data"`
	NextCursor string            `json:"nextCursor"`
}

type appServerThreadEnvelope struct {
	Thread appServerThread `json:"thread"`
}

type appServerTurnEnvelope struct {
	Turn appServerTurn `json:"turn"`
}

type appServerThread struct {
	ID             string                `json:"id"`
	SessionID      string                `json:"sessionId"`
	ForkedFromID   string                `json:"forkedFromId"`
	ParentThreadID string                `json:"parentThreadId"`
	Preview        string                `json:"preview"`
	CWD            string                `json:"cwd"`
	Name           string                `json:"name"`
	ModelProvider  string                `json:"modelProvider"`
	Source         any                   `json:"source"`
	ThreadSource   string                `json:"threadSource"`
	AgentNickname  string                `json:"agentNickname"`
	AgentRole      string                `json:"agentRole"`
	GitInfo        *appServerGitInfo     `json:"gitInfo"`
	CreatedAt      int64                 `json:"createdAt"`
	UpdatedAt      int64                 `json:"updatedAt"`
	Status         appServerThreadStatus `json:"status"`
	Turns          []appServerTurn       `json:"turns"`
}

type appServerThreadStatus struct {
	Type        string   `json:"type"`
	ActiveFlags []string `json:"activeFlags"`
}

func (s *appServerThreadStatus) UnmarshalJSON(data []byte) error {
	var text string
	if err := json.Unmarshal(data, &text); err == nil {
		s.Type = text
		return nil
	}
	var object struct {
		Type        string   `json:"type"`
		ActiveFlags []string `json:"activeFlags"`
	}
	if err := json.Unmarshal(data, &object); err != nil {
		return err
	}
	s.Type = object.Type
	s.ActiveFlags = append([]string(nil), object.ActiveFlags...)
	return nil
}

type appServerGitInfo struct {
	SHA       string `json:"sha"`
	Branch    string `json:"branch"`
	OriginURL string `json:"originUrl"`
}

type appServerTurn struct {
	ID          string                `json:"id"`
	Status      string                `json:"status"`
	StartedAt   *int64                `json:"startedAt"`
	CompletedAt *int64                `json:"completedAt"`
	Items       []appServerThreadItem `json:"items"`
}

type appServerThreadItem struct {
	Type           string                   `json:"type"`
	ID             string                   `json:"id"`
	ClientID       string                   `json:"clientId"`
	Content        []appServerUserInput     `json:"content"`
	Text           string                   `json:"text"`
	Command        string                   `json:"command"`
	CWD            string                   `json:"cwd"`
	ProcessID      string                   `json:"processId"`
	Source         string                   `json:"source"`
	Status         string                   `json:"status"`
	CommandActions []appServerCommandAction `json:"commandActions"`
	ExitCode       *int                     `json:"exitCode"`
	Changes        []appServerFileChange    `json:"changes"`
	Server         string                   `json:"server"`
	Tool           string                   `json:"tool"`
	Namespace      string                   `json:"namespace"`
	PluginID       string                   `json:"pluginId"`
	Arguments      any                      `json:"arguments"`
}

type appServerUserInput struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type appServerCommandAction struct {
	Type    string `json:"type"`
	Command string `json:"command"`
	Name    string `json:"name"`
	Path    string `json:"path"`
	Query   string `json:"query"`
}

type appServerFileChange struct {
	Path string `json:"path"`
	Kind string `json:"kind"`
	Diff string `json:"diff"`
}
