package httpapi

// 后台审批连接脱离单个 HTTP 请求存活，必须随 Router 显式关闭。
// 先在各自 map 锁下禁止新连接登记，再在锁外关闭，避免 close 回收 map 时死锁。
func (r *Router) shutdownApprovalObservers() {
	r.codexBrokerMu.Lock()
	r.codexBrokersClosing = true
	brokers := make([]*codexGatewayBroker, 0, len(r.codexBrokers))
	for _, broker := range r.codexBrokers {
		brokers = append(brokers, broker)
	}
	r.codexBrokerMu.Unlock()
	r.claudeObserverMu.Lock()
	r.claudeObserversClosing = true
	observers := make([]*claudeApprovalObserver, 0, len(r.claudeObservers))
	for _, observer := range r.claudeObservers {
		observers = append(observers, observer)
	}
	r.claudeObserverMu.Unlock()
	for _, broker := range brokers {
		broker.close("router_shutdown")
	}
	for _, observer := range observers {
		observer.close("router_shutdown")
	}
}
