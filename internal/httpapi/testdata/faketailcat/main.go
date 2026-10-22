// faketailcat 只在本机 Unix socket 上模拟受控 sidecar，不建立任何中继连接。
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"time"
)

func main() {
	flags := flag.NewFlagSet("managed-host", flag.ExitOnError)
	stateDir := flags.String("state-dir", "", "")
	control := flags.String("control", "", "")
	relay := flags.String("derpmap-url", "", "")
	flags.String("target", "", "")
	flags.String("port", "", "")
	_ = flags.Parse(os.Args[2:])
	identityPath := filepath.Join(*stateDir, "host.private.json")
	identity, err := os.ReadFile(identityPath)
	if os.IsNotExist(err) {
		identity = []byte(newKey())
		must(os.WriteFile(identityPath, identity, 0o600))
	} else {
		must(err)
	}
	// 故意在生成新身份后失败，验证回滚不能只恢复 URL。
	failure, _ := os.ReadFile(filepath.Join(*stateDir, "fail-start-url"))
	if string(failure) == *relay && len(failure) > 0 {
		os.Exit(1)
	}
	address := "tailcat:test?relay=" + url.QueryEscape(*relay)
	must(os.WriteFile(filepath.Join(*stateDir, "host.address"), []byte(address), 0o600))
	var clients []string
	if raw, err := os.ReadFile(filepath.Join(*stateDir, "clients.json")); err == nil {
		must(json.Unmarshal(raw, &clients))
	}
	status := map[string]any{
		"running": true, "address": address, "public_key": string(identity),
		"instance_id": newKey(), "paired_device_count": len(clients),
	}
	var mu sync.Mutex
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch r.URL.Path {
		case "/pair":
			status["pair_address"] = "tailcat:pair?relay=" + url.QueryEscape(*relay)
			status["pair_public_key"] = newKey()
			status["pair_expires_at"] = time.Now().Add(10 * time.Minute).UTC().Format(time.RFC3339Nano)
		case "/managed-clients":
			var body struct {
				PublicKeys []string `json:"public_keys"`
			}
			must(json.NewDecoder(r.Body).Decode(&body))
			status["paired_device_count"] = len(clients) + len(body.PublicKeys)
		case "/shutdown":
			time.AfterFunc(10*time.Millisecond, func() { os.Exit(0) })
		case "/status":
		default:
			w.WriteHeader(http.StatusNotFound)
			return
		}
		must(json.NewEncoder(w).Encode(status))
	})
	listener, err := net.Listen("unix", *control)
	must(err)
	must(http.Serve(listener, handler))
}

func newKey() string {
	var key [32]byte
	_, err := rand.Read(key[:])
	must(err)
	return "nodekey:" + hex.EncodeToString(key[:])
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
