package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
)

func readPublicationBytes(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func requirePublicationError(t *testing.T, err error, code string) *SaveError {
	t.Helper()
	var failure *SaveError
	if !errors.As(err, &failure) || failure.Code != code || failure.Step != "config_store" {
		t.Fatalf("expected %s, got %v", code, err)
	}
	return failure
}

func readPublicationRecord(t *testing.T, path string) publication {
	t.Helper()
	var record publication
	if err := json.Unmarshal(readPublicationBytes(t, config.SetupJournalPath(path)), &record); err != nil {
		t.Fatal(err)
	}
	return record
}

// This path is entered only by the parent test's child process. Exit where the
// config would be renamed so the OS releases the lock but no cleanup defer runs.
func TestSetupPublicationCrashChild(t *testing.T) {
	if os.Getenv("MIMI_SETUP_CRASH_CHILD") != "yes" {
		return
	}
	path := os.Getenv("MIMI_SETUP_CRASH_DESTINATION")
	root := os.Getenv("MIMI_SETUP_CRASH_ROOT")
	opts := Options{ConfigPath: path, ScanRoot: root, LegacyPath: os.Getenv("MIMI_SETUP_CRASH_LEGACY"), SaveOnly: true}
	p, err := readProposal(path, opts.LegacyPath, false)
	if err != nil {
		t.Fatal(err)
	}
	if !p.source.exists {
		if err := p.fresh(opts, interruptedIdentity{}); err != nil {
			t.Fatal(err)
		}
	}
	if err := p.selectRoots(opts); err != nil {
		t.Fatal(err)
	}
	if p.companion == "" {
		// Unix setup needs no WS credential. Exercise the same two-file
		// publication protocol with an isolated private companion.
		p.companion = filepath.Join(filepath.Dir(path), "app-server-ws-token-fixture-interrupted")
		p.token = []byte("isolated test companion\n")
	}
	raw, err := p.bytes()
	if err != nil {
		t.Fatal(err)
	}
	ops := defaultSetupFileTransactionOps()
	syncDir := ops.syncDir
	ops.syncDir = func(dir string) error {
		if err := syncDir(dir); err != nil {
			return err
		}
		if _, err := os.Stat(p.companion); errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if !bytes.Equal(readPublicationBytes(t, p.companion), p.token) {
			t.Fatal("reached config rename without a published companion")
		}
		os.Exit(97)
		return nil
	}
	_, err = p.commit(t.Context(), raw, ops)
	t.Fatalf("failed to reach crash point: %v", err)
}

func TestSetupPublicationCrashReplay(t *testing.T) {
	for _, existing := range []bool{false, true} {
		name := "fresh identity"
		if existing {
			name = "legacy identity and paired client"
		}
		t.Run(name, func(t *testing.T) {
			clearSetupEnv(t)
			dir := t.TempDir()
			path := filepath.Join(dir, "config.json")
			opts := atomicSetupOptions(t, path, false)
			for _, name := range []string{"app-server-ws-token-user", ".config.json.tmp-unrelated", "other-config.json"} {
				writeFileWithMode(t, filepath.Join(dir, name), []byte("keep this unrelated file"), 0600)
			}
			unrelated := setupFilesSnapshot(t, dir)
			var legacyFiles map[string]savedFile
			var oldBearer string
			if existing {
				opts.LegacyPath = filepath.Join(t.TempDir(), "legacy.json")
				source := atomicSetupOptions(t, opts.LegacyPath, false)
				if _, err := Run(t.Context(), source); err != nil {
					t.Fatal(err)
				}
				var doc map[string]json.RawMessage
				if err := json.Unmarshal(readPublicationBytes(t, source.ConfigPath), &doc); err != nil {
					t.Fatal(err)
				}
				doc["future_preference"] = json.RawMessage(`{"precise":9007199254740993}`)
				raw, err := json.Marshal(doc)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(source.ConfigPath, raw, 0600); err != nil {
					t.Fatal(err)
				}
				legacy, err := config.LoadForDoctor(source.ConfigPath)
				if err != nil {
					t.Fatal(err)
				}
				oldBearer = legacy.Auth.Token
				legacyFiles = setupFilesSnapshot(t, filepath.Dir(source.ConfigPath))
			}
			ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
			defer cancel()
			var stale *proposal
			var staleBytes []byte
			if !existing {
				// Start a second save before the child leaves its durable journal.
				var err error
				stale, err = readProposal(path, "", false)
				if err != nil {
					t.Fatal(err)
				}
				if err = stale.fresh(opts, interruptedIdentity{}); err != nil {
					t.Fatal(err)
				}
				if err = stale.selectRoots(opts); err != nil {
					t.Fatal(err)
				}
				staleBytes, err = stale.bytes()
				if err != nil {
					t.Fatal(err)
				}
			}
			child := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestSetupPublicationCrashChild$")
			child.Env = append(os.Environ(), "MIMI_SETUP_CRASH_CHILD=yes", "MIMI_SETUP_CRASH_DESTINATION="+path, "MIMI_SETUP_CRASH_ROOT="+opts.ScanRoot, "MIMI_SETUP_CRASH_LEGACY="+opts.LegacyPath)
			output, err := child.CombinedOutput()
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 97 {
				t.Fatalf("child missed crash point: %v: %s", err, output)
			}
			assertMissingPath(t, path)
			record := readPublicationRecord(t, path)
			staged := config.ParseSetupDocument(readPublicationBytes(t, filepath.Join(dir, record.ConfigStage)))
			if staged.Code != "" || staged.Config.Auth.Token == "" {
				t.Fatalf("unusable staged identity: %q", staged.Code)
			}
			wsBefore := readPublicationBytes(t, filepath.Join(dir, record.Companion))
			if len(wsBefore) == 0 || !bytes.Equal(wsBefore, readPublicationBytes(t, filepath.Join(dir, record.TokenStage))) {
				t.Fatal("incomplete staged or published companion at crash")
			}
			if !existing {
				tryStale := func() {
					t.Helper()
					before := setupFilesSnapshot(t, dir)
					_, err := stale.commit(t.Context(), staleBytes, defaultSetupFileTransactionOps())
					requirePublicationError(t, err, "config_concurrent_change")
					if !reflect.DeepEqual(before, setupFilesSnapshot(t, dir)) {
						t.Fatal("stale writer changed the recovered identity or transaction files")
					}
				}
				tryStale()
				invalid := opts
				invalid.ScanRoot = filepath.Join(dir, "missing")
				if _, e := Run(t.Context(), invalid); e == nil {
					t.Fatal("replayed onto an unconfirmed missing root")
				}
				tryStale()
				if _, e := ConfigureWorkspaceRoots(path, opts.ScanRoot, ""); e == nil {
					t.Fatal("workspace created an identity")
				}
			}
			receipt, err := Run(t.Context(), opts)
			if err != nil || receipt.Created == existing {
				t.Fatalf("replay receipt: created=%v err=%v", receipt.Created, err)
			}
			current, err := config.LoadForDoctor(path)
			if err != nil || current.Auth.Token != staged.Config.Auth.Token {
				t.Fatalf("replay lost staged host identity: %v", err)
			}
			files := setupFilesSnapshot(t, dir)
			delete(files, path)
			if existing {
				if !reflect.DeepEqual(legacyFiles, setupFilesSnapshot(t, filepath.Dir(opts.LegacyPath))) {
					t.Fatal("legacy config, access mode or referenced token changed")
				}
				req := httptest.NewRequest("GET", "/api/projects", nil)
				req.Header.Set("Authorization", "Bearer "+oldBearer)
				if !auth.NewWithOptions(current.Auth.Token, false, auth.Options{}).ValidRequest(req) {
					t.Fatal("existing client no longer authenticated after replay")
				}
				if !bytes.Contains(readPublicationBytes(t, path), []byte("9007199254740993")) {
					t.Fatal("replay dropped an unknown field or lost integer precision")
				}
			} else if config.SupportsManagedAppServer() {
				if !bytes.Equal(wsBefore, readPublicationBytes(t, current.AppServer.WSTokenFile)) {
					t.Fatal("replay regenerated WS credential")
				}
				delete(files, current.AppServer.WSTokenFile)
			}
			if !reflect.DeepEqual(files, unrelated) {
				t.Fatal("replay left transaction debris or changed unrelated files")
			}
		})
	}
}

func TestSetupPublicationDetectsConcurrentSourceAndDestinationChanges(t *testing.T) {
	for _, tc := range []struct {
		name, target, change string
		destination, legacy  bool
	}{
		{"destination appeared", "destination", "create", false, false},
		{"destination appeared during migration", "destination", "create", false, true},
		{"destination edited", "destination", "edit", true, false},
		{"destination deleted", "destination", "delete", true, false},
		{"legacy appeared", "legacy", "create", false, false},
		{"legacy edited", "legacy", "edit", false, true},
		{"legacy deleted", "legacy", "delete", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			clearSetupEnv(t)
			path := filepath.Join(t.TempDir(), "config.json")
			legacy := filepath.Join(t.TempDir(), "legacy.json")
			if tc.destination || tc.legacy {
				source := path
				if tc.legacy {
					source = legacy
				}
				if _, err := Run(t.Context(), atomicSetupOptions(t, source, false)); err != nil {
					t.Fatal(err)
				}
			}
			opts := atomicSetupOptions(t, path, false)
			opts.LegacyPath = legacy
			target := path
			if tc.target == "legacy" {
				target = legacy
			}
			ops := defaultSetupFileTransactionOps()
			link := ops.link
			var expected []byte
			reachedJournal := false
			// An editor appears after the first CAS and after journal creation.
			// Only the final CAS immediately preceding config rename can catch it.
			ops.link = func(src, dst string) error {
				if err := link(src, dst); err != nil {
					return err
				}
				if dst != config.SetupJournalPath(path) {
					return nil
				}
				reachedJournal = true
				switch tc.change {
				case "delete":
					return os.Remove(target)
				case "create":
					expected = []byte(`{"new_owner":"external-editor"}`)
					configtest.CreatePrivateFile(t, target, expected)
					return nil
				case "edit":
					// Whitespace is a generation change, even when JSON is equivalent.
					expected = append(readPublicationBytes(t, target), '\n')
				}
				return os.WriteFile(target, expected, 0600)
			}
			_, err := runWithFileOps(t.Context(), opts, ops)
			requirePublicationError(t, err, "config_concurrent_change")
			if !reachedJournal {
				t.Fatal("test never injected the concurrent change")
			}
			if tc.change == "delete" {
				assertMissingPath(t, target)
			} else {
				assertFileBytesAndMode(t, target, expected, 0600)
			}
			if target != path {
				assertMissingPath(t, path)
			}
			assertMissingPath(t, config.SetupJournalPath(path))
		})
	}
}

func TestSetupPublicationKeepsEvidenceOfIndeterminateCommit(t *testing.T) {
	for _, failure := range []string{"ambiguous rename", "rollback rename", "rollback directory sync"} {
		t.Run(failure, func(t *testing.T) {
			clearSetupEnv(t)
			path := filepath.Join(t.TempDir(), "config.json")
			opts := atomicSetupOptions(t, path, false)
			if _, err := Run(t.Context(), opts); err != nil {
				t.Fatal(err)
			}
			original := readPublicationBytes(t, path)
			opts.ScanRoot = t.TempDir()
			injected := errors.New("injected publication failure")
			ops := defaultSetupFileTransactionOps()
			syncDir, rename := ops.syncDir, ops.rename
			commits := 0
			didRollback := false
			ops.rename = func(src, dst string) error {
				if dst != path {
					return rename(src, dst)
				}
				commits++
				if commits == 2 && failure == "rollback rename" {
					return injected
				}
				if err := rename(src, dst); err != nil {
					return err
				}
				if commits == 1 && failure == "ambiguous rename" {
					return injected
				}
				didRollback = commits == 2
				return nil
			}
			syncFailures := 0
			ops.syncDir = func(dir string) error {
				if commits == 1 && syncFailures == 0 && failure != "ambiguous rename" {
					syncFailures++
					return injected
				}
				if didRollback && syncFailures == 1 && failure == "rollback directory sync" {
					syncFailures++
					return injected
				}
				return syncDir(dir)
			}
			_, err := runWithFileOps(t.Context(), opts, ops)
			typed := requirePublicationError(t, err, "config_recovery_required")
			if typed.RecoveryPath == "" || !errors.Is(err, injected) {
				t.Fatal("lost original failure or recovery location")
			}
			if failure == "ambiguous rename" && commits != 1 || failure != "ambiguous rename" && commits != 2 {
				t.Fatalf("fault not reached: %d renames", commits)
			}
			record := readPublicationRecord(t, path)
			dir := filepath.Dir(path)
			assertFileBytesAndMode(t, filepath.Join(dir, record.Backup), original, 0600)
			physical := readPublicationBytes(t, path)
			if failure == "rollback directory sync" {
				if !bytes.Equal(original, physical) {
					t.Fatal("rollback returned without restoring original inode")
				}
			} else if digest(physical) != record.After || bytes.Equal(physical, original) {
				t.Fatal("expected physical committed file")
			}
			marker := config.SetupJournalPath(path) + ".recovery"
			assertPrivateRegularFile(t, marker)
			before := setupFilesSnapshot(t, dir)
			if observed := config.ReadPreflightSnapshot(path); observed.Code != "config_recovery_required" || observed.Confirmed {
				t.Fatal("preflight did not report read-only recovery")
			}
			_, err = Run(t.Context(), opts)
			requirePublicationError(t, err, "config_recovery_required")
			if !reflect.DeepEqual(before, setupFilesSnapshot(t, dir)) {
				t.Fatal("retry discarded recovery material")
			}
		})
	}
}

func TestSetupPublicationTwoStagedWriters(t *testing.T) {
	clearSetupEnv(t)
	path := filepath.Join(t.TempDir(), "config.json")
	seed := atomicSetupOptions(t, path, false)
	if _, err := Run(t.Context(), seed); err != nil {
		t.Fatal(err)
	}
	base, err := config.LoadForDoctor(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	type outcome struct {
		result Result
		err    error
	}
	outcomes := make(chan outcome, 2)
	bothStaged := make(chan struct{}, 2)
	proceed := make(chan struct{})
	for range 2 {
		opts := seed
		opts.ScanRoot = t.TempDir()
		ops := defaultSetupFileTransactionOps()
		stage := ops.stage
		ops.stage = func(dir, prefix string, raw []byte) (string, error) {
			name, err := stage(dir, prefix, raw)
			if err == nil && strings.HasPrefix(prefix, ".config.json.tmp-") {
				bothStaged <- struct{}{}
				select {
				case <-proceed:
				case <-ctx.Done():
				}
			}
			return name, err
		}
		go func() {
			res, err := runWithFileOps(ctx, opts, ops)
			outcomes <- outcome{res, err}
		}()
	}
	for range 2 {
		select {
		case <-bothStaged:
		case <-ctx.Done():
			t.Fatal("concurrent proposals did not reach staging")
		}
	}
	close(proceed)
	success, conflicts := 0, 0
	var winner Result
	for range 2 {
		select {
		case got := <-outcomes:
			if got.err == nil {
				success++
				winner = got.result
			} else {
				requirePublicationError(t, got.err, "config_concurrent_change")
				conflicts++
			}
		case <-ctx.Done():
			t.Fatal("concurrent saves did not resolve")
		}
	}
	if success != 1 || conflicts != 1 {
		t.Fatalf("success=%d, conflicts=%d", success, conflicts)
	}
	final, err := config.LoadForDoctor(path)
	if err != nil || len(final.ScanRoots) != 1 || final.ScanRoots[0] != winner.ScanRoot || final.Auth.Token != base.Auth.Token {
		t.Fatalf("wrong committed generation: %v", err)
	}
	assertMissingPath(t, config.SetupJournalPath(path))
}

func TestFreshPublicationDoesNotReplaceLastMomentCreation(t *testing.T) {
	clearSetupEnv(t)
	path := filepath.Join(t.TempDir(), "config.json")
	opts := atomicSetupOptions(t, path, false)
	ops := defaultSetupFileTransactionOps()
	publish := ops.renameNew
	foreign := []byte("{\"future_user_config\":true}\n")
	ops.renameNew = func(stage, destination string) error {
		configtest.CreatePrivateFile(t, destination, foreign)
		return publish(stage, destination)
	}
	_, err := runWithFileOps(t.Context(), opts, ops)
	requirePublicationError(t, err, "config_concurrent_change")
	assertFileBytesAndMode(t, path, foreign, 0600)
	assertSetupDirectoryEntries(t, filepath.Dir(path), "config.json")
}

func TestSetupRefusesAmbiguousIdentityBeforeEditing(t *testing.T) {
	clearSetupEnv(t)
	opts := atomicSetupOptions(t, filepath.Join(t.TempDir(), "config.json"), false)
	if _, err := Run(t.Context(), opts); err != nil {
		t.Fatal(err)
	}
	raw := bytes.TrimSpace(readPublicationBytes(t, opts.ConfigPath))
	raw = append(bytes.Clone(raw[:len(raw)-1]), []byte(`,"AUTH":{"token":"ambiguous-fixture-only"}}`)...)
	writeFileWithMode(t, opts.ConfigPath, raw, 0600)
	if snapshot := config.ReadPreflightSnapshot(opts.ConfigPath); snapshot.Code != "config_invalid" || snapshot.Confirmed {
		t.Fatal("preflight accepted an ambiguous host identity")
	}
	opts.ScanRoot = t.TempDir()
	_, err := Run(t.Context(), opts)
	requirePublicationError(t, err, "config_invalid")
	assertFileBytesAndMode(t, opts.ConfigPath, raw, 0600)
}
