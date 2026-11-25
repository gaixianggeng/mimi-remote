package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

// The command boundary runs before flag.Parse, which can fail before reaching
// --json. Existing human-readable errors remain available to legacy callers.
func commandExit(args []string, stdout, stderr io.Writer) int {
	asJSON := onboardingJSONCommand(args)
	notice := stderr
	if asJSON {
		notice = io.Discard
	}
	err := runCommand(args, stdout, stderr, notice)
	if err == nil {
		return 0
	}
	if asJSON {
		diagnostic := commandDiagnostic(args, err)
		_ = json.NewEncoder(stdout).Encode(struct {
			OK    bool                  `json:"ok"`
			Error setup.OnboardingError `json:"error"`
		}{Error: diagnostic})
	} else {
		fmt.Fprintf(stderr, "错误：%v\n", err)
		appendManagedServiceFailure(args, err)
	}
	return 1
}

func onboardingJSONCommand(args []string) bool {
	if len(args) < 3 || !commandBool(args[2:], "json") {
		return false
	}
	switch args[1] {
	case "preflight", "setup", "up", "start", "restart", "pair", "network", "runtime", "workspace":
		return true
	case "doctor":
		return commandBool(args[2:], "fix")
	case "tailcat":
		switch strings.ToLower(strings.TrimSpace(args[2])) {
		case "pair", "enable", "relay-set":
			return true
		case "relay":
			return len(args) > 3 && args[3] == "set"
		}
	}
	return false
}

func commandBool(args []string, name string) bool {
	enabled := false
	for _, arg := range args {
		if arg == "--" {
			break
		}
		key, value, specified := strings.Cut(arg, "=")
		if key != "-"+name && key != "--"+name {
			continue
		}
		enabled = true
		if specified {
			b, err := strconv.ParseBool(value)
			enabled = b || err != nil
		}
	}
	return enabled
}

func onboardingJSONFlags(name string, args []string) bool {
	if name == "doctor" && !commandBool(args, "fix") {
		return false
	}
	if strings.HasPrefix(name, "tailcat ") && name != "tailcat pair" && name != "tailcat enable" && name != "tailcat relay-set" {
		return false
	}
	return commandBool(args, "json")
}

func onboardingFlagSet(name string, args []string) *flag.FlagSet {
	if onboardingJSONFlags(name, args) {
		fs := flag.NewFlagSet(name, flag.ContinueOnError)
		fs.SetOutput(io.Discard)
		return fs
	}
	return flag.NewFlagSet(name, flag.ExitOnError)
}

func parseOnboardingFlags(fs *flag.FlagSet, args []string) error {
	asJSON := onboardingJSONFlags(fs.Name(), args)
	if asJSON {
		fs.SetOutput(io.Discard)
	}
	if err := fs.Parse(args); err != nil {
		return invalidOnboardingRequest(err)
	}
	if fs.Name() == "runtime" && fs.NArg() != 0 {
		return invalidOnboardingRequest(errors.New("runtime 不接受位置参数；含凭据的 Harness 链接只能通过标准输入传入"))
	}
	if asJSON && (fs.NArg() != 0 || fs.Lookup("json").Value.String() != "true") {
		return invalidOnboardingRequest(errors.New("请检查命令参数"))
	}
	return nil
}

type onboardingCommandError struct {
	code, step string
	configured bool
	cause      error
}

func (e *onboardingCommandError) Error() string { return e.cause.Error() }
func (e *onboardingCommandError) Unwrap() error { return e.cause }

func onboardingFailure(code, step string, configured bool, cause error) error {
	var specific *onboardingCommandError
	if errors.As(cause, &specific) {
		return cause
	}
	return &onboardingCommandError{code, step, configured, cause}
}

func invalidOnboardingRequest(cause error) error {
	return onboardingFailure("invalid_request", "config_store", false, cause)
}

func commandDiagnostic(args []string, err error) setup.OnboardingError {
	var save *setup.SaveError
	if errors.As(err, &save) {
		d := setup.OnboardingDiagnostic(save.Code, save.Step, "setup", save.Code != "config_missing", "")
		d.ConfigPath = save.ConfigPath
		d.RecoveryPath = save.RecoveryPath
		return d
	}
	var typed *onboardingCommandError
	if errors.As(err, &typed) {
		return setup.OnboardingDiagnostic(typed.code, typed.step, "pair", typed.configured, "")
	}
	var pair *setup.PairingDiagnostic
	if errors.As(err, &pair) {
		return setup.OnboardingDiagnostic(pair.Code, pair.Step, "pair", true, "")
	}
	if errors.Is(err, config.ErrLegacyAppServerConfiguration) {
		return setup.OnboardingDiagnostic("legacy_codex_residue", "config_store", "pair", true, "")
	}
	var syntax *json.SyntaxError
	var fieldType *json.UnmarshalTypeError
	if errors.As(err, &syntax) || errors.As(err, &fieldType) {
		return setup.OnboardingDiagnostic("config_invalid", "config_store", "pair", true, "")
	}
	step := "config_store"
	if args[1] == "pair" || args[1] == "tailcat" && strings.EqualFold(strings.TrimSpace(args[2]), "pair") {
		step = "network_any"
	}
	code := "internal_error"
	if errors.Is(err, context.DeadlineExceeded) {
		code = "probe_timeout"
	}
	return setup.OnboardingDiagnostic(code, step, "pair", false, "")
}

func workspaceFailure(root string, cause error) error {
	if !filepath.IsAbs(root) {
		return invalidOnboardingRequest(cause)
	}
	if _, code := config.InspectWorkspaceRoot(root); code != "" {
		return onboardingFailure(code, "workspace_root", true, cause)
	}
	return cause
}

// Treat an inaccessible destination as configured: a failed stat cannot
// authorize replacing an existing identity.
func onboardingConfigured(path string) bool {
	_, err := os.Lstat(config.ExpandPath(path))
	return !errors.Is(err, os.ErrNotExist)
}

func requireOnboardingConfig(path string) error {
	info, err := os.Lstat(config.ExpandPath(path))
	if errors.Is(err, os.ErrNotExist) {
		return onboardingFailure("config_missing", "config_store", false, err)
	}
	if err != nil {
		return onboardingFailure("config_invalid", "config_store", true, err)
	}
	if !info.Mode().IsRegular() {
		return onboardingFailure("config_invalid", "config_store", true, errors.New("配置必须是普通文件"))
	}
	return nil
}

func prepareRequiredConfig(fs *flag.FlagSet, path string, notice io.Writer) error {
	if err := prepareDefaultConfigMigration(fs, path, notice); err != nil {
		return err
	}
	if fs.Lookup("json").Value.String() == "true" {
		return requireOnboardingConfig(path)
	}
	return nil
}

// Module mutations already validate their arguments before opening the file.
// Classify errors from that exact file, without interpreting diagnostic text.
func moduleConfigFailure(path string, err error) error {
	var typed *onboardingCommandError
	if err == nil || errors.As(err, &typed) {
		return err
	}
	var pe *os.PathError
	if errors.As(err, &pe) && errors.Is(err, os.ErrNotExist) {
		requested, resolveErr := filepath.Abs(config.ExpandPath(path))
		if resolveErr == nil && filepath.Clean(pe.Path) == requested {
			return onboardingFailure("config_missing", "config_store", false, err)
		}
	}
	return err
}

func runDoctorFix(ctx context.Context, path string, checkPort bool, current doctor.Results) ([]string, bool, *doctor.Checker, doctor.Results, error) {
	return repairDoctor(ctx, path, checkPort, current, false)
}

func blockedDoctorRebuild(path string, current doctor.Results) error {
	err := errors.New("请检查保留的配置")
	if !onboardingConfigured(path) {
		return onboardingFailure("config_missing", "config_store", false, err)
	}
	if hasFailedCheck(current, "token") {
		return onboardingFailure("config_recovery_required", "config_store", true, err)
	}
	return onboardingFailure("token_rotation_requires_approval", "config_store", true, err)
}
