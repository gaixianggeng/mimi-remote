//go:build linux

package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"html/template"
	"net"
	"net/http"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/skip2/go-qrcode"
)

type linuxPanelResult struct {
	Output, Error string
	Pair          *linuxPairingInfo
}
type linuxTrayPanel struct {
	app                 *linuxTrayApplication
	server              *http.Server
	origin, base, nonce string
	mu                  sync.Mutex
	results             map[string]linuxPanelResult
	open                func(string) error
}
type linuxPanelPage struct {
	ButtonDisabled, CanStart, CanStop, AutoReload                                                            bool
	Base, Nonce, Heading, Action, Button, Warning, State, Details, Endpoint, Output, Error, PairURL, Expires string
	QR                                                                                                       template.URL
}

var linuxPanelActions = map[string][3]string{
	"status":  {"当前主机", "", ""},
	"pair":    {"配对设备", "生成新的配对二维码", "请用 Mimi Remote 扫描短期二维码。过期后重新生成。"},
	"doctor":  {"运行诊断", "运行诊断", "检查当前配置与 Runtime 就绪状态。"},
	"logs":    {"服务日志", "读取最近日志", "仅显示最近 200 行，凭据信息会隐藏。"},
	"start":   {"启动服务", "启动服务", "启动当前用户的 Mimi Remote 服务。"},
	"restart": {"重启服务", "确认重启服务", "这会中断手机和平板的当前连接。"},
	"stop":    {"停止服务", "确认停止服务", "这会中断手机和平板的连接，直到再次启动服务。"},
	"refresh": {"刷新状态", "刷新状态", ""},
}

func newLinuxTrayPanel(app *linuxTrayApplication) (*linuxTrayPanel, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	token := make([]byte, 32)
	if _, err = rand.Read(token); err != nil {
		listener.Close()
		return nil, err
	}
	p := &linuxTrayPanel{app: app, origin: "http://" + listener.Addr().String(), nonce: hex.EncodeToString(token), results: map[string]linuxPanelResult{}}
	p.base = p.origin + "/" + p.nonce + "/"
	p.open = func(address string) error {
		// xdg-open may remain attached to a newly launched browser. The tray
		// must never own or cancel that browser's lifetime, including on quit.
		cmd := exec.Command("xdg-open", address)
		if err := cmd.Start(); err != nil {
			return err
		}
		go func() { _ = cmd.Wait() }()
		return nil
	}

	p.server = &http.Server{Handler: p, ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 100 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	go func() { _ = p.server.Serve(listener) }()
	return p, nil
}
func (p *linuxTrayPanel) close() { _ = p.server.Close() }
func (p *linuxTrayPanel) show(action string) {
	if _, ok := linuxPanelActions[action]; !ok {
		action = "status"
	}
	if err := p.open(p.base + action); err != nil {
		// No capability URLs or pairing content in logs/notifications.
		fmt.Println("无法打开本机状态面板，请检查默认浏览器和 xdg-open。")
	}
}
func (p *linuxTrayPanel) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	// Native form POSTs carry Origin: null under no-referrer. Keep the
	// real same-origin Origin for CSRF checks, without sending referrers away.
	w.Header().Set("Referrer-Policy", "same-origin")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; img-src data:; style-src 'nonce-"+p.nonce+"'; script-src 'nonce-"+p.nonce+"'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
	prefix := "/" + p.nonce + "/"
	if r.Host != strings.TrimPrefix(p.origin, "http://") || !strings.HasPrefix(r.URL.Path, prefix) {
		http.NotFound(w, r)
		return
	}
	action := strings.TrimPrefix(r.URL.Path, prefix)
	metadata, ok := linuxPanelActions[action]
	if !ok {
		http.NotFound(w, r)
		return
	}
	if r.Method == http.MethodPost {
		if r.Header.Get("Origin") != p.origin {
			http.Error(w, "请求来源无效", http.StatusForbidden)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		if r.ParseForm() != nil || subtle.ConstantTimeCompare([]byte(r.PostForm.Get("csrf")), []byte(p.nonce)) != 1 {
			http.Error(w, "请求已失效", http.StatusForbidden)
			return
		}
		if action == "status" {
			http.Error(w, "不支持的操作", http.StatusMethodNotAllowed)
			return
		}
		output, pair, err := p.app.perform(action)
		result := linuxPanelResult{Output: output, Pair: pair}
		if err != nil {
			result.Error = redactTrayText(err.Error())
		} else if output == "" && pair == nil {
			result.Output = "操作已完成"
		}
		p.mu.Lock()
		p.results[action] = result
		p.mu.Unlock()
		http.Redirect(w, r, p.base+action, http.StatusSeeOther)
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "不支持的请求", http.StatusMethodNotAllowed)
		return
	}
	snapshot := p.app.snapshot()
	page := linuxPanelPage{Base: p.base, Nonce: p.nonce, Action: action, Heading: metadata[0], Button: metadata[1], Warning: metadata[2], State: snapshot.title(), Error: snapshot.Error}
	page.ButtonDisabled = true
	page.AutoReload = snapshot.Busy
	for _, item := range linuxMenuItems(snapshot) {
		if item.Action == action {
			page.ButtonDisabled = !item.Enabled
		}
		if item.Action == "start" {
			page.CanStart = item.Enabled
		}
		if item.Action == "stop" {
			page.CanStop = item.Enabled
		}
	}
	if snapshot.HasStatus {
		page.Details = redactTrayText(snapshot.Status.details())
		page.Endpoint = snapshot.Status.Endpoint
	}
	p.mu.Lock()
	result := p.results[action]
	p.mu.Unlock()
	page.Output = result.Output
	if result.Error != "" {
		page.Error = result.Error
	}
	if result.Pair != nil {
		expires, err := time.Parse(time.RFC3339, result.Pair.PairExpiresAt)
		if err == nil && time.Now().Before(expires) {
			image, err := qrcode.Encode(result.Pair.PairURL, qrcode.Medium, 320)
			if err == nil {
				page.QR = template.URL("data:image/png;base64," + base64.StdEncoding.EncodeToString(image))
				page.PairURL = result.Pair.PairURL
				page.Expires = expires.Format(time.RFC3339)
			}
		} else {
			page.Error = "配对二维码已过期，请重新生成。"
		}
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = linuxPanelTemplate.Execute(w, page)
}

var linuxPanelTemplate = template.Must(template.New("panel").Parse(`<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Mimi Remote · {{.Heading}}</title>{{if .AutoReload}}<meta http-equiv="refresh" content="3">{{end}}
<style nonce="{{.Nonce}}">
:root{color-scheme:light dark;font-family:system-ui,sans-serif;background:#f5f5f8;color:#232332}body{max-width:800px;margin:48px auto;padding:0 24px}header{display:flex;justify-content:space-between;align-items:center;gap:20px}header strong{font-size:20px}header span{font-size:13px;color:#596879}nav{display:flex;flex-wrap:wrap;gap:18px;margin:24px 0}a{color:#6754c7;text-decoration:none}main{background:#fff;border:1px solid #dedee7;border-radius:18px;padding:28px}h1{font-size:25px;margin-top:0}p{line-height:1.7}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:13px/1.7 ui-monospace,monospace;background:#f5f5f8;padding:16px;border-radius:10px}button{background:#6554ba;color:white;border:0;border-radius:9px;padding:12px 18px;cursor:pointer;font:inherit}button:disabled{opacity:.6;cursor:wait}.error{color:#a33f24;background:#fff1e8;border-radius:10px;padding:12px}.endpoint{display:flex;gap:12px;align-items:center;flex-wrap:wrap}input{flex:1;min-width:200px;padding:10px;font:13px ui-monospace,monospace;border:1px solid #d5d5df;border-radius:8px}.qr{display:block;max-width:100%;margin:24px auto}.muted{color:#697182;font-size:13px}form{margin-top:20px}
@media(prefers-color-scheme:dark){:root{background:#17171e;color:#ececf1}main{background:#23232c;border-color:#383846}pre{background:#191921}a{color:#b6a7ff}.error{background:#422e26;color:#ffb795}input{background:#191921;border-color:#444450;color:#eee}header span,.muted{color:#a7a7b8}}
</style>
<header><strong>Mimi Remote</strong><span>{{.State}}</span></header>
<nav><a href="{{.Base}}status">主机状态</a><a href="{{.Base}}pair">配对设备</a><a href="{{.Base}}doctor">诊断</a><a href="{{.Base}}logs">日志</a></nav>
<main><h1>{{.Heading}}</h1>{{if .Error}}<p class="error" role="alert">{{.Error}}</p>{{end}}
{{if eq .Action "status"}}<div class="endpoint"><input id="endpoint" aria-label="连接地址" readonly value="{{.Endpoint}}"><button data-copy="endpoint">复制地址</button></div><pre>{{.Details}}</pre><nav><a href="{{.Base}}refresh">刷新状态</a>{{if .CanStart}}<a href="{{.Base}}start">启动</a>{{end}}{{if .CanStop}}<a href="{{.Base}}restart">重启</a><a href="{{.Base}}stop">停止服务</a>{{end}}</nav>{{end}}
{{if .Warning}}<p>{{.Warning}}</p>{{end}}
{{if .QR}}<div id="pairing" data-expires="{{.Expires}}"><img class="qr" src="{{.QR}}" width="320" height="320" alt="短期配对二维码"><p class="muted">有效期至 <time>{{.Expires}}</time></p><div class="endpoint"><input id="pair-url" aria-label="短期配对链接" readonly value="{{.PairURL}}"><button data-copy="pair-url">复制短期链接</button></div></div>{{end}}
{{if .Output}}<pre>{{.Output}}</pre>{{end}}
{{if .Button}}<form method="post" action="{{.Base}}{{.Action}}"><input type="hidden" name="csrf" value="{{.Nonce}}"><button type="submit" {{if .ButtonDisabled}}disabled{{end}}>{{.Button}}</button></form>{{end}}
<p id="feedback" class="muted" role="status"></p></main>
<script nonce="{{.Nonce}}">
document.querySelectorAll('[data-copy]').forEach(button=>button.addEventListener('click',async()=>{const input=document.getElementById(button.dataset.copy);try{await navigator.clipboard.writeText(input.value);document.getElementById('feedback').textContent='已复制'}catch{input.select();document.getElementById('feedback').textContent='请按 Ctrl+C 复制'}}));
document.querySelectorAll('form').forEach(form=>form.addEventListener('submit',()=>{const button=form.querySelector('button');button.disabled=true;button.textContent='正在处理…'}));
const pairing=document.getElementById('pairing');if(pairing){const expire=()=>{if(Date.now()>=Date.parse(pairing.dataset.expires)){pairing.replaceChildren();pairing.textContent='配对二维码已过期，请重新生成。'}};expire();setInterval(expire,1000)}
</script></html>`))
