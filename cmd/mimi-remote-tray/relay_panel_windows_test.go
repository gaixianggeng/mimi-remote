//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestRelaySelectionCompletesModeConfigurationAndEnable(t *testing.T) {
	for _, choice := range []string{"default", "custom", "mimi"} {
		t.Run(choice, func(t *testing.T) {
			state := tailcatTrayStatus{Mode: "managed"}
			var calls []string
			controller := &agentController{commandRunner: func(_ context.Context, args ...string) ([]byte, error) {
				calls = append(calls, strings.Join(args, " "))
				switch args[1] {
				case "exit-managed":
					state.Mode = "self_hosted"
				case "enter-managed":
					state.Mode = "managed"
				case "configure":
					state.DERPMapURL = strings.TrimPrefix(args[2], "--derp-map-url=")
				case "enable":
					state.Enabled, state.Running = true, true
				}
				return json.Marshal(state)
			}}
			url := ""
			if choice == "custom" {
				url = "https://relay.example/map"
			}
			result, err := controller.configureRelay(context.Background(), choice, url)
			if err != nil || !result.ready() || result.managed() != (choice == "mimi") {
				t.Fatalf("result = %+v, error = %v", result, err)
			}
			if choice != "mimi" && result.DERPMapURL != url {
				t.Fatal("wrong relay")
			}
			if choice != "mimi" && !reflect.DeepEqual(calls[1:4], []string{
				"tailcat exit-managed --json", "tailcat status --json", "tailcat configure --derp-map-url=" + url + " --json",
			}) {
				t.Fatalf("unexpected transition: %v", calls)
			}
		})
	}
}

func TestInvalidCustomRelayDoesNotChangeCurrentService(t *testing.T) {
	for _, raw := range []string{"", "http://relay.example/map", "https://user:password@relay.example/map"} {
		var calls []string
		controller := fakeTailcatController(nil, &calls)
		if _, err := controller.configureRelay(context.Background(), "custom", raw); err == nil {
			t.Fatal("expected validation error")
		}
		if len(calls) != 0 {
			t.Fatalf("invalid URL changed service: %v", calls)
		}
	}
}

func TestRelayConfigurationFailureDoesNotEnableOrReportSuccess(t *testing.T) {
	var calls []string
	controller := &agentController{commandRunner: func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, args[1])
		if args[1] == "configure" {
			return nil, errors.New("relay unreachable")
		}
		return []byte(`{"enabled":true,"running":true,"mode":"self_hosted"}`), nil
	}}
	if _, err := controller.configureRelay(context.Background(), "custom", "https://relay.example/map"); err == nil {
		t.Fatal("expected error")
	}
	if !reflect.DeepEqual(calls, []string{"status", "configure"}) {
		t.Fatalf("unexpected commands: %v", calls)
	}
}
