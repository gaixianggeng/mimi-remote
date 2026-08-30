// Command fakebridge stands in for alleycat-claude-bridge in gateway tests.
//
// The real bridge serves a Unix socket and multiplexes connections onto
// sessions. Reproducing that in a shell stub is not practical, so this helper
// owns the socket and runs a caller-supplied shell script per connection with
// stdin/stdout wired to it — letting tests keep expressing bridge behaviour as
// the same small line-oriented scripts they used when the bridge spoke stdio.
package main

import (
	"flag"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

func main() {
	executable, err := os.Executable()
	if err != nil {
		log.Fatalf("fakebridge: executable: %v", err)
	}
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		version := "alleycat-claude-bridge 0.2.8"
		if configured, readErr := os.ReadFile(executable + ".version"); readErr == nil {
			version = strings.TrimSpace(string(configured))
		}
		if version != "" {
			_, _ = os.Stdout.WriteString(version + "\n")
		}
		return
	}

	body := flag.String("body", "", "path to the shell script serving one connection")
	socket := flag.String("socket", "", "unix socket to listen on")
	tcpListen := flag.String("tcp-listen", "", "loopback TCP address to listen on")
	flag.Parse()

	if _, err := os.Stat(executable + ".silent"); err == nil {
		time.Sleep(30 * time.Second)
		return
	}
	if *body == "" {
		*body = executable + ".body"
	}

	network, address := "unix", *socket
	if *tcpListen != "" {
		network, address = "tcp", *tcpListen
	}
	if address == "" {
		log.Fatal("fakebridge: --socket or --tcp-listen is required")
	}
	listener, err := net.Listen(network, address)
	if err != nil {
		log.Fatalf("fakebridge: listen: %v", err)
	}
	defer listener.Close()

	discardReadinessProbe := network == "tcp"
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		if discardReadinessProbe {
			discardReadinessProbe = false
			_ = conn.Close()
			continue
		}
		go serve(conn, *body)
	}
}

func serve(conn net.Conn, body string) {
	defer conn.Close()
	cmd := exec.Command(shellPath(), body)
	cmd.Stdin = conn
	cmd.Stderr = os.Stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}
	// Copy rather than assigning conn to cmd.Stdout so the script's output
	// reaches the socket as it is written, without waiting for exit.
	_, _ = io.Copy(conn, stdout)
	_ = cmd.Wait()
}

func shellPath() string {
	if runtime.GOOS != "windows" {
		return "/bin/sh"
	}
	for _, candidate := range []string{
		`C:\Program Files\Git\bin\bash.exe`,
		`C:\Program Files\Git\usr\bin\bash.exe`,
		filepath.Join(os.Getenv("ProgramW6432"), "Git", "bin", "bash.exe"),
		filepath.Join(os.Getenv("ProgramFiles"), "Git", "bin", "bash.exe"),
		filepath.Join(os.Getenv("ProgramFiles"), "Git", "usr", "bin", "bash.exe"),
		filepath.Join(os.Getenv("LocalAppData"), "Programs", "Git", "bin", "bash.exe"),
	} {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	if path, err := exec.LookPath("bash.exe"); err == nil {
		return path
	}
	return "bash.exe"
}
