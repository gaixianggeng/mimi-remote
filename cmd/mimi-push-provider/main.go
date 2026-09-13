// mimi-push-provider 是 MIM-112 的最小推送服务。
//
// 它只做三件事：给设备签发不透明 Push Ticket、撤销 Ticket、按固定枚举向 APNs 发
// 一条审批提醒。它不托管账号、不托管会话、不中继代码、不代理审批动作 —— 用户的
// 「允许 / 拒绝」始终由设备直接提交给自己的 agentd。
//
// 全部密钥只通过环境变量指向的外部文件注入，绝不进入仓库或 Release 资产。
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/pushprovider"
)

func main() {
	genkey := flag.Bool("genkey", false, "生成一把新的 ticket 加密密钥并退出")
	flag.Parse()
	if *genkey {
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			log.Fatalf("生成密钥失败: %v", err)
		}
		fmt.Println(hex.EncodeToString(key))
		return
	}
	if err := run(); err != nil {
		log.Fatalf("mimi-push-provider 启动失败: %v", err)
	}
}

func run() error {
	listen := envOrDefault("MIMI_PUSH_LISTEN", "127.0.0.1:8087")
	topic := strings.TrimSpace(os.Getenv("MIMI_PUSH_TOPIC"))
	if topic == "" {
		return errors.New("MIMI_PUSH_TOPIC（iOS Bundle ID）必填")
	}
	environment := envOrDefault("MIMI_PUSH_ENVIRONMENT", "production")

	sealer, err := loadSealer()
	if err != nil {
		return err
	}
	credentials, err := loadAPNsCredentials()
	if err != nil {
		return err
	}
	store, err := pushprovider.OpenRevocationStore(envOrDefault("MIMI_PUSH_DB", "/var/lib/mimi-push-provider/revocations.db"))
	if err != nil {
		return fmt.Errorf("打开撤销表失败: %w", err)
	}
	defer store.Close()

	// 两个环境都建好客户端：TestFlight/Debug 构建拿到的是 sandbox Token，
	// App Store 构建是 production，二者不能混用。
	hosts := map[string]string{
		"production": envOrDefault("MIMI_PUSH_APNS_HOST", pushprovider.APNsProductionHost),
		"sandbox":    envOrDefault("MIMI_PUSH_APNS_SANDBOX_HOST", pushprovider.APNsSandboxHost),
	}
	clients := map[string]*pushprovider.APNsClient{}
	for name, host := range hosts {
		clients[name] = pushprovider.NewAPNsClient(host, credentials)
	}

	server, err := pushprovider.NewServer(pushprovider.Options{
		Sealer:      sealer,
		Store:       store,
		Topic:       topic,
		Environment: environment,
		Clients:     clients,
	})
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go server.PurgeLoop(ctx, time.Hour)

	httpServer := &http.Server{
		Addr:              listen,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf("mimi-push-provider listening on %s topic=%s environment=%s", listen, topic, environment)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// loadSealer 读取 ticket 加密密钥文件。每行 `版本:64位十六进制`，允许同时保留
// 上一版密钥，让轮换期间已经发出去的 Ticket 继续可用。
func loadSealer() (*pushprovider.TicketSealer, error) {
	path := strings.TrimSpace(os.Getenv("MIMI_PUSH_TICKET_KEY_FILE"))
	if path == "" {
		return nil, errors.New("MIMI_PUSH_TICKET_KEY_FILE 必填")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读取 ticket 密钥失败: %w", err)
	}
	keys := map[int][]byte{}
	newest := 0
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			return nil, errors.New("ticket 密钥行格式应为 版本:十六进制")
		}
		version, err := strconv.Atoi(strings.TrimSpace(parts[0]))
		if err != nil {
			return nil, fmt.Errorf("非法密钥版本: %w", err)
		}
		key, err := hex.DecodeString(strings.TrimSpace(parts[1]))
		if err != nil {
			return nil, fmt.Errorf("非法密钥内容: %w", err)
		}
		keys[version] = key
		if version > newest {
			newest = version
		}
	}
	currentVersion := newest
	if raw := strings.TrimSpace(os.Getenv("MIMI_PUSH_TICKET_KEY_VERSION")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			return nil, fmt.Errorf("非法 MIMI_PUSH_TICKET_KEY_VERSION: %w", err)
		}
		currentVersion = parsed
	}
	lifetime := 30 * 24 * time.Hour
	if raw := strings.TrimSpace(os.Getenv("MIMI_PUSH_TICKET_LIFETIME")); raw != "" {
		parsed, err := time.ParseDuration(raw)
		if err != nil {
			return nil, fmt.Errorf("非法 MIMI_PUSH_TICKET_LIFETIME: %w", err)
		}
		lifetime = parsed
	}
	return pushprovider.NewTicketSealer(keys, currentVersion, lifetime)
}

func loadAPNsCredentials() (pushprovider.APNsCredentials, error) {
	path := strings.TrimSpace(os.Getenv("MIMI_PUSH_APNS_KEY_FILE"))
	if path == "" {
		return pushprovider.APNsCredentials{}, errors.New("MIMI_PUSH_APNS_KEY_FILE 必填")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return pushprovider.APNsCredentials{}, fmt.Errorf("读取 APNs .p8 失败: %w", err)
	}
	return pushprovider.ParseAPNsAuthKey(raw,
		os.Getenv("MIMI_PUSH_APNS_KEY_ID"),
		os.Getenv("MIMI_PUSH_APNS_TEAM_ID"))
}

func envOrDefault(name string, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}
