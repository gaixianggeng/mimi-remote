package httpapi

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestSharedHostCLIRelayCases(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "contracts", "host-cli", "relay-cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		ID      string        `json:"id"`
		Choice  string        `json:"choice"`
		URL     string        `json:"url"`
		Current tailcatStatus `json:"current"`
		Valid   bool          `json:"valid"`
	}
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		t.Run(tc.ID, func(t *testing.T) {
			server := newRelayTestServer(t)
			fake := &fakeTailcatSidecar{status: tc.Current, configureApplies: true}
			managed := &fakeManagedPairingService{status: tc.Current}
			managed.onConfigureMode = func(bool) { fake.status.Mode = config.TailcatModeManaged }
			managed.onConfigureRelay = func(ctx context.Context, url string) (tailcatStatus, error) {
				return fake.ConfigureRelay(ctx, url, func() error { return nil })
			}
			server.router.tailcat = fake
			server.router.managedPairing = managed
			response := tailcatRelaySetResponse(t, server, tc.Choice, tc.URL)
			want := http.StatusBadRequest
			if tc.Valid {
				want = http.StatusOK
			}
			if response.Code != want {
				t.Fatalf("expected %d, got %d: %s", want, response.Code, response.Body.String())
			}
			if !tc.Valid && (fake.configureCalls != 0 || fake.startCalls != 0 || managed.relayCalls != 0 || managed.modeCalls != 0) {
				t.Fatal("非法中转输入不应启动或修改连接")
			}
		})
	}
}

const hostContractDir = "../../contracts/host-cli"

func contractFile(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(hostContractDir, name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func contractJSON[T any](t *testing.T, data []byte) T {
	t.Helper()
	var out T
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

type wireObject = map[string]any

// Only the draft-07 vocabulary used in this checked-in schema is supported.
// DisallowUnknownFields on load makes adding a keyword require corresponding validation.
type contractSchema struct {
	Dialect                       string `json:"$schema"`
	Title                         string
	Description                   string
	Definitions                   map[string]*contractSchema
	Ref                           string `json:"$ref"`
	Type                          any
	Const                         json.RawMessage
	Enum                          []any
	Required                      []string
	Properties                    map[string]*contractSchema
	PatternProperties             map[string]*contractSchema
	AdditionalProperties          *bool
	Items                         *schemaItems
	Contains                      *contractSchema
	MinItems, MaxItems, MinLength int
	Pattern, Format               string
	AnyOf, OneOf, AllOf           []*contractSchema
	Not, If, Then, Else           *contractSchema
}

type schemaItems struct {
	all   *contractSchema
	tuple []*contractSchema
}

func (s *schemaItems) UnmarshalJSON(raw []byte) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if raw[0] == '[' {
		return d.Decode(&s.tuple)
	}
	return d.Decode(&s.all)
}

func wireType(value any) string {
	switch value.(type) {
	case string:
		return "string"
	case bool:
		return "boolean"
	case nil:
		return "null"
	case []any:
		return "array"
	case wireObject:
		return "object"
	default:
		return "number"
	}
}

func (root *contractSchema) validate(s *contractSchema, value any) error {
	if s == nil {
		return fmt.Errorf("missing schema definition")
	}
	if s.Ref != "" {
		return root.validate(root.Definitions[strings.TrimPrefix(s.Ref, "#/definitions/")], value)
	}
	switch types := s.Type.(type) {
	case string:
		if wireType(value) != types {
			return fmt.Errorf("expected %s", types)
		}
	case []any:
		if !slices.Contains(types, any(wireType(value))) {
			return fmt.Errorf("expected one of %v", types)
		}
	}
	if len(s.Const) != 0 {
		var expected any
		if err := json.Unmarshal(s.Const, &expected); err != nil {
			return err
		}
		if !reflect.DeepEqual(expected, value) {
			return fmt.Errorf("expected %s", s.Const)
		}
	}
	if s.Enum != nil && !slices.ContainsFunc(s.Enum, func(x any) bool { return reflect.DeepEqual(x, value) }) {
		return fmt.Errorf("value outside enum")
	}
	if obj, ok := value.(wireObject); ok {
		for _, key := range s.Required {
			if _, exists := obj[key]; !exists {
				return fmt.Errorf("missing %s", key)
			}
		}
		for key, field := range obj {
			property, known := s.Properties[key]
			if known {
				if err := root.validate(property, field); err != nil {
					return fmt.Errorf("%s: %w", key, err)
				}
			}
			for pattern, rule := range s.PatternProperties {
				matches, err := regexp.MatchString(pattern, key)
				if err != nil {
					return err
				}
				if matches {
					known = true
					if err := root.validate(rule, field); err != nil {
						return fmt.Errorf("%s: %w", key, err)
					}
				}
			}
			if !known && s.AdditionalProperties != nil && !*s.AdditionalProperties {
				return fmt.Errorf("unexpected property %s", key)
			}
		}
	}
	if a, ok := value.([]any); ok {
		if len(a) < s.MinItems || s.MaxItems != 0 && len(a) > s.MaxItems {
			return fmt.Errorf("array length %d", len(a))
		}
		if s.Items != nil {
			for i, item := range a {
				child := s.Items.all
				if i < len(s.Items.tuple) {
					child = s.Items.tuple[i]
				}
				if child == nil {
					continue
				}
				if err := root.validate(child, item); err != nil {
					return fmt.Errorf("[%d]: %w", i, err)
				}
			}
		}
		if s.Contains != nil && !slices.ContainsFunc(a, func(item any) bool { return root.validate(s.Contains, item) == nil }) {
			return fmt.Errorf("missing required array member")
		}
	}
	if text, ok := value.(string); ok {
		if len([]rune(text)) < s.MinLength {
			return fmt.Errorf("string too short")
		}
		if s.Pattern != "" {
			match, err := regexp.MatchString(s.Pattern, text)
			if err != nil || !match {
				return fmt.Errorf("string must match %q", s.Pattern)
			}
		}
		if s.Format != "" {
			if s.Format != "date-time" {
				return fmt.Errorf("unsupported format %s", s.Format)
			}
			if _, err := time.Parse(time.RFC3339Nano, text); err != nil {
				return err
			}
		}
	}
	for _, branch := range s.AllOf {
		if err := root.validate(branch, value); err != nil {
			return err
		}
	}
	matches := func(branches []*contractSchema) int {
		count := 0
		for _, branch := range branches {
			if root.validate(branch, value) == nil {
				count++
			}
		}
		return count
	}
	if s.AnyOf != nil && matches(s.AnyOf) == 0 {
		return fmt.Errorf("no allowed shape matched")
	}
	if s.OneOf != nil && matches(s.OneOf) != 1 {
		return fmt.Errorf("expected exactly one allowed shape")
	}
	if s.Not != nil && root.validate(s.Not, value) == nil {
		return fmt.Errorf("forbidden shape")
	}
	if s.If != nil {
		branch := s.Then
		if root.validate(s.If, value) != nil {
			branch = s.Else
		}
		if branch != nil {
			return root.validate(branch, value)
		}
	}
	return nil
}

type catalogCheck struct {
	ID, Group string
	Platforms []string
}

type fixVariant struct {
	When wireObject
	Fix  wireObject
}

type catalogCode struct {
	Code                       string
	Platforms, Steps, Surfaces []string
	States                     map[string][]string `json:"states_by_stage"`
	Message                    string              `json:"message_zh"`
	Variants                   []fixVariant
	StateRule                  string     `json:"state_rule"`
	SecondaryFix               wireObject `json:"secondary_fix"`
	SecondaryLabel             string     `json:"secondary_label_zh"`
}

type onboardingCatalog struct {
	Schema   string
	Checks   []catalogCheck
	URLs     map[string]string
	Settings []string `json:"settings_targets"`
	Pickers  []string `json:"path_targets"`
	Actions  map[string]struct {
		RequiresConfig *bool  `json:"requires_config"`
		Capability     string `json:"requires_capability"`
		BeforeSave     string `json:"before_save"`
		AfterSave      string `json:"after_save"`
		Assistant      string `json:"assistant"`
	} `json:"run_fix"`
	Wire  []catalogCode `json:"wire_codes"`
	Local []catalogCode `json:"ui_local_codes"`
}

type onboardingContract struct {
	schema  *contractSchema
	catalog onboardingCatalog
	codes   map[string]catalogCode
	checks  map[string]catalogCheck
}

func loadOnboarding(t *testing.T) onboardingContract {
	t.Helper()
	var schema contractSchema
	d := json.NewDecoder(bytes.NewReader(contractFile(t, "onboarding-v1.schema.json")))
	d.DisallowUnknownFields()
	if err := d.Decode(&schema); err != nil {
		t.Fatal(err)
	}
	c := onboardingContract{
		schema: &schema, catalog: contractJSON[onboardingCatalog](t, contractFile(t, "onboarding-codes-v1.json")),
		codes: make(map[string]catalogCode), checks: make(map[string]catalogCheck),
	}
	for _, check := range c.catalog.Checks {
		if _, seen := c.checks[check.ID]; seen {
			t.Fatalf("duplicate check %s", check.ID)
		}
		c.checks[check.ID] = check
	}
	for _, code := range slices.Concat(c.catalog.Wire, c.catalog.Local) {
		if _, seen := c.codes[code.Code]; seen {
			t.Fatalf("duplicate diagnostic %s", code.Code)
		}
		c.codes[code.Code] = code
	}
	return c
}

func (c onboardingContract) shape(name string, value any) error {
	return c.schema.validate(c.schema.Definitions[name], value)
}

func chineseFallback(s any) bool {
	text, ok := s.(string)
	return ok && strings.ContainsFunc(text, func(r rune) bool { return unicode.Is(unicode.Han, r) })
}

func sortedWords(words string) []string {
	return slices.Sorted(slices.Values(strings.Fields(words)))
}

func TestHostCLIContractCatalog(t *testing.T) {
	c := loadOnboarding(t)
	cat := c.catalog
	if c.schema.Dialect != "http://json-schema.org/draft-07/schema#" || cat.Schema != "mimi.onboarding.codes/v1" {
		t.Fatal("unexpected contract version")
	}
	ids := strings.Fields("config_store workspace_root service_owner_conflict service_daemon assistant_codex assistant_claude assistant_agy assistant_deepseek assistant_any network_tailscale network_tailcat network_lan network_any permission_login_item permission_folder_access permission_local_network permission_photos permission_full_disk")
	if len(cat.Checks) != 18 || len(cat.Wire) != 77 || len(cat.Local) != 2 {
		t.Fatalf("counts: checks=%d wire=%d local=%d", len(cat.Checks), len(cat.Wire), len(cat.Local))
	}
	wireIDs := make([]string, 0, len(cat.Wire))
	for i, check := range cat.Checks {
		if check.ID != ids[i] {
			t.Errorf("check %d: got %s want %s", i, check.ID, ids[i])
		}
		platforms := "linux macos windows"
		switch {
		case check.ID == "permission_local_network":
			platforms = "macos windows"
		case check.ID == "service_owner_conflict" || check.Group == "permission":
			platforms = "macos"
		}
		if !slices.Equal(slices.Sorted(slices.Values(check.Platforms)), sortedWords(platforms)) {
			t.Errorf("%s platforms", check.ID)
		}
	}
	for _, entry := range cat.Wire {
		wireIDs = append(wireIDs, entry.Code)
	}
	for name, expected := range map[string][]string{"check_id": ids, "wire_code": wireIDs} {
		if got := c.schema.Definitions[name].Enum; len(got) != len(expected) {
			t.Fatalf("%s enum count", name)
		} else {
			for _, id := range expected {
				if !slices.Contains(got, any(id)) {
					t.Errorf("schema %s missing %s", name, id)
				}
			}
		}
	}
	for _, id := range []string{"command_timeout", "embedded_binary_missing"} {
		if !slices.Equal(c.codes[id].Surfaces, []string{"ui_local"}) || slices.Contains(wireIDs, id) {
			t.Errorf("invalid namespace for %s", id)
		}
	}
	allowedActions := sortedWords("save_setup enable_codex enable_claude enable_agy enable_tailscale enable_lan enable_tailcat connect_deepseek restart_service register_service doctor_fix takeover_homebrew")
	if !slices.Equal(slices.Sorted(maps.Keys(cat.Actions)), allowedActions) {
		t.Fatal("run_fix action set changed")
	}
	for id, action := range cat.Actions {
		draft := slices.Contains(strings.Fields("save_setup enable_codex enable_claude enable_agy"), id)
		if action.RequiresConfig == nil || *action.RequiresConfig == draft {
			t.Errorf("%s requires_config", id)
		}
		if draft && id != "save_setup" {
			if action.BeforeSave != "assistant_draft" || action.AfterSave != "runtime" || action.Assistant != strings.TrimPrefix(id, "enable_") {
				t.Errorf("%s must change only the selected draft before save and its runtime after save", id)
			}
		}
	}
	if cat.Actions["doctor_fix"].Capability != "identity_preserving_doctor_fix" {
		t.Error("doctor_fix lost host capability guard")
	}
	urls := map[string]string{
		"CODEX": "https://learn.chatgpt.com/docs/codex/cli", "CLAUDE": "https://code.claude.com/docs/en/quickstart",
		"AGY": "https://antigravity.google/", "HARNESS": "https://github.com/deepseek-ai/deepseek-harness",
		"TS": "https://tailscale.com/download", "DESKTOP": "https://github.com/gaixianggeng/mimi-remote/releases/latest",
		"GUIDE": "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/quickstart.md",
	}
	if !maps.Equal(cat.URLs, urls) {
		t.Fatal("URL allowlist changed")
	}
	if !slices.Equal(slices.Sorted(slices.Values(cat.Settings)), sortedWords("login_items files_and_folders local_network photos full_disk_access windows_firewall windows_network_profile assistants connections host_recovery date_time managed_connection")) ||
		!slices.Equal(slices.Sorted(slices.Values(cat.Pickers)), sortedWords("workspace_root codex_bin claude_bin agy_bin")) {
		t.Fatal("settings or path picker allowlist changed")
	}
	fixFields := map[string]string{"open_url": "url", "open_settings": "target", "choose_path": "target", "run_fix": "action", "retry": "", "skip": ""}
	fixValues := map[string][]string{"open_url": slices.Sorted(maps.Values(urls)), "open_settings": cat.Settings, "choose_path": cat.Pickers, "run_fix": allowedActions}
	for _, branch := range c.schema.Definitions["fix"].OneOf {
		kind := string(bytes.Trim(branch.Properties["kind"].Const, `"`))
		key, known := fixFields[kind]
		if !known || branch.AdditionalProperties == nil || *branch.AdditionalProperties {
			t.Fatalf("unexpected or open fix shape %q", kind)
		}
		delete(fixFields, kind)
		required := []string{"kind"}
		if key != "" {
			required = append(required, key)
			enum := branch.Properties[key].Enum
			if len(enum) != len(fixValues[kind]) {
				t.Fatalf("%s allowlist size", kind)
			}
			for _, v := range fixValues[kind] {
				if !slices.Contains(enum, any(v)) {
					t.Errorf("%s missing value %s", kind, v)
				}
			}
		}
		if len(branch.Properties) != len(required) || !slices.Equal(slices.Sorted(slices.Values(branch.Required)), slices.Sorted(slices.Values(required))) {
			t.Errorf("invalid fields for %s", kind)
		}
	}
	if len(fixFields) > 0 {
		t.Fatalf("missing fix kinds: %v", fixFields)
	}
	for _, entry := range c.codes {
		if !chineseFallback(entry.Message) || len(entry.Steps) == 0 || len(entry.Surfaces) == 0 || len(entry.Platforms) == 0 || len(entry.Variants) == 0 {
			t.Errorf("incomplete catalog entry %s", entry.Code)
		}
		for _, step := range entry.Steps {
			if _, exists := c.checks[step]; !exists && !(step == "*" && slices.Contains([]string{"probe_timeout", "internal_error", "command_timeout"}, entry.Code)) {
				t.Errorf("%s: unexpected step %s", entry.Code, step)
			}
		}
		for _, v := range entry.Variants {
			if err := c.shape("fix", v.Fix); err != nil {
				t.Errorf("%s fix: %v", entry.Code, err)
			}
			for k := range v.When {
				if !slices.Contains([]string{"stage", "configured", "step", "surface", "recommended_transport"}, k) {
					t.Errorf("%s unknown variant condition %s", entry.Code, k)
				}
			}
		}
		if strings.HasSuffix(entry.Code, "_signed_out") && (entry.StateRule != "signed_out_states" || !reflect.DeepEqual(entry.SecondaryFix, wireObject{"kind": "retry"}) || entry.SecondaryLabel != "我已登录，重新检查") {
			t.Errorf("%s signed-out controls", entry.Code)
		}
	}
}

func (c onboardingContract) diagnostic(code, step string, fix wireObject, context wireObject, state string) (int, error) {
	entry, ok := c.codes[code]
	if !ok {
		return -1, fmt.Errorf("unknown diagnostic %q", code)
	}
	surface := context["surface"].(string)
	platform := context["platform"].(string)
	if surface == "native" && platform != "macos" {
		return -1, fmt.Errorf("native overlay requires macOS evidence")
	}
	if !slices.Contains(entry.Surfaces, surface) || !slices.Contains(entry.Platforms, platform) || !slices.Contains(c.checks[step].Platforms, platform) {
		return -1, fmt.Errorf("%s unavailable on %s/%s/%s", code, surface, platform, step)
	}
	if !slices.Contains(entry.Steps, step) && !slices.Equal(entry.Steps, []string{"*"}) {
		return -1, fmt.Errorf("%s cannot use step %s", code, step)
	}
	if state != "" && !slices.Contains(entry.States[context["stage"].(string)], state) {
		return -1, fmt.Errorf("%s cannot use state %s", code, state)
	}
	matched := -1
	for i, variant := range entry.Variants {
		matches := true
		for key, want := range variant.When {
			got, present := context[key]
			if key == "step" {
				got, present = step, true
			}
			if !present || !reflect.DeepEqual(got, want) {
				matches = false
				break
			}
		}
		if matches {
			if matched >= 0 {
				return -1, fmt.Errorf("ambiguous %s variants", code)
			}
			matched = i
		}
	}
	if matched < 0 || !reflect.DeepEqual(entry.Variants[matched].Fix, fix) {
		return -1, fmt.Errorf("mismatched fix for %s at %s", code, step)
	}
	if action, ok := fix["action"].(string); ok {
		metadata := c.catalog.Actions[action]
		if metadata.RequiresConfig == nil || *metadata.RequiresConfig && context["configured"] != true {
			return -1, fmt.Errorf("action requires configuration")
		}
		if metadata.Capability != "" && context["verified_capability"] != metadata.Capability {
			return -1, fmt.Errorf("unverified host capability for %s", action)
		}
		if slices.Contains([]string{"enable_lan", "enable_tailscale", "enable_tailcat"}, action) && context["stage"] != "pair" {
			return -1, fmt.Errorf("transport enable outside pair stage")
		}
	}
	return matched, nil
}

func (c onboardingContract) check(row, context wireObject) error {
	if err := c.shape("check", row); err != nil {
		return err
	}
	id, state := row["id"].(string), row["state"].(string)
	code, _ := row["code"].(string)
	check := c.checks[id]
	if context["surface"] == "native" {
		permission := check.Group == "permission"
		approval := id == "service_daemon" && code == "service_requires_approval"
		if context["platform"] != "macos" || !(permission || approval) {
			return fmt.Errorf("invalid native overlay on %s", id)
		}
	}
	if !slices.Contains(check.Platforms, context["platform"].(string)) || check.Group != row["group"] {
		return fmt.Errorf("%s group or platform mismatch", id)
	}
	if !chineseFallback(row["title"]) || !chineseFallback(row["detail"]) {
		return fmt.Errorf("missing Chinese check fallback")
	}
	if candidates, ok := row["candidates"].([]any); ok {
		selected := 0
		for _, candidate := range candidates {
			if candidate.(wireObject)["outcome"] == "selected" {
				selected++
			}
		}
		needsSelection := state == "ok" || strings.HasSuffix(code, "_signed_out") || code == "assistant_disabled"
		if selected > 1 || needsSelection && selected != 1 {
			return fmt.Errorf("invalid selected candidate count %d for %s", selected, id)
		}
	}
	if code == "" {
		return nil
	}
	pair := context["stage"] == "pair"
	switch id {
	case "config_store", "workspace_root":
		if row["blocking"] != (pair || state == "error") {
			return fmt.Errorf("inconsistent required directory/config blocker")
		}
	case "assistant_any", "network_any", "service_daemon":
		if row["blocking"] != pair {
			return fmt.Errorf("inconsistent pair blocker %s", id)
		}
	}
	fix := row["fix"].(wireObject)
	if _, err := c.diagnostic(code, id, fix, context, state); err != nil {
		return err
	}
	if strings.HasSuffix(code, "_signed_out") {
		explicit, known := context["explicitly_enabled"].(bool)
		if context["stage"] == "pair" || known {
			enabled := row["enabled"] == true
			if context["stage"] == "setup" {
				enabled = explicit
			}
			if (state == "action_needed") != enabled {
				return fmt.Errorf("incorrect signed-out state")
			}
		}
	}
	return nil
}

func (c onboardingContract) report(report wireObject, observation wireObject) error {
	if err := c.shape("report", report); err != nil {
		return err
	}
	rows := report["checks"].([]any)
	platform := observation["platform"].(string)
	var applicable []string
	for _, check := range c.catalog.Checks {
		if slices.Contains(check.Platforms, platform) {
			applicable = append(applicable, check.ID)
		}
	}
	if len(applicable) != len(rows) {
		return fmt.Errorf("expected %d %s rows, got %d", len(applicable), platform, len(rows))
	}
	stage := report["stage"]
	context := wireObject{"platform": platform, "stage": stage, "configured": report["configured"], "recommended_transport": report["recommended_transport"], "verified_capability": observation["verified_capability"]}
	firstBlocker := ""
	eligible := map[string]bool{}
	var recommended any
	for i, item := range rows {
		row := item.(wireObject)
		id := applicable[i]
		if row["id"] != id {
			return fmt.Errorf("expected %s at index %d", id, i)
		}
		if row["state"] == "checking" {
			return fmt.Errorf("unfinished %s", id)
		}
		context["surface"] = "check"
		if observation["native_overlay"] == true && (strings.HasPrefix(id, "permission_") || id == "service_daemon" && row["code"] == "service_requires_approval") {
			context["surface"] = "native"
		}
		if err := c.check(row, context); err != nil {
			return fmt.Errorf("%s: %w", id, err)
		}
		group := row["group"].(string)
		if row["blocking"] == true {
			if stage == "setup" && group != "workspace" {
				return fmt.Errorf("unexpected setup blocker %s", id)
			}
			if firstBlocker == "" {
				firstBlocker = id
			}
		}
		switch id {
		case "assistant_codex", "assistant_claude", "assistant_agy", "assistant_deepseek",
			"network_tailscale", "network_tailcat", "network_lan":
			ready := row["enabled"] == true && row["available"] == true
			if (row["state"] == "ok") != ready {
				return fmt.Errorf("%s intent/availability mismatch", id)
			}
			eligible[group] = eligible[group] || ready
			if group == "network" && recommended == nil && row["available"] == true {
				recommended = strings.TrimPrefix(id, "network_")
			}
		}
		if id == "assistant_any" || id == "network_any" {
			if (row["state"] == "ok") != eligible[group] || row["blocking"] != (stage == "pair" && !eligible[group]) {
				return fmt.Errorf("%s eligibility mismatch", id)
			}
		}
		if stage == "pair" && id == "service_daemon" && row["blocking"] != (row["state"] != "ok") {
			return fmt.Errorf("daemon readiness mismatch")
		}
	}
	if report["recommended_transport"] != recommended {
		return fmt.Errorf("unexpected transport recommendation")
	}
	if report["ok"] != (firstBlocker == "") {
		return fmt.Errorf("report ok inconsistent with blockers")
	}
	next := firstBlocker
	if next == "" {
		next = "network_any"
		if stage == "setup" && report["configured"] == false {
			next = "config_store"
		}
	}
	if report["recommended_next"] != next {
		return fmt.Errorf("expected next %s", next)
	}
	return nil
}

func (c onboardingContract) envelope(obj, context wireObject) error {
	surface := context["surface"].(string)
	if surface == "ui_local" {
		surface = "local"
	}
	if err := c.shape(surface+"_error", obj); err != nil {
		return err
	}
	body := obj["error"].(wireObject)
	code, ok := body["code"].(string)
	if !ok || !chineseFallback(body["message"]) {
		return fmt.Errorf("missing diagnostic or Chinese fallback")
	}
	_, err := c.diagnostic(code, body["step"].(string), body["fix"].(wireObject), context, "")
	return err
}

type fixtureSpec struct {
	file, kind, platform, code string
}

var onboardingFixtures = []fixtureSpec{
	{"preflight-all-green.json", "report", "macos", ""},
	{"preflight-claude-only-no-network.json", "report", "linux", ""},
	{"preflight-codex-chatgpt-app.json", "report", "macos", ""},
	{"preflight-permission-needed.json", "report", "macos", ""},
	{"preflight-deepseek-only.json", "report", "linux", ""},
	{"preflight-windows-public.json", "report", "windows", ""},
	{"preflight-progress-slow-assistant.ndjson", "progress", "macos", ""},
	{"setup-ok-no-assistant.json", "setup", "", ""},
	{"setup-ok-pairing-deferred.json", "setup", "", ""},
	{"setup-error-config-invalid.json", "cli_error", "", "config_invalid"},
	{"setup-error-config-concurrent-change.json", "cli_error", "", "config_concurrent_change"},
	{"up-ok-ready.json", "ready", "", ""},
	{"up-error-service-start-timeout.json", "cli_error", "", "service_start_timeout"},
	{"pair-ok-direct.json", "ticket", "", ""},
	{"pair-ok-tailcat.json", "ticket", "", ""},
	{"pair-error-no-enabled-assistant.json", "cli_error", "", "no_enabled_assistant"},
	{"pair-error-expired.json", "http_error", "", "pair_ticket_expired"},
	{"onboarding-error-cases.json", "cases", "", ""},
}

func TestHostCLIContractFixtures(t *testing.T) {
	c := loadOnboarding(t)
	names := []string{"status-ready.json", "relay-cases.json", "onboarding-codes-v1.json", "onboarding-v1.schema.json"}
	for _, f := range onboardingFixtures {
		names = append(names, f.file)
	}
	files, err := os.ReadDir(hostContractDir)
	if err != nil {
		t.Fatal(err)
	}
	var actual []string
	for _, file := range files {
		if ext := filepath.Ext(file.Name()); ext == ".json" || ext == ".ndjson" {
			actual = append(actual, file.Name())
		}
	}
	if len(onboardingFixtures) != 18 || !slices.Equal(slices.Sorted(slices.Values(names)), actual) {
		t.Fatalf("fixture manifest differs from directory: %v", actual)
	}
	for _, f := range onboardingFixtures {
		t.Run(f.file, func(t *testing.T) {
			raw := contractFile(t, f.file)
			switch f.kind {
			case "progress":
				c.testProgress(t, raw)
				return
			case "cases":
				c.testCases(t, raw)
				return
			}
			obj := contractJSON[wireObject](t, raw)
			if err := fixturePrivacy(obj, f.kind == "ticket"); err != nil {
				t.Fatal(err)
			}
			if err := c.shape(f.kind, obj); err != nil {
				t.Fatal(err)
			}
			switch f.kind {
			case "report":
				observation := wireObject{"platform": f.platform, "native_overlay": f.file == "preflight-permission-needed.json"}
				if err := c.report(obj, observation); err != nil {
					t.Fatal(err)
				}
				checkScenario(t, f.file, obj)
			case "setup":
				if _, ok := obj["pair_url"]; ok {
					t.Fatal("unexpected ticket on save")
				}
				if (obj["pairing_deferred"] == true) != (f.file == "setup-ok-pairing-deferred.json") {
					t.Fatal("incorrect deferral")
				}
			case "ticket":
				if err := fixtureTicket(obj, f.file == "pair-ok-tailcat.json"); err != nil {
					t.Fatal(err)
				}
			case "http_error", "cli_error":
				context := wireObject{"platform": "macos", "surface": strings.TrimSuffix(f.kind, "_error"), "configured": true, "stage": "pair"}
				if strings.HasPrefix(f.file, "setup-") {
					context["stage"] = "setup"
				}
				if err := c.envelope(obj, context); err != nil {
					t.Fatal(err)
				}
				if obj["error"].(wireObject)["code"] != f.code {
					t.Fatalf("expected %s", f.code)
				}
			}
		})
	}
	// Both legacy documents have their own wire formats and are still shared with older readers.
	for _, f := range []string{"relay-cases.json", "status-ready.json"} {
		if err := fixturePrivacy(contractJSON[any](t, contractFile(t, f)), false); err != nil {
			t.Errorf("%s: %v", f, err)
		}
	}
}

func checkScenario(t *testing.T, name string, report wireObject) {
	t.Helper()
	rows := map[string]wireObject{}
	for _, r := range report["checks"].([]any) {
		v := r.(wireObject)
		rows[v["id"].(string)] = v
	}
	solo := func(id string) bool {
		for _, r := range rows {
			if r["group"] == "assistant" && r["id"] != "assistant_any" && (r["state"] == "ok") != (r["id"] == id) {
				return false
			}
		}
		return true
	}
	switch name {
	case "preflight-all-green.json":
		for _, r := range rows {
			if r["state"] != "ok" {
				t.Fatal("expected an all-green check")
			}
		}
	case "preflight-claude-only-no-network.json":
		if !solo("assistant_claude") || report["ok"] != true || report["configured"] != false || report["stage"] != "setup" || rows["network_any"]["code"] != "no_direct_network" {
			t.Fatal("expected fresh offline Claude setup")
		}
	case "preflight-codex-chatgpt-app.json":
		for _, candidate := range rows["assistant_codex"]["candidates"].([]any) {
			v := candidate.(wireObject)
			if v["outcome"] == "selected" && strings.HasSuffix(v["path"].(string), "/ChatGPT.app/Contents/Resources/codex-cli/bin/codex") {
				return
			}
		}
		t.Fatal("missing selected ChatGPT bundle CLI")
	case "preflight-permission-needed.json":
		if rows["service_daemon"]["code"] != "service_requires_approval" || report["ok"] != false {
			t.Fatal("expected pending agent approval")
		}
	case "preflight-deepseek-only.json":
		if !solo("assistant_deepseek") || report["ok"] != true {
			t.Fatal("expected DeepSeek-only readiness")
		}
	case "preflight-windows-public.json":
		if rows["network_lan"]["code"] != "lan_public_network_blocked" || rows["network_lan"]["available"] != false {
			t.Fatal("expected blocked public LAN")
		}
	}
}

func (c onboardingContract) testProgress(t *testing.T, raw []byte) {
	t.Helper()
	report := contractJSON[wireObject](t, contractFile(t, "preflight-codex-chatgpt-app.json"))
	final := report["checks"].([]any)
	context := wireObject{"platform": "macos", "surface": "check", "stage": "pair", "configured": true, "recommended_transport": report["recommended_transport"]}
	done := map[string]wireObject{}
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	count := 0
	for scanner.Scan() {
		row := contractJSON[wireObject](t, scanner.Bytes())
		if err := fixturePrivacy(row, false); err != nil {
			t.Fatal(err)
		}
		if err := c.check(row, context); err != nil {
			t.Fatalf("progress line %d: %v", count+1, err)
		}
		id := row["id"].(string)
		if count < len(final) {
			if id != final[count].(wireObject)["id"] || row["state"] != "checking" || row["available"] != nil {
				t.Fatalf("invalid initial skeleton %d", count)
			}
		} else {
			if row["state"] == "checking" || done[id] != nil {
				t.Fatalf("invalid completion %s", id)
			}
			switch id {
			case "assistant_any":
				if done["assistant_codex"] == nil || done["assistant_claude"] != nil {
					t.Fatal("assistant aggregate did not follow fast Codex result")
				}
			case "network_any":
				if done["network_tailscale"] == nil || done["assistant_claude"] != nil {
					t.Fatal("network aggregate waited for unrelated slow assistant")
				}
			}
			done[id] = row
		}
		count++
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if count != 2*len(final) {
		t.Fatalf("incomplete progress: %d rows", count)
	}
	for _, item := range final {
		row := item.(wireObject)
		if !reflect.DeepEqual(done[row["id"].(string)], row) {
			t.Errorf("progress differs from final %s row", row["id"])
		}
	}
}

// The report examples apply RFC 6902 edits to a named fixture. Keep this
// reader limited to the top-level fields and the checks array used here.
type reportPatch struct {
	Op, Path string
	Value    any
}

func patchedReport(t *testing.T, file string, patch []reportPatch) wireObject {
	t.Helper()
	if !slices.ContainsFunc(onboardingFixtures, func(f fixtureSpec) bool { return f.file == file && f.kind == "report" }) {
		t.Fatalf("unknown base report %q", file)
	}
	report := contractJSON[wireObject](t, contractFile(t, file))
	for _, p := range patch {
		key, ok := strings.CutPrefix(p.Path, "/")
		if !ok {
			t.Fatal("invalid patch path")
		}
		if indexPath, found := strings.CutPrefix(key, "checks/"); found {
			items := report["checks"].([]any)
			if indexPath == "-" && p.Op == "add" {
				report["checks"] = append(items, p.Value)
				continue
			}
			index, field, nested := strings.Cut(indexPath, "/")
			n, err := strconv.Atoi(index)
			if err != nil || n < 0 || n >= len(items) {
				t.Fatal("invalid checks index")
			}
			if !nested {
				switch p.Op {
				case "replace":
					items[n] = p.Value
				case "remove":
					report["checks"] = slices.Delete(items, n, n+1)
				default:
					t.Fatalf("unsupported checks patch %v", p)
				}
				continue
			}
			applyFieldPatch(t, items[n].(wireObject), field, p)
		} else {
			applyFieldPatch(t, report, key, p)
		}
	}
	return report
}

func applyFieldPatch(t *testing.T, obj wireObject, key string, p reportPatch) {
	t.Helper()
	if key == "" || strings.Contains(key, "/") {
		t.Fatalf("unsupported path %s", p.Path)
	}
	if _, exists := obj[key]; p.Op != "add" && !exists {
		t.Fatalf("patch path does not exist: %s", p.Path)
	}
	switch p.Op {
	case "add", "replace":
		obj[key] = p.Value
	case "remove":
		delete(obj, key)
	default:
		t.Fatalf("unsupported patch op %s", p.Op)
	}
}

func (c onboardingContract) testCases(t *testing.T, raw []byte) {
	t.Helper()
	type example struct {
		ID               string
		Valid            *bool
		Context, Payload wireObject
		Fixture          string
		Patch            []reportPatch
	}
	examples := contractJSON[[]example](t, raw)
	if err := fixturePrivacy(contractJSON[any](t, raw), false); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	coverage := map[string]bool{}
	for _, e := range examples {
		if _, exists := seen[e.ID]; exists || e.ID == "" || e.Valid == nil {
			t.Fatalf("duplicate or incomplete case %q", e.ID)
		}
		seen[e.ID] = *e.Valid
		t.Run(e.ID, func(t *testing.T) {
			obj := e.Payload
			context := e.Context
			surface := context["surface"]
			var err error
			switch surface {
			case "report":
				obj = patchedReport(t, e.Fixture, e.Patch)
				err = c.report(obj, context)
			case "check", "native":
				err = c.check(obj, context)
			case "cli", "http", "ui_local":
				err = c.envelope(obj, context)
			default:
				t.Fatalf("invalid case surface %v", surface)
			}
			if (err == nil) != *e.Valid {
				t.Fatalf("want valid=%v, got %v", *e.Valid, err)
			}
			if err == nil && surface != "report" {
				row := obj
				step := row["id"]
				if body, ok := obj["error"].(wireObject); ok {
					row = body
					step = body["step"]
				}
				code := row["code"].(string)
				variant, err := c.diagnostic(code, step.(string), row["fix"].(wireObject), context, "")
				if err != nil {
					t.Fatal(err)
				}
				coverage[fmt.Sprintf("%s/%d", code, variant)] = true
			}
		})
	}
	for _, entry := range c.codes {
		for i := range entry.Variants {
			if !coverage[fmt.Sprintf("%s/%d", entry.Code, i)] {
				t.Errorf("missing accepted case for %s variant %d", entry.Code, i)
			}
		}
	}
	for _, id := range strings.Fields(`unknown-major unknown-code mismatched-step unknown-state unknown-action signed-out-native-surface
		unknown-url extra-fix-field legacy-rotation-parameter missing-fix missing-required-row missing-required-field duplicate-row
		ui-code-on-wire host-recovery-on-http config-required-before-save transport-enabled-during-setup mismatched-recommendation
		aggregate-is-not-an-assistant aggregate-is-not-a-transport blocked-pair-unconfirmed-workspace blocked-pair-missing-workspace
		blocked-pair-missing-config setup-missing-root-marked-ready unfinished-final-report optional-login-item-blocks-pair
		native-daemon-claims-readiness native-assistant-override windows-native-permission-override http-nested-local-detail`) {
		if valid, found := seen[id]; !found || valid {
			t.Errorf("missing rejection case %s", id)
		}
	}
	for _, id := range strings.Fields(`additive-data report-additive-field http-additive-nested-data verified-identity-preserving-repair
		enable-codex-in-draft enable-claude-in-draft enable-agy-in-draft`) {
		if !seen[id] {
			t.Errorf("missing acceptance case %s", id)
		}
	}
}

var (
	privateFixtureText = regexp.MustCompile(`(?i)(/users/|/home/|[a-z]:[/\\]users[/\\]|~[/\\]|%userprofile%|\$home[/\\]|bearer[[:space:]]+|-----begin [a-z ]*private key|(?:token|secret|grant|password|api[_-]?key|signature)=|(?:gh[pousr]_|github_pat_|sk-)[a-z0-9_-]{8,}|[a-z0-9_.+-]+@[a-z0-9.-]+\.[a-z]{2,}|\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b|\b(?:[0-9a-f]{8}-[0-9a-f]{16}|[0-9a-f]{32,})\b)`)
	ipv4InText         = regexp.MustCompile(`\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b`)
	credentialField    = regexp.MustCompile(`(?i)(^|_)(token|secret|password|credential|authorization|api_key|grant|signature|pair_sig|device_id|device_name|installation_id|session_id|public_key|private_key|account_id|stderr)($|_)`)
)

func fixturePrivacy(value any, ticket bool) error {
	switch v := value.(type) {
	case []any:
		for i, item := range v {
			if err := fixturePrivacy(item, ticket); err != nil {
				return fmt.Errorf("item %d: %w", i, err)
			}
		}
	case wireObject:
		for key, field := range v {
			if credentialField.MatchString(key) && key != "rotates_token" {
				return fmt.Errorf("private field %s", key)
			}
			if key == "pair_url" {
				if !ticket {
					return fmt.Errorf("pair_url outside a ticket fixture")
				}
				continue // fixtureTicket checks the entire URL and its literal query allowlist.
			}
			if key == "path" || slices.Contains([]string{"config_path", "recovery_path", "scan_root", "browse_root"}, key) {
				path, ok := field.(string)
				if _, patch := v["op"]; !patch && ok {
					normalized := strings.ReplaceAll(path, `\`, "/")
					if !strings.HasPrefix(normalized, "/fixture/") && !strings.HasPrefix(normalized, "C:/fixture/") && normalized != "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex" {
						return fmt.Errorf("non-fixture path in %s", key)
					}
				}
			}
			if err := fixturePrivacy(field, false); err != nil {
				return fmt.Errorf("%s: %w", key, err)
			}
		}
	case string:
		decoded, err := url.PathUnescape(v)
		if err != nil {
			decoded = v
		}
		if privateFixtureText.MatchString(decoded) || strings.Contains(decoded, "mimiremote://") || strings.Contains(decoded, "pair_sig=") {
			return fmt.Errorf("private diagnostic text")
		}
		for _, address := range ipv4InText.FindAllString(decoded, -1) {
			if ip := net.ParseIP(address); ip != nil && address != "127.0.0.1" {
				return fmt.Errorf("non-fixture IPv4 address")
			}
		}
		for _, fragment := range strings.FieldsFunc(decoded, func(r rune) bool { return !strings.ContainsRune("0123456789abcdefABCDEF:", r) }) {
			if strings.Count(fragment, ":") >= 2 && net.ParseIP(fragment) != nil {
				return fmt.Errorf("IPv6 address in fixture")
			}
		}
	}
	return nil
}

func fixtureTicket(obj wireObject, tailcat bool) error {
	endpoint := "https://host.example.invalid:8787"
	network := "tailscale"
	if tailcat {
		endpoint = "http://127.0.0.1:8787"
		network = "tailcat"
	}
	if obj["endpoint"] != endpoint || obj["network"] != network {
		return fmt.Errorf("unexpected fixture endpoint or transport")
	}
	link, err := url.Parse(obj["pair_url"].(string))
	if err != nil || link.Scheme != "mimiremote" || link.Host != "pair" || link.User != nil || link.Path != "" || link.Fragment != "" {
		return fmt.Errorf("invalid fixture pairing URL")
	}
	q, err := url.ParseQuery(link.RawQuery)
	if err != nil {
		return err
	}
	issued, err := time.Parse(time.RFC3339Nano, q.Get("issued_at"))
	if err != nil {
		return fmt.Errorf("invalid issue time")
	}
	expiry, err := time.Parse(time.RFC3339Nano, obj["pair_expires_at"].(string))
	if err != nil || !expiry.After(issued) {
		return fmt.Errorf("invalid fixture ticket lifetime")
	}
	want := url.Values{"endpoint": {endpoint}, "issued_at": {issued.Format(time.RFC3339Nano)}, "expires_at": {obj["pair_expires_at"].(string)}, "pair_sig": {"fixture-signature"}}
	if tailcat {
		want.Set("transport", "tailcat")
		want.Set("relay_service", "default")
		want.Set("tailcat_pair_address", "tc:fixture")
	}
	if !reflect.DeepEqual(want, q) {
		return fmt.Errorf("pairing URL needs matching receipt, synthetic signature and allowed transport fields")
	}
	return nil
}

func TestHostCLIContractBoundaries(t *testing.T) {
	c := loadOnboarding(t)
	for _, kind := range []string{"retry", "skip", "choose_path", "open_settings", "run_fix", "open_url"} {
		fix := wireObject{"kind": kind}
		switch kind {
		case "choose_path":
			fix["target"] = "workspace_root"
		case "open_settings":
			fix["target"] = "connections"
		case "run_fix":
			fix["action"] = "enable_lan"
		case "open_url":
			fix["url"] = c.catalog.URLs["GUIDE"]
		}
		if err := c.shape("fix", fix); err != nil {
			t.Errorf("%s valid shape: %v", kind, err)
		}
		fix["extra"] = true
		if err := c.shape("fix", fix); err == nil {
			t.Errorf("%s accepted extra action parameter", kind)
		}
	}
	ready := wireObject{"ok": true, "start_submitted": true}
	if c.shape("submitted", ready) != nil || c.shape("ready", ready) == nil {
		t.Error("submitted start mistaken for authenticated readiness")
	}
	deferred := contractJSON[wireObject](t, contractFile(t, "setup-ok-pairing-deferred.json"))
	deferred["pair_url"] = "mimiremote://pair?fixture"
	deferred["pair_expires_at"] = "2030-01-01T00:00:00Z"
	deferred["endpoint"] = "https://host.example.invalid"
	if c.shape("setup", deferred) == nil {
		t.Error("deferred save accepted ticket")
	}
	for _, sample := range []any{
		wireObject{"token": "fixture"}, wireObject{"device_id": "fixture"},
		"Bearer fixture-value", "/home/fixture/private", `C:\Users\fixture\code`,
		"http://" + net.IPv4(192, 0, 2, 1).String(), net.ParseIP("2001:db8::1").String(),
		strings.Repeat("ab", 16), wireObject{"pair_url": "fixture"},
	} {
		if fixturePrivacy(sample, false) == nil {
			t.Errorf("privacy check missed sample of type %T", sample)
		}
	}
}
