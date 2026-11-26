package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

type fakePinnedMaintenanceDir struct {
	receiptRaw         []byte
	receiptErr         error
	imageErrors        map[string]error
	imageDigests       map[string][]byte
	imagePaths         map[string]string
	verifiedOrder      []string
	verifiedPublishers [][]byte
	pinned             bool
}

func (f *fakePinnedMaintenanceDir) ReadReceipt(name string, maxBytes int64) ([]byte, error) {
	if !f.pinned {
		return nil, errors.New("not pinned")
	}
	if name != maintenanceReceiptName {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	if f.receiptErr != nil {
		return nil, f.receiptErr
	}
	if int64(len(f.receiptRaw)) > maxBytes {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	return f.receiptRaw, nil
}

func (f *fakePinnedMaintenanceDir) VerifyPinnedImage(name string, expectedDigest []byte, expectedPublisher []byte) (string, error) {
	if !f.pinned {
		return "", errors.New("not pinned")
	}
	f.verifiedOrder = append(f.verifiedOrder, name)
	f.verifiedPublishers = append(f.verifiedPublishers, append([]byte(nil), expectedPublisher...))
	if err := f.imageErrors[name]; err != nil {
		return "", err
	}
	if actual, ok := f.imageDigests[name]; ok {
		if hex.EncodeToString(actual) != hex.EncodeToString(expectedDigest) {
			return "", newMaintenanceError(maintenanceFailureDigestMismatch)
		}
	}
	if p, ok := f.imagePaths[name]; ok {
		return p, nil
	}
	return `\\?\Volume{11111111-2222-3333-4444-555555555555}\Users\tester\AppData\Local\Programs\Mimi Remote\` + name, nil
}

func makeValidMaintenanceFixture(t *testing.T) (maintenanceRunner, *fakePinnedMaintenanceDir, *[][]string, *string) {
	t.Helper()
	publisherHex := strings.Repeat("ab", 32)
	brokerDigest := sha256.Sum256([]byte("signed-agentd-fixture"))
	maintDigest := sha256.Sum256([]byte("signed-maintenance-fixture"))
	receiptBytes, err := json.Marshal(maintenanceIdentityReceipt{
		Schema:            maintenanceReceiptSchema,
		Version:           "1.2.3",
		Broker:            maintenanceBrokerRole,
		BrokerSHA256:      hex.EncodeToString(brokerDigest[:]),
		Maintenance:       maintenanceImageRole,
		MaintenanceSHA256: hex.EncodeToString(maintDigest[:]),
	})
	if err != nil {
		t.Fatal(err)
	}
	pinnedDir := &fakePinnedMaintenanceDir{
		receiptRaw: append([]byte("CMS:"), receiptBytes...),
		imageDigests: map[string][]byte{
			maintenanceBrokerRole: brokerDigest[:],
			maintenanceImageRole:  maintDigest[:],
		},
		imageErrors: map[string]error{},
	}
	var launchedArgs [][]string
	var launchedPath string
	confirmed := true
	runner := maintenanceRunner{
		installDir:      `C:\Users\tester\AppData\Local\Programs\Mimi Remote`,
		expectedVersion: "1.2.3",
		publisherSHA256: publisherHex,
		ops: maintenancePlatformOps{
			isElevated: func() (bool, error) { return false, nil },
			withPinnedInstall: func(_ string, fn func(pinned pinnedMaintenanceDir) error) error {
				pinnedDir.pinned = true
				defer func() { pinnedDir.pinned = false }()
				return fn(pinnedDir)
			},
			verifyCMSReceipt: func(raw []byte, expectedPublisher []byte) ([]byte, error) {
				if hex.EncodeToString(expectedPublisher) != publisherHex {
					return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
				}
				if !strings.HasPrefix(string(raw), "CMS:") {
					return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
				}
				return raw[len("CMS:"):], nil
			},
			runBroker: func(_ context.Context, pinnedBrokerPath string, args []string) ([]byte, []byte, int, error) {
				if !pinnedDir.pinned {
					t.Error("broker launched after install directory pins were released")
				}
				launchedPath = pinnedBrokerPath
				launchedArgs = append(launchedArgs, append([]string(nil), args...))
				return nil, nil, 0, nil
			},
			readStatus: func(_ context.Context) (agentStatus, error) {
				if pinnedDir.pinned {
					t.Error("status read ran before install pins were released")
				}
				return agentStatus{
					Version:            "1.2.3",
					ProcessOK:          true,
					ServiceOK:          true,
					WorkspaceConfirmed: &confirmed,
					ModuleStatus:       &moduleStatus{LANEnabled: true, LANAvailable: true},
					NetworkStatus:      &networkStatus{Mode: "lan", AllowLAN: true, PolicyChecked: true, PolicyOK: true},
				}, nil
			},
		},
	}
	return runner, pinnedDir, &launchedArgs, &launchedPath
}

func TestMaintenanceRunnerVerifiesPinsLaunchesArgvAndReReadsStatus(t *testing.T) {
	runner, pinnedDir, launchedArgs, launchedPath := makeValidMaintenanceFixture(t)

	outcome, err := runner.RunModify(context.Background(), true)
	if err != nil {
		t.Fatalf("RunModify failed: %v", err)
	}
	if !outcome.WorkspaceConfirmed || !outcome.LANEnabled || !outcome.LANPolicyOK {
		t.Fatalf("unexpected outcome: %+v", outcome)
	}
	if !reflect.DeepEqual(pinnedDir.verifiedOrder, []string{maintenanceImageRole, maintenanceBrokerRole}) {
		t.Fatalf("verification order = %v, want [%s %s]", pinnedDir.verifiedOrder, maintenanceImageRole, maintenanceBrokerRole)
	}
	if len(*launchedArgs) != 1 || !reflect.DeepEqual((*launchedArgs)[0], []string{"installer-maintenance", "modify"}) {
		t.Fatalf("broker argv = %#v", *launchedArgs)
	}
	if !strings.HasPrefix(*launchedPath, `\\?\Volume{`) || !strings.HasSuffix(*launchedPath, `\agentd.exe`) {
		t.Fatalf("broker launch path was not pinned volume GUID path: %q", *launchedPath)
	}
}

func TestMaintenanceRunnerFailurePathsFallBackWithTypedErrors(t *testing.T) {
	tests := []struct {
		name             string
		mutate           func(r *maintenanceRunner, d *fakePinnedMaintenanceDir)
		wantKind         maintenanceFailureKind
		wantDownload     bool
		expectBrokerCall bool
	}{
		{
			name: "unsigned build empty publisher",
			mutate: func(r *maintenanceRunner, _ *fakePinnedMaintenanceDir) {
				r.publisherSHA256 = ""
			},
			wantKind:     maintenanceFailureUnsignedBuild,
			wantDownload: true,
		},
		{
			name: "dev version rejected",
			mutate: func(r *maintenanceRunner, _ *fakePinnedMaintenanceDir) {
				r.expectedVersion = "dev"
			},
			wantKind:     maintenanceFailureUnsignedBuild,
			wantDownload: true,
		},
		{
			name: "elevated process rejected",
			mutate: func(r *maintenanceRunner, _ *fakePinnedMaintenanceDir) {
				r.ops.isElevated = func() (bool, error) { return true, nil }
			},
			wantKind:     maintenanceFailureElevatedSession,
			wantDownload: false,
		},
		{
			name: "missing receipt",
			mutate: func(_ *maintenanceRunner, d *fakePinnedMaintenanceDir) {
				d.receiptErr = newMaintenanceError(maintenanceFailureReceiptMissing)
			},
			wantKind:     maintenanceFailureReceiptMissing,
			wantDownload: true,
		},
		{
			name: "cms publisher or chain mismatch",
			mutate: func(r *maintenanceRunner, _ *fakePinnedMaintenanceDir) {
				r.ops.verifyCMSReceipt = func([]byte, []byte) ([]byte, error) {
					return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
				}
			},
			wantKind:     maintenanceFailureIdentityMismatch,
			wantDownload: true,
		},
		{
			name: "old signed receipt version replay rejected",
			mutate: func(r *maintenanceRunner, _ *fakePinnedMaintenanceDir) {
				r.expectedVersion = "2.0.0"
			},
			wantKind:     maintenanceFailureIdentityMismatch,
			wantDownload: true,
		},
		{
			name: "role substitution rejected",
			mutate: func(_ *maintenanceRunner, d *fakePinnedMaintenanceDir) {
				d.receiptRaw = []byte(`CMS:{"schema":"mimi.windows.maintenance/v1","version":"1.2.3","broker":"unins000.exe","broker_sha256":"` + strings.Repeat("aa", 32) + `","maintenance":"Mimi-Remote-Maintenance.exe","maintenance_sha256":"` + strings.Repeat("bb", 32) + `"}`)
			},
			wantKind:     maintenanceFailureIdentityMismatch,
			wantDownload: true,
		},
		{
			name: "reparse point on install directory rejected",
			mutate: func(r *maintenanceRunner, _ *fakePinnedMaintenanceDir) {
				r.ops.withPinnedInstall = func(string, func(pinnedMaintenanceDir) error) error {
					return newMaintenanceError(maintenanceFailureReparsePoint)
				}
			},
			wantKind:     maintenanceFailureReparsePoint,
			wantDownload: true,
		},
		{
			name: "missing maintenance exe",
			mutate: func(_ *maintenanceRunner, d *fakePinnedMaintenanceDir) {
				d.imageErrors[maintenanceImageRole] = newMaintenanceError(maintenanceFailureImageMissing)
			},
			wantKind:     maintenanceFailureImageMissing,
			wantDownload: true,
		},
		{
			name: "digest mismatch on maintenance exe",
			mutate: func(_ *maintenanceRunner, d *fakePinnedMaintenanceDir) {
				d.imageDigests[maintenanceImageRole] = make([]byte, 32)
			},
			wantKind:     maintenanceFailureDigestMismatch,
			wantDownload: true,
		},
		{
			name: "digest mismatch on agentd broker",
			mutate: func(_ *maintenanceRunner, d *fakePinnedMaintenanceDir) {
				d.imageDigests[maintenanceBrokerRole] = make([]byte, 32)
			},
			wantKind:     maintenanceFailureDigestMismatch,
			wantDownload: true,
		},
		{
			name: "authenticode failure on broker handle",
			mutate: func(_ *maintenanceRunner, d *fakePinnedMaintenanceDir) {
				d.imageErrors[maintenanceBrokerRole] = newMaintenanceError(maintenanceFailureAuthenticodeFailed)
			},
			wantKind:     maintenanceFailureAuthenticodeFailed,
			wantDownload: true,
		},
		{
			name: "uac cancelled by user",
			mutate: func(r *maintenanceRunner, _ *fakePinnedMaintenanceDir) {
				r.ops.runBroker = func(context.Context, string, []string) ([]byte, []byte, int, error) {
					return []byte(`{"ok":false,"error":{"code":"lan_firewall_blocked","step":"network_lan","message":"管理员授权已取消"}}`),
						[]byte("pair_url=mimiremote://pair?pair_sig=secret-do-not-leak"), 1, errors.New("exit 1")
				}
			},
			wantKind:         maintenanceFailureUACCancelled,
			wantDownload:     true,
			expectBrokerCall: true,
		},
		{
			name: "old host lacking installer-maintenance subcommand",
			mutate: func(r *maintenanceRunner, _ *fakePinnedMaintenanceDir) {
				r.ops.runBroker = func(context.Context, string, []string) ([]byte, []byte, int, error) {
					return nil, []byte(`错误：未知命令 "installer-maintenance"，可用命令：status`), 1, errors.New("exit 1")
				}
			},
			wantKind:         maintenanceFailureOldHostUnsupported,
			wantDownload:     true,
			expectBrokerCall: true,
		},
		{
			name: "post-run status still unconfirmed",
			mutate: func(r *maintenanceRunner, _ *fakePinnedMaintenanceDir) {
				pending := false
				r.ops.readStatus = func(context.Context) (agentStatus, error) {
					return agentStatus{Version: "1.2.3", ProcessOK: true, ServiceOK: true, WorkspaceConfirmed: &pending}, nil
				}
			},
			wantKind:         maintenanceFailureStatusStillUnconfirmed,
			wantDownload:     false,
			expectBrokerCall: true,
		},
		{
			name: "post-run status read failed",
			mutate: func(r *maintenanceRunner, _ *fakePinnedMaintenanceDir) {
				r.ops.readStatus = func(context.Context) (agentStatus, error) {
					return agentStatus{}, errors.New("status pipe closed")
				}
			},
			wantKind:         maintenanceFailureStatusReadFailed,
			wantDownload:     false,
			expectBrokerCall: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			runner, pinnedDir, launchedArgs, _ := makeValidMaintenanceFixture(t)
			origRun := runner.ops.runBroker
			brokerCalled := false
			runner.ops.runBroker = func(ctx context.Context, path string, args []string) ([]byte, []byte, int, error) {
				brokerCalled = true
				return origRun(ctx, path, args)
			}
			tc.mutate(&runner, pinnedDir)
			if tc.expectBrokerCall && !brokerCalled {
				// Wrap custom runBroker if replaced by test case.
				customRun := runner.ops.runBroker
				runner.ops.runBroker = func(ctx context.Context, path string, args []string) ([]byte, []byte, int, error) {
					brokerCalled = true
					return customRun(ctx, path, args)
				}
			}

			_, err := runner.RunModify(context.Background(), true)
			if err == nil {
				t.Fatalf("expected error %s, got nil", tc.wantKind)
			}
			var maintErr *maintenanceError
			if !errors.As(err, &maintErr) {
				t.Fatalf("expected *maintenanceError, got %T: %v", err, err)
			}
			if maintErr.Kind != tc.wantKind {
				t.Fatalf("kind = %s, want %s", maintErr.Kind, tc.wantKind)
			}
			if maintErr.FallbackToDownload != tc.wantDownload {
				t.Fatalf("FallbackToDownload = %v, want %v", maintErr.FallbackToDownload, tc.wantDownload)
			}
			if tc.wantDownload {
				if maintErr.DownloadURL != maintenanceOfficialDownloadURL || !strings.Contains(maintErr.Message, maintenanceOfficialDownloadURL) {
					t.Fatalf("missing official download guidance: %+v", maintErr)
				}
			}
			if !tc.expectBrokerCall && (brokerCalled || len(*launchedArgs) != 0) {
				t.Fatalf("broker must not be launched on %s", tc.name)
			}
			// Ensure formatted user error never leaks raw secrets/pair_url and preserves official download URL.
			formatted := formatTrayUserError(err)
			if strings.Contains(formatted, "secret-do-not-leak") || strings.Contains(formatted, "pair_sig=") {
				t.Fatalf("secret leaked into formatted error: %q", formatted)
			}
			if tc.wantDownload && !strings.Contains(formatted, maintenanceOfficialDownloadURL) {
				t.Fatalf("formatted error lost official download URL: %q", formatted)
			}
		})
	}
}
