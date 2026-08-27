package desktopipc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Delivery string

const (
	DeliveryNotSent   Delivery = "not_sent"
	DeliveryNoClient  Delivery = "no_client_found"
	DeliveryUncertain Delivery = "uncertain"
)

type RequestError struct {
	Method   string
	Delivery Delivery
	Cause    error
}

func (e *RequestError) Error() string {
	return fmt.Sprintf("Desktop IPC %s failed (%s): %v", e.Method, e.Delivery, e.Cause)
}

func (e *RequestError) Unwrap() error { return e.Cause }

func SafeToFallback(err error) bool {
	var requestErr *RequestError
	return errors.As(err, &requestErr) && requestErr.Delivery == DeliveryNoClient
}

type Broadcast struct {
	Method         string
	Version        int
	SourceClientID string
	Params         json.RawMessage
}

type IncomingRequest struct {
	RequestID      json.RawMessage
	Method         string
	Version        int
	SourceClientID string
	Params         json.RawMessage
}

type RequestHandler func(context.Context, IncomingRequest) (any, error)

type DialContextFunc func(context.Context, string, string) (net.Conn, error)
type VerifySocketFunc func(string) error
type VerifyPeerFunc func(net.Conn) (DesktopInfo, error)

type ClientOptions struct {
	Enabled        bool
	SocketPath     string
	DesktopVersion string
	DesktopBuild   string
	DialContext    DialContextFunc
	VerifySocket   VerifySocketFunc
	VerifyPeer     VerifyPeerFunc
	Preflight      func() (State, error)
	RequestTimeout time.Duration
	ReconnectDelay time.Duration
	OnBroadcast    func(Broadcast)
	OnReady        func(uint64)
	OnDisconnect   func(uint64)
	CanHandle      func(IncomingRequest) bool
	HandleRequest  RequestHandler
}

type pendingResponse struct {
	method         string
	targetClientID string
	generation     uint64
	result         chan requestResult
}

type requestResult struct {
	value             json.RawMessage
	handledByClientID string
	err               error
}

type Client struct {
	opts ClientOptions

	status *statusStore
	nextID atomic.Uint64

	mu             sync.RWMutex
	conn           net.Conn
	clientID       string
	generation     uint64
	nextGeneration uint64
	pending        map[string]pendingResponse
	ready          chan struct{}
	started        bool

	writeMu sync.Mutex
	stop    context.CancelFunc
	done    chan struct{}
}

func NewClient(opts ClientOptions) (*Client, error) {
	if opts.RequestTimeout <= 0 {
		opts.RequestTimeout = 15 * time.Second
	}
	if opts.ReconnectDelay <= 0 {
		opts.ReconnectDelay = time.Second
	}
	if opts.DialContext == nil {
		dialer := &net.Dialer{Timeout: 2 * time.Second}
		opts.DialContext = dialer.DialContext
	}
	if opts.VerifySocket == nil {
		opts.VerifySocket = VerifySocket
	}
	if opts.VerifyPeer == nil {
		opts.VerifyPeer = VerifyPeer
	}
	if opts.Enabled && strings.TrimSpace(opts.SocketPath) == "" {
		return nil, fmt.Errorf("Desktop IPC socket path is required")
	}
	client := &Client{
		opts:    opts,
		status:  newStatusStore(opts.Enabled),
		pending: make(map[string]pendingResponse),
		ready:   make(chan struct{}),
		done:    make(chan struct{}),
	}
	client.status.update(func(status *Status) {
		status.DesktopVersion = opts.DesktopVersion
		status.DesktopBuild = opts.DesktopBuild
		if opts.DesktopBuild == SupportedBuild && opts.DesktopVersion == SupportedVersion {
			status.Profile = SupportedProfile
		}
	})
	return client, nil
}

func (c *Client) Start(parent context.Context) {
	c.mu.Lock()
	if c.started {
		c.mu.Unlock()
		return
	}
	c.started = true
	ctx, cancel := context.WithCancel(parent)
	c.stop = cancel
	c.mu.Unlock()
	if !c.opts.Enabled {
		close(c.done)
		return
	}
	go c.run(ctx)
}

func (c *Client) Close() {
	c.mu.RLock()
	stop := c.stop
	started := c.started
	c.mu.RUnlock()
	if stop != nil {
		stop()
	}
	if started {
		<-c.done
	}
}

func (c *Client) Status() Status { return c.status.get() }

func (c *Client) ConnectionGeneration() uint64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.generation
}

func (c *Client) WaitReady(ctx context.Context) error {
	c.mu.RLock()
	ready := c.ready
	c.mu.RUnlock()
	select {
	case <-ready:
		if c.Status().State == StateReady {
			return nil
		}
		return fmt.Errorf("Desktop IPC is not ready")
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (c *Client) Request(ctx context.Context, method string, params any) (json.RawMessage, error) {
	result, _, err := c.request(ctx, "", method, params)
	return result, err
}

func (c *Client) RequestTo(ctx context.Context, targetClientID, method string, params any) (json.RawMessage, error) {
	result, _, err := c.request(ctx, strings.TrimSpace(targetClientID), method, params)
	return result, err
}

// FindHandler asks the IPC server to route the non-mutating owner-discovery
// request. The server returns the client ID that accepted it.
func (c *Client) FindHandler(ctx context.Context, method string, params any) (string, error) {
	_, handledByClientID, err := c.request(ctx, "", method, params)
	return handledByClientID, err
}

func (c *Client) request(ctx context.Context, targetClientID, method string, params any) (json.RawMessage, string, error) {
	requestID := fmt.Sprintf("mimi-%d", c.nextID.Add(1))
	c.mu.RLock()
	conn, clientID, generation := c.conn, c.clientID, c.generation
	c.mu.RUnlock()
	if conn == nil || clientID == "" {
		return nil, "", &RequestError{Method: method, Delivery: DeliveryNotSent, Cause: errors.New("not connected")}
	}
	payload, err := marshalRequest(requestID, clientID, targetClientID, method, params, false)
	if err != nil {
		return nil, "", &RequestError{Method: method, Delivery: DeliveryNotSent, Cause: err}
	}
	waiter := pendingResponse{
		method: method, targetClientID: targetClientID, generation: generation,
		result: make(chan requestResult, 1),
	}
	c.mu.Lock()
	if c.conn != conn || c.clientID == "" || c.generation != waiter.generation {
		c.mu.Unlock()
		return nil, "", &RequestError{Method: method, Delivery: DeliveryNotSent, Cause: errors.New("connection changed")}
	}
	c.pending[requestID] = waiter
	c.mu.Unlock()
	if err := c.write(conn, payload); err != nil {
		c.removePending(requestID)
		return nil, "", &RequestError{Method: method, Delivery: DeliveryUncertain, Cause: err}
	}
	timer := time.NewTimer(c.opts.RequestTimeout)
	defer timer.Stop()
	select {
	case result := <-waiter.result:
		return result.value, result.handledByClientID, result.err
	case <-timer.C:
		c.removePending(requestID)
		return nil, "", &RequestError{Method: method, Delivery: DeliveryUncertain, Cause: errors.New("request timed out")}
	case <-ctx.Done():
		c.removePending(requestID)
		return nil, "", &RequestError{Method: method, Delivery: DeliveryUncertain, Cause: ctx.Err()}
	}
}

func (c *Client) Broadcast(method string, params any) error {
	c.mu.RLock()
	conn, clientID := c.conn, c.clientID
	c.mu.RUnlock()
	if conn == nil || clientID == "" {
		return &RequestError{Method: method, Delivery: DeliveryNotSent, Cause: errors.New("not connected")}
	}
	payload, err := marshalBroadcast(clientID, method, params)
	if err != nil {
		return &RequestError{Method: method, Delivery: DeliveryNotSent, Cause: err}
	}
	if err := c.write(conn, payload); err != nil {
		return &RequestError{Method: method, Delivery: DeliveryUncertain, Cause: err}
	}
	return nil
}

func (c *Client) run(ctx context.Context) {
	defer close(c.done)
	for ctx.Err() == nil {
		if c.opts.Preflight != nil {
			state, err := c.opts.Preflight()
			if err != nil {
				c.status.update(func(status *Status) { status.State = StateProtocolError })
				if !c.waitReconnect(ctx) {
					break
				}
				continue
			}
			if state != "" && state != StateConnecting && state != StateReady {
				c.status.update(func(status *Status) { status.State = state })
				if !c.waitReconnect(ctx) {
					break
				}
				continue
			}
		}
		c.status.update(func(status *Status) { status.State = StateConnecting })
		err := c.connectAndServe(ctx)
		if ctx.Err() != nil {
			break
		}
		state := StateProtocolError
		if errors.Is(err, errSocketUnavailable) {
			state = StateSocketUnavailable
		} else if errors.Is(err, errUnsupportedBuild) {
			state = StateUnsupportedBuild
		}
		c.status.update(func(status *Status) { status.State = state })
		if state == StateUnsupportedBuild {
			c.signalReady()
		}
		if !c.waitReconnect(ctx) {
			break
		}
	}
	c.disconnect(errors.New("Desktop IPC stopped"))
}

func (c *Client) waitReconnect(ctx context.Context) bool {
	timer := time.NewTimer(c.opts.ReconnectDelay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

var errSocketUnavailable = errors.New("Desktop IPC socket unavailable")
var errUnsupportedBuild = errors.New("Desktop IPC peer build is unsupported")

func (c *Client) connectAndServe(ctx context.Context) error {
	if err := c.opts.VerifySocket(c.opts.SocketPath); err != nil {
		return fmt.Errorf("%w: %v", errSocketUnavailable, err)
	}
	conn, err := c.opts.DialContext(ctx, "unix", c.opts.SocketPath)
	if err != nil {
		return fmt.Errorf("%w: %v", errSocketUnavailable, err)
	}
	peer, err := c.opts.VerifyPeer(conn)
	if err != nil {
		_ = conn.Close()
		return err
	}
	c.status.update(func(status *Status) {
		status.DesktopVersion = peer.Version
		status.DesktopBuild = peer.Build
		status.Profile = ""
		if peer.Version == SupportedVersion && peer.Build == SupportedBuild {
			status.Profile = SupportedProfile
		}
	})
	if peer.Version != SupportedVersion || peer.Build != SupportedBuild {
		_ = conn.Close()
		return errUnsupportedBuild
	}
	connectionDone := make(chan struct{})
	defer close(connectionDone)
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-connectionDone:
		}
	}()
	c.mu.Lock()
	c.conn = conn
	c.mu.Unlock()
	initializeID := fmt.Sprintf("mimi-initialize-%d", c.nextID.Add(1))
	payload, err := marshalRequest(initializeID, "", "", "initialize", map[string]any{"clientType": "mimi-agentd"}, true)
	if err != nil {
		_ = conn.Close()
		return err
	}
	if err := c.write(conn, payload); err != nil {
		_ = conn.Close()
		return err
	}
	if deadlineConn, ok := conn.(interface{ SetReadDeadline(time.Time) error }); ok {
		_ = deadlineConn.SetReadDeadline(time.Now().Add(c.opts.RequestTimeout))
	}
	for {
		frame, err := ReadFrame(conn)
		if err != nil {
			_ = conn.Close()
			return err
		}
		var incoming envelope
		if err := json.Unmarshal(frame, &incoming); err != nil {
			_ = conn.Close()
			return fmt.Errorf("decode initialize response: %w", err)
		}
		if incoming.Type != "response" || rawMessageKey(incoming.RequestID) != initializeID {
			c.dispatch(conn, incoming)
			continue
		}
		if incoming.ResultType == "error" {
			_ = conn.Close()
			return fmt.Errorf("initialize failed")
		}
		var result struct {
			ClientID string `json:"clientId"`
		}
		if err := json.Unmarshal(incoming.Result, &result); err != nil || result.ClientID == "" {
			_ = conn.Close()
			return fmt.Errorf("initialize response did not include clientId")
		}
		c.mu.Lock()
		c.clientID = result.ClientID
		c.nextGeneration++
		c.generation = c.nextGeneration
		c.mu.Unlock()
		break
	}
	if deadlineConn, ok := conn.(interface{ SetReadDeadline(time.Time) error }); ok {
		_ = deadlineConn.SetReadDeadline(time.Time{})
	}
	c.status.update(func(status *Status) { status.State = StateReady })
	c.signalReady()
	c.mu.RLock()
	generation := c.generation
	c.mu.RUnlock()
	if c.opts.OnReady != nil {
		c.opts.OnReady(generation)
	}
	for {
		frame, err := ReadFrame(conn)
		if err != nil {
			c.disconnect(err)
			if errors.Is(err, io.EOF) {
				return errSocketUnavailable
			}
			return err
		}
		var incoming envelope
		if err := json.Unmarshal(frame, &incoming); err != nil {
			c.disconnect(err)
			return err
		}
		c.dispatch(conn, incoming)
	}
}

func (c *Client) dispatch(conn net.Conn, incoming envelope) {
	switch incoming.Type {
	case "response":
		requestID := rawMessageKey(incoming.RequestID)
		c.mu.Lock()
		waiter, ok := c.pending[requestID]
		if ok {
			delete(c.pending, requestID)
		}
		generation := c.generation
		currentConn := c.conn
		c.mu.Unlock()
		if !ok {
			return
		}
		if currentConn != conn || waiter.generation != generation {
			waiter.result <- requestResult{err: &RequestError{
				Method: waiter.method, Delivery: DeliveryUncertain, Cause: errors.New("response came from a stale connection"),
			}}
			return
		}
		if incoming.ResultType == "error" {
			delivery := DeliveryUncertain
			if isNoClientFound(incoming.Error, waiter.method) {
				delivery = DeliveryNoClient
			}
			waiter.result <- requestResult{err: &RequestError{
				Method: waiter.method, Delivery: delivery, Cause: errors.New("remote request failed"),
			}}
			return
		}
		if waiter.targetClientID != "" && strings.TrimSpace(incoming.HandledByClientID) != waiter.targetClientID {
			waiter.result <- requestResult{err: &RequestError{
				Method: waiter.method, Delivery: DeliveryUncertain, Cause: errors.New("response handler did not match the targeted Desktop owner"),
			}}
			return
		}
		waiter.result <- requestResult{value: incoming.Result, handledByClientID: incoming.HandledByClientID}
	case "broadcast":
		if c.opts.OnBroadcast != nil {
			c.opts.OnBroadcast(Broadcast{
				Method: incoming.Method, Version: incoming.Version,
				SourceClientID: incoming.SourceClientID, Params: incoming.Params,
			})
		}
	case "client-discovery-request":
		candidate := incoming
		if incoming.Request != nil {
			candidate = *incoming.Request
		}
		sourceClientID := strings.TrimSpace(candidate.SourceClientID)
		if sourceClientID == "" {
			sourceClientID = strings.TrimSpace(incoming.SourceClientID)
		}
		request := IncomingRequest{
			RequestID: candidate.RequestID, Method: candidate.Method, Version: candidate.Version,
			SourceClientID: sourceClientID, Params: candidate.Params,
		}
		canHandle := requestVersionMatches(request) && c.opts.CanHandle != nil && c.opts.CanHandle(request)
		c.writeJSON(conn, map[string]any{
			"type": "client-discovery-response", "requestId": json.RawMessage(incoming.RequestID),
			"response": map[string]any{"canHandle": canHandle},
		})
	case "request":
		go c.handleIncomingRequest(conn, incoming)
	}
}

func isNoClientFound(value, method string) bool {
	normalized := strings.ToLower(strings.TrimSpace(value))
	explicitHandlerMiss := "no codex ipc client can handle " + strings.ToLower(strings.TrimSpace(method)) + "."
	return normalized == "no-client-found" || normalized == explicitHandlerMiss
}

func (c *Client) handleIncomingRequest(conn net.Conn, incoming envelope) {
	request := IncomingRequest{
		RequestID: incoming.RequestID, Method: incoming.Method, Version: incoming.Version,
		SourceClientID: incoming.SourceClientID, Params: incoming.Params,
	}
	var result any
	var err error
	if !requestVersionMatches(request) {
		err = fmt.Errorf("request-version-mismatch")
	} else if c.opts.CanHandle != nil && !c.opts.CanHandle(request) {
		err = fmt.Errorf("no-client-found")
	} else if c.opts.HandleRequest == nil {
		err = fmt.Errorf("unsupported follower request")
	} else {
		ctx, cancel := context.WithTimeout(context.Background(), c.opts.RequestTimeout)
		result, err = c.opts.HandleRequest(ctx, request)
		cancel()
	}
	response := map[string]any{
		"type": "response", "requestId": json.RawMessage(incoming.RequestID), "method": incoming.Method,
		"handledByClientId": c.currentClientID(),
	}
	if err != nil {
		response["resultType"] = "error"
		response["error"] = "Mimi owner request failed"
	} else {
		response["resultType"] = "success"
		response["result"] = result
	}
	c.writeJSON(conn, response)
}

func requestVersionMatches(request IncomingRequest) bool {
	expected, ok := MethodVersion(request.Method)
	return ok && request.Version == expected
}

func (c *Client) writeJSON(conn net.Conn, value any) {
	payload, err := json.Marshal(value)
	if err == nil {
		_ = c.write(conn, payload)
	}
}

func (c *Client) write(conn net.Conn, payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	return WriteFrame(conn, payload)
}

func (c *Client) disconnect(cause error) {
	c.mu.Lock()
	conn := c.conn
	generation := c.generation
	c.conn = nil
	c.clientID = ""
	c.generation = 0
	pending := c.pending
	c.pending = make(map[string]pendingResponse)
	c.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
	for _, waiter := range pending {
		waiter.result <- requestResult{err: &RequestError{Method: waiter.method, Delivery: DeliveryUncertain, Cause: cause}}
	}
	if conn != nil && generation != 0 && c.opts.OnDisconnect != nil {
		c.opts.OnDisconnect(generation)
	}
}

func (c *Client) removePending(requestID string) {
	c.mu.Lock()
	delete(c.pending, requestID)
	c.mu.Unlock()
}

func (c *Client) currentClientID() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.clientID
}

func (c *Client) signalReady() {
	c.mu.Lock()
	select {
	case <-c.ready:
	default:
		close(c.ready)
	}
	c.mu.Unlock()
}

func rawMessageKey(raw json.RawMessage) string {
	var value string
	if json.Unmarshal(raw, &value) == nil {
		return value
	}
	return string(raw)
}
