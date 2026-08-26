package httpapi

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func newSharedDaemonFencePolicy(t *testing.T, released *atomic.Int32) *appServerGatewayPolicy {
	t.Helper()
	router := &Router{}
	router.cfg.AppServer.Transport = "unix"
	router.cfg.AppServer.Managed = true
	router.cfg.AppServer.SharedFallback = &config.AppServerFallbackConfig{}
	return &appServerGatewayPolicy{
		router:    router,
		runtimeID: "codex",
		acquireDaemonFence: func(context.Context) (func(), error) {
			return func() { released.Add(1) }, nil
		},
	}
}

func reserveSharedDaemonFence(
	t *testing.T,
	policy *appServerGatewayPolicy,
	payload []byte,
) *appServerGatewayClientRPCReservation {
	t.Helper()
	reservation, policyErr := policy.reserveClientRPC(payload)
	if policyErr != nil {
		t.Fatalf("保留客户端请求失败：%s", policyErr.message)
	}
	if reservation == nil {
		t.Fatal("客户端 request 必须取得 reservation")
	}
	if policyErr := reservation.attachSharedDaemonFence(context.Background(), payload); policyErr != nil {
		t.Fatalf("获取使用锁失败：%s", policyErr.message)
	}
	return reservation
}

func TestSharedDaemonFenceHeldUntilUpstreamResponse(t *testing.T) {
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	request := []byte(`{"id":41,"method":"turn/start","params":{"threadId":"thread-1"}}`)
	reserveSharedDaemonFence(t, policy, request)
	if got := released.Load(); got != 0 {
		t.Fatalf("收到 upstream 响应前不应释放使用锁，实际 %d", got)
	}

	response := []byte(`{"id":41,"result":{"turn":{"id":"turn-1"}}}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(1, response); policyErr != nil || !forward {
		t.Fatalf("upstream 响应处理失败：forward=%t err=%v", forward, policyErr)
	}
	if got := released.Load(); got != 0 {
		t.Fatalf("响应写回客户端前不应释放使用锁，实际 %d", got)
	}
	policy.releaseClientRPCReservationForResponsePayload(response)
	if got := released.Load(); got != 1 {
		t.Fatalf("响应写回客户端后应释放一次使用锁，实际 %d", got)
	}
	policy.releaseClientRPCReservationForResponsePayload(response)
	if got := released.Load(); got != 1 {
		t.Fatalf("重复响应不应重复释放，实际 %d", got)
	}
}

func TestSharedDaemonFenceIgnoresCollidingServerRequestID(t *testing.T) {
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	request := []byte(`{"id":41,"method":"turn/start","params":{}}`)
	reservation := reserveSharedDaemonFence(t, policy, request)
	serverRequest := []byte(`{"id":41,"method":"item/tool/requestUserInput","params":{}}`)
	policy.releaseClientRPCReservationForResponsePayload(serverRequest)
	if got := released.Load(); got != 0 {
		t.Fatalf("反向请求 id 碰撞不应释放客户端请求锁，实际 %d", got)
	}
	reservation.release()
}

func TestSharedDaemonFenceReleasesAfterErrorResponseDelivery(t *testing.T) {
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	request := []byte(`{"id":42,"method":"thread/compact/start","params":{}}`)
	reserveSharedDaemonFence(t, policy, request)
	errorResponse := []byte(`{"id":42,"error":{"code":-32603,"message":"failed"}}`)
	policy.releaseClientRPCReservationForResponsePayload(errorResponse)
	if got := released.Load(); got != 1 {
		t.Fatalf("error 响应写回后也应释放使用锁，实际 %d", got)
	}
}

func TestSharedDaemonFenceOnlyProtectsSharedCodexMutations(t *testing.T) {
	tests := []struct {
		name      string
		runtimeID string
		transport string
		method    string
		managed   bool
		fallback  bool
		wantToken bool
		wantHeld  bool
	}{
		{name: "shared mutation", runtimeID: "codex", transport: "unix", method: "thread/start", managed: true, fallback: true, wantToken: true, wantHeld: true},
		{name: "shared read", runtimeID: "codex", transport: "unix", method: "thread/read", managed: true, fallback: true, wantToken: true},
		{name: "legacy websocket", runtimeID: "codex", transport: "ws", method: "turn/start", managed: true, fallback: true},
		{name: "unmanaged unix", runtimeID: "codex", transport: "unix", method: "turn/start", fallback: true},
		{name: "unix without fallback", runtimeID: "codex", transport: "unix", method: "turn/start", managed: true},
		{name: "claude", runtimeID: "claude", transport: "unix", method: "turn/start", managed: true, fallback: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var acquired atomic.Int32
			var released atomic.Int32
			router := &Router{}
			router.cfg.AppServer.Transport = test.transport
			router.cfg.AppServer.Managed = test.managed
			if test.fallback {
				router.cfg.AppServer.SharedFallback = &config.AppServerFallbackConfig{}
			}
			policy := &appServerGatewayPolicy{
				router:    router,
				runtimeID: test.runtimeID,
				acquireDaemonFence: func(context.Context) (func(), error) {
					acquired.Add(1)
					return func() { released.Add(1) }, nil
				},
			}
			payload := []byte(`{"id":1,"method":"` + test.method + `","params":{}}`)
			reservation, policyErr := policy.reserveClientRPC(payload)
			if policyErr != nil {
				t.Fatalf("保留客户端请求失败：%s", policyErr.message)
			}
			if (reservation != nil) != test.wantToken {
				t.Fatalf("reservation=%v wantToken=%t", reservation, test.wantToken)
			}
			if policyErr := reservation.attachSharedDaemonFence(context.Background(), payload); policyErr != nil {
				t.Fatalf("获取使用锁失败：%s", policyErr.message)
			}
			if got := acquired.Load(); (got == 1) != test.wantHeld {
				t.Fatalf("acquired=%d wantHeld=%t", got, test.wantHeld)
			}
			reservation.release()
			if got := released.Load(); (got == 1) != test.wantHeld {
				t.Fatalf("released=%d wantHeld=%t", got, test.wantHeld)
			}
		})
	}
}

func TestSharedDaemonFenceReleasedWhenGatewayCloses(t *testing.T) {
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	request := []byte(`{"id":"request-1","method":"thread/archive","params":{"threadId":"thread-1"}}`)
	reserveSharedDaemonFence(t, policy, request)
	policy.close()
	policy.close()
	if got := released.Load(); got != 1 {
		t.Fatalf("gateway 关闭应只释放一次使用锁，实际 %d", got)
	}
}

func TestSharedDaemonFenceWriteFailureWaitsForConnectionClose(t *testing.T) {
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	request := []byte(`{"id":"write-failed","method":"turn/start","params":{}}`)
	reserveSharedDaemonFence(t, policy, request)
	if err := policy.forwardClientFrameToUpstream(request, func() error {
		return errors.New("uncertain upstream write")
	}); err == nil {
		t.Fatal("测试 writer 必须失败")
	}
	if got := released.Load(); got != 0 {
		t.Fatalf("write 失败不能证明 upstream 未接收，关闭连接前不得释放：%d", got)
	}
	policy.close()
	if got := released.Load(); got != 1 {
		t.Fatalf("连接关闭后应释放一次共享锁，实际 %d", got)
	}
}

func TestSharedDaemonFenceFailsClosedDuringRestart(t *testing.T) {
	router := &Router{}
	router.cfg.AppServer.Transport = "unix"
	router.cfg.AppServer.Managed = true
	router.cfg.AppServer.SharedFallback = &config.AppServerFallbackConfig{}
	policy := &appServerGatewayPolicy{
		router:    router,
		runtimeID: "codex",
		acquireDaemonFence: func(context.Context) (func(), error) {
			return nil, context.DeadlineExceeded
		},
	}
	request := []byte(`{"id":7,"method":"turn/start","params":{}}`)
	reservation, reserveErr := policy.reserveClientRPC(request)
	if reserveErr != nil {
		t.Fatalf("保留客户端请求失败：%s", reserveErr.message)
	}
	policyErr := reservation.attachSharedDaemonFence(context.Background(), request)
	if policyErr == nil {
		t.Fatal("重启期间 mutation 必须 fail closed")
	}
	if got := policyErr.data["reason"]; got != "shared_daemon_restart_in_progress" {
		t.Fatalf("reason=%v", got)
	}
	if retryable, _ := policyErr.data["retryable"].(bool); !retryable {
		t.Fatal("重启竞争应允许客户端稍后重试")
	}
}

func TestSharedDaemonFenceRejectsDuplicateRequestID(t *testing.T) {
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	request := []byte(`{"id":9,"method":"turn/start","params":{}}`)
	first := reserveSharedDaemonFence(t, policy, request)
	if _, policyErr := policy.reserveClientRPC(request); policyErr == nil {
		t.Fatal("重复请求 id 应被拒绝")
	}
	if got := released.Load(); got != 0 {
		t.Fatalf("重复请求不能释放原请求锁，实际 %d", got)
	}
	first.release()
	if got := released.Load(); got != 1 {
		t.Fatalf("原请求锁应保留到显式释放，实际 %d", got)
	}
}

func TestSharedDaemonFenceRejectsReadCollisionWithoutReleasingMutation(t *testing.T) {
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	mutation := []byte(`{"id":11,"method":"turn/start","params":{}}`)
	first := reserveSharedDaemonFence(t, policy, mutation)
	read := []byte(`{"id":11,"method":"thread/read","params":{"threadId":"thread-1"}}`)
	if _, policyErr := policy.reserveClientRPC(read); policyErr == nil {
		t.Fatal("mutation 在途时同 id read 必须被拒绝")
	}
	if got := released.Load(); got != 0 {
		t.Fatalf("同 id read 不能释放 mutation 锁，实际 %d", got)
	}
	first.release()
}

func TestSharedDaemonFenceRejectsMutationCollisionWithPendingRead(t *testing.T) {
	var acquired atomic.Int32
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	policy.acquireDaemonFence = func(context.Context) (func(), error) {
		acquired.Add(1)
		return func() { released.Add(1) }, nil
	}
	read := []byte(`{"id":12,"method":"thread/read","params":{"threadId":"thread-1"}}`)
	readReservation := reserveSharedDaemonFence(t, policy, read)
	mutation := []byte(`{"id":12,"method":"turn/start","params":{}}`)
	if _, policyErr := policy.reserveClientRPC(mutation); policyErr == nil {
		t.Fatal("read 在途时同 id mutation 必须被拒绝")
	}
	if got := acquired.Load(); got != 0 {
		t.Fatalf("冲突 mutation 不得获取共享锁，实际 %d", got)
	}
	readReservation.release()
}

func TestSharedDaemonFenceCanonicalizesEscapedStringRequestID(t *testing.T) {
	var acquired atomic.Int32
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	policy.acquireDaemonFence = func(context.Context) (func(), error) {
		acquired.Add(1)
		return func() { released.Add(1) }, nil
	}
	read := []byte(`{"id":"\u0061","method":"thread/read","params":{"threadId":"thread-1"}}`)
	readReservation := reserveSharedDaemonFence(t, policy, read)
	mutation := []byte(`{"id":"a","method":"turn/start","params":{}}`)
	if _, policyErr := policy.reserveClientRPC(mutation); policyErr == nil {
		t.Fatal("转义后语义相同的 request id 必须被视为冲突")
	}
	if got := acquired.Load(); got != 0 {
		t.Fatalf("冲突 mutation 不得获取共享锁，实际 %d", got)
	}
	readReservation.release()
}

func TestGatewayRejectsRequestIDOutsideCodexStringOrInt64(t *testing.T) {
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	for _, rawID := range []string{`1.5`, `1e0`, `{}`, `true`, `null`, `9223372036854775808`} {
		t.Run(rawID, func(t *testing.T) {
			payload := []byte(`{"id":` + rawID + `,"method":"model/list","params":{}}`)
			if _, policyErr := policy.validateClientFrame(1, payload); policyErr == nil ||
				!strings.Contains(policyErr.message, "id") {
				t.Fatalf("非法 request id 必须被明确拒绝：%s err=%+v", rawID, policyErr)
			}
		})
	}
}

func TestSharedDaemonFenceAcquiredOnlyAfterPolicyValidation(t *testing.T) {
	var acquired atomic.Int32
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	policy.acquireDaemonFence = func(context.Context) (func(), error) {
		acquired.Add(1)
		return func() { released.Add(1) }, nil
	}
	request := []byte(`{"id":13,"method":"turn/start","params":[]}`)
	reservation, reserveErr := policy.reserveClientRPC(request)
	if reserveErr != nil {
		t.Fatalf("保留客户端请求失败：%s", reserveErr.message)
	}
	_, policyErr := policy.validateClientFrameContextWithReservation(context.Background(), 1, request, reservation)
	if policyErr == nil {
		t.Fatal("无效 params 必须被 policy 拒绝")
	}
	reservation.release()
	if got := acquired.Load(); got != 0 {
		t.Fatalf("校验失败的 mutation 不得获取共享锁，实际 %d", got)
	}
}

func TestSharedDaemonFenceReservationLimitPreventsFDExhaustion(t *testing.T) {
	var acquired atomic.Int32
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	policy.acquireDaemonFence = func(context.Context) (func(), error) {
		acquired.Add(1)
		return func() { released.Add(1) }, nil
	}
	reservations := make([]*appServerGatewayClientRPCReservation, 0, appServerGatewayPendingClientRequestMax)
	for index := 0; index < appServerGatewayPendingClientRequestMax; index++ {
		request := []byte(fmt.Sprintf(`{"id":%d,"method":"thread/read","params":{}}`, index))
		reservation, policyErr := policy.reserveClientRPC(request)
		if policyErr != nil || reservation == nil {
			t.Fatalf("第 %d 个 request 保留失败：%v", index, policyErr)
		}
		reservations = append(reservations, reservation)
	}
	overflow := []byte(`{"id":"overflow","method":"turn/start","params":{}}`)
	if _, policyErr := policy.reserveClientRPC(overflow); policyErr == nil {
		t.Fatal("超过连接级上限的 request 必须被拒绝")
	}
	if got := acquired.Load(); got != 0 {
		t.Fatalf("容量检查必须发生在打开 lock fd 前，实际 acquire=%d", got)
	}
	for _, reservation := range reservations {
		reservation.release()
	}
}

func TestSharedDaemonFenceOldTokenCannotReleaseReusedID(t *testing.T) {
	var released atomic.Int32
	policy := newSharedDaemonFencePolicy(t, &released)
	request := []byte(`{"id":14,"method":"turn/start","params":{}}`)
	first := reserveSharedDaemonFence(t, policy, request)
	first.release()
	second := reserveSharedDaemonFence(t, policy, request)
	first.release()
	if got := released.Load(); got != 1 {
		t.Fatalf("旧 token 不能释放复用 id 的新锁，实际 %d", got)
	}
	second.release()
	if got := released.Load(); got != 2 {
		t.Fatalf("新 token 应独立释放一次，实际 %d", got)
	}
}
