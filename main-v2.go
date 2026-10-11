// ws — a clean WebSocket-to-TCP relay (SSH/OpenVPN tunnel).
//
// This is a from-scratch, malware-free reimplementation of the public
// "ws-epro" style proxy. It does ONE thing: it listens on local ports,
// answers the client's HTTP/WebSocket upgrade with "101 Switching
// Protocols", and then relays raw bytes to a target host:port.
//
// It deliberately contains NONE of the following, which were present in
// the binary this replaces:
//   - writing any SSH key to ~/.ssh/authorized_keys
//   - chattr/immutable attribute tampering or a "key watcher"
//   - Telegram notifications / data exfiltration
//   - fetching a remote IP allow-list or any kill-switch
//   - fetching/saving the machine's public IP anywhere
//
// Config format is compatible with the original config.conf.
//
// Build:  go build -o ws .
// Run:    ./ws -f config.conf
package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// wsGUID is the fixed magic value from RFC 6455 used to compute the
// Sec-WebSocket-Accept response header.
const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type ListenerConfig struct {
	TargetHost string
	TargetPort int
	ListenPort int
	BufLen     int
}

type Config struct {
	Verbose   int
	Listeners []ListenerConfig
}

// ---------------------------------------------------------------------------
// Minimal config parser (no external dependencies).
//
// Accepts the same simple YAML-ish format as the original config.conf:
//
//   verbose: 0
//   listen:
//   - target_host: 127.0.0.1
//     target_port: 22
//     listen_port: 10015
//     bufLen: 16384
//
// Lines starting with '#' and blank lines are ignored. Each "- " under
// "listen:" begins a new listener block.
// ---------------------------------------------------------------------------

func loadConfig(path string) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	cfg := &Config{}
	var cur *ListenerConfig
	flush := func() {
		if cur != nil {
			cfg.Listeners = append(cfg.Listeners, *cur)
			cur = nil
		}
	}

	sc := bufio.NewScanner(f)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		raw := sc.Text()

		// Strip comments (# or //) and surrounding whitespace.
		line := raw
		if i := strings.IndexAny(line, "#"); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		// New listener entry.
		if strings.HasPrefix(line, "-") {
			flush()
			cur = &ListenerConfig{BufLen: 16384}
			line = strings.TrimSpace(strings.TrimPrefix(line, "-"))
			if line == "" {
				continue
			}
		}

		key, val, ok := splitKV(line)
		if !ok {
			return nil, fmt.Errorf("config line %d: expected 'key: value', got %q", lineNo, raw)
		}

		switch key {
		case "verbose":
			cfg.Verbose = atoiDefault(val, 0)
		case "listen":
			// section header, nothing to read on this line
		case "target_host":
			requireCur(&cur)
			cur.TargetHost = val
		case "target_port":
			requireCur(&cur)
			cur.TargetPort = atoiDefault(val, 0)
		case "listen_port":
			requireCur(&cur)
			cur.ListenPort = atoiDefault(val, 0)
		case "buflen", "bufLen":
			requireCur(&cur)
			cur.BufLen = atoiDefault(val, 16384)
		default:
			// Unknown keys are ignored for forward-compatibility.
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	flush()

	if len(cfg.Listeners) == 0 {
		return nil, fmt.Errorf("no listeners defined in %s", path)
	}
	for i := range cfg.Listeners {
		l := &cfg.Listeners[i]
		if l.TargetHost == "" {
			l.TargetHost = "127.0.0.1"
		}
		if l.BufLen <= 0 {
			l.BufLen = 16384
		}
		if l.ListenPort <= 0 || l.TargetPort <= 0 {
			return nil, fmt.Errorf("listener %d: listen_port and target_port are required", i+1)
		}
	}
	return cfg, nil
}

func requireCur(cur **ListenerConfig) {
	if *cur == nil {
		*cur = &ListenerConfig{BufLen: 16384}
	}
}

func splitKV(line string) (key, val string, ok bool) {
	i := strings.Index(line, ":")
	if i < 0 {
		return "", "", false
	}
	key = strings.TrimSpace(line[:i])
	val = strings.TrimSpace(line[i+1:])
	return key, val, true
}

func atoiDefault(s string, def int) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return def
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return n
}

// ---------------------------------------------------------------------------
// Proxy
// ---------------------------------------------------------------------------

type ProxyServer struct {
	cfg     ListenerConfig
	verbose int
}

func NewProxyServer(cfg ListenerConfig, verbose int) *ProxyServer {
	return &ProxyServer{cfg: cfg, verbose: verbose}
}

func (p *ProxyServer) listenAddr() string {
	return fmt.Sprintf("0.0.0.0:%d", p.cfg.ListenPort)
}

func (p *ProxyServer) targetAddr() string {
	return net.JoinHostPort(p.cfg.TargetHost, strconv.Itoa(p.cfg.TargetPort))
}

func (p *ProxyServer) Start() error {
	ln, err := net.Listen("tcp", p.listenAddr())
	if err != nil {
		return err
	}
	log.Printf("Listening on %s, forwarding to %s", p.listenAddr(), p.targetAddr())
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("Accept error: %v", err)
			continue
		}
		go p.handleConnection(conn)
	}
}

func (p *ProxyServer) handleConnection(client net.Conn) {
	defer client.Close()

	br := bufio.NewReader(client)

	// Peek the first bytes to decide how to treat the connection,
	// without consuming them. Injector-style clients send an HTTP
	// upgrade request first; other modes (direct SSH, or clients that
	// expect the server to speak first) send raw bytes. A short
	// deadline keeps a silent client from hanging the handshake — if
	// nothing arrives we fall through to a plain relay, which also
	// serves "server speaks first" modes correctly.
	_ = client.SetReadDeadline(time.Now().Add(15 * time.Second))
	head, _ := br.Peek(8)
	_ = client.SetReadDeadline(time.Time{}) // clear deadline for the relay phase

	if looksLikeHTTP(head) {
		reqLine, headers, err := readHTTPHead(br)
		if err != nil {
			if p.verbose >= 1 {
				log.Printf("Read error from client %s: %v", client.RemoteAddr(), err)
			}
			return
		}
		if p.verbose >= 2 {
			log.Printf("HTTP request from %s: %q", client.RemoteAddr(), reqLine)
		}

		// Build the 101 response. If the client sent a proper
		// Sec-WebSocket-Key, answer with a spec-compliant upgrade so
		// real WebSocket clients are happy; otherwise send a bare 101,
		// which is what simple tunnel clients expect.
		var resp string
		if key := headers["sec-websocket-key"]; key != "" {
			accept := calculateWebSocketAccept(key)
			resp = "HTTP/1.1 101 Switching Protocols\r\n" +
				"Upgrade: websocket\r\n" +
				"Connection: Upgrade\r\n" +
				"Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
		} else {
			resp = "HTTP/1.1 101 Switching Protocols\r\n\r\n"
		}
		if _, err := client.Write([]byte(resp)); err != nil {
			return
		}
	} else if p.verbose >= 2 {
		log.Printf("Raw (non-HTTP) connection from %s, relaying directly", client.RemoteAddr())
	}

	// Connect to the real target (e.g. local SSH on 127.0.0.1:22).
	target, err := net.DialTimeout("tcp", p.targetAddr(), 10*time.Second)
	if err != nil {
		if p.verbose >= 1 {
			log.Printf("Target connection error (%s): %v", p.targetAddr(), err)
		}
		return
	}
	defer target.Close()

	// Relay in both directions until either side closes. Any bytes the
	// client already sent (HTTP body after headers, or the peeked raw
	// bytes) are still buffered in br and get forwarded here.
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		pipe(target, br, p.cfg.BufLen)
		halfClose(target)
	}()
	go func() {
		defer wg.Done()
		pipe(client, target, p.cfg.BufLen)
		halfClose(client)
	}()
	wg.Wait()

	if p.verbose >= 1 {
		log.Printf("Connection closed for client: %s", client.RemoteAddr())
	}
}

// readHTTPHead reads the request line and headers up to the blank line.
// Header names are returned lower-cased.
func readHTTPHead(br *bufio.Reader) (reqLine string, headers map[string]string, err error) {
	headers = make(map[string]string)
	first := true
	for {
		line, e := br.ReadString('\n')
		if e != nil {
			return reqLine, headers, e
		}
		line = strings.TrimRight(line, "\r\n")
		if first {
			reqLine = line
			first = false
			continue
		}
		if line == "" {
			return reqLine, headers, nil
		}
		if i := strings.Index(line, ":"); i >= 0 {
			name := strings.ToLower(strings.TrimSpace(line[:i]))
			val := strings.TrimSpace(line[i+1:])
			headers[name] = val
		}
	}
}

// looksLikeHTTP reports whether the peeked bytes begin with a common
// HTTP request method, i.e. an injector-style upgrade request.
func looksLikeHTTP(b []byte) bool {
	s := string(b)
	for _, m := range []string{"GET ", "POST ", "PUT ", "HEAD ", "OPTIONS", "CONNECT", "DELETE ", "PATCH ", "TRACE "} {
		if strings.HasPrefix(s, m) {
			return true
		}
	}
	return false
}

func calculateWebSocketAccept(key string) string {
	h := sha1.New()
	io.WriteString(h, key+wsGUID)
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

func pipe(dst io.Writer, src io.Reader, bufLen int) {
	if bufLen <= 0 {
		bufLen = 16384
	}
	buf := make([]byte, bufLen)
	io.CopyBuffer(dst, src, buf)
}

// halfClose closes the write side of a TCP connection if possible, so the
// peer sees EOF without tearing down the read side prematurely.
func halfClose(c net.Conn) {
	if tcp, ok := c.(*net.TCPConn); ok {
		_ = tcp.CloseWrite()
		return
	}
	_ = c.Close()
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

func main() {
	cfgPath := flag.String("f", "", "path to config file (e.g. config.conf)")
	flag.Parse()

	if *cfgPath == "" {
		log.Fatalf("Please load a config with: ws -f config.conf")
	}

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	log.SetFlags(log.LstdFlags)

	var wg sync.WaitGroup
	for _, lc := range cfg.Listeners {
		lc := lc
		wg.Add(1)
		go func() {
			defer wg.Done()
			srv := NewProxyServer(lc, cfg.Verbose)
			if err := srv.Start(); err != nil {
				log.Printf("Listener on port %d failed: %v", lc.ListenPort, err)
			}
		}()
	}
	wg.Wait()
}
