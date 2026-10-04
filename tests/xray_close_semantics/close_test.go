package xray_close_semantics

import (
	"bytes"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
)

func socksJSON(port int) []byte {
	return []byte(fmt.Sprintf(`{
  "log": {"loglevel": "none"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": %d,
    "protocol": "socks",
    "settings": {"udp": false, "auth": "noauth"}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}`, port))
}

func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	return port
}

func probeSocks(port int) (live bool, hex string) {
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 400*time.Millisecond)
	if err != nil {
		return false, "dead"
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(400 * time.Millisecond))
	if _, err := c.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		return false, "write"
	}
	buf := make([]byte, 2)
	n, err := c.Read(buf)
	if n >= 1 && buf[0] == 0x05 {
		if n >= 2 {
			return true, fmt.Sprintf("%02x%02x", buf[0], buf[1])
		}
		return true, fmt.Sprintf("%02x", buf[0])
	}
	if err != nil {
		return false, "no-socks"
	}
	return false, "not-socks5"
}

func TestUnpatchedDoubleStartCloseLeavesOrRevealsSocks(t *testing.T) {
	port := freePort(t)
	cfg := socksJSON(port)
	inst, err := core.StartInstance("json", cfg)
	if err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	live, hex := probeSocks(port)
	if !live {
		_ = inst.Close()
		t.Fatalf("StartInstance did not leave a SOCKS service: %s", hex)
	}
	t.Log("after StartInstance SOCKS", hex)

	secondErr := inst.Start()
	if secondErr != nil {
		t.Log("second Start failed (hub not overwritten):", secondErr)
		if !probeSocksAlive(t, port) {
			t.Fatal("first listener vanished before Close")
		}
		if err := inst.Close(); err != nil {
			t.Fatal(err)
		}
		if live, hex = probeSocks(port); live {
			t.Fatalf("single-hub Close left SOCKS %s", hex)
		}
		return
	}

	if err := inst.Close(); err != nil {
		t.Fatal(err)
	}
	live, hex = probeSocks(port)
	if !live {
		t.Fatal("double-start Close did not leave leftover SOCKS; old counterexample not revealed on this host")
	}
	t.Log("revealed leftover SOCKS after double-start Close", hex)
}

func probeSocksAlive(t *testing.T, port int) bool {
	t.Helper()
	live, _ := probeSocks(port)
	return live
}

func TestSingleStartCloseStopsSocks(t *testing.T) {
	port := freePort(t)
	config, err := core.LoadConfig("json", bytes.NewReader(socksJSON(port)))
	if err != nil {
		t.Fatal(err)
	}
	inst, err := core.New(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := inst.Start(); err != nil {
		t.Fatal(err)
	}
	live, hex := probeSocks(port)
	if !live {
		_ = inst.Close()
		t.Fatalf("single Start did not serve SOCKS: %s", hex)
	}
	if err := inst.Close(); err != nil {
		t.Fatal(err)
	}
	live, hex = probeSocks(port)
	if live {
		t.Fatalf("single Start+Close left SOCKS %s", hex)
	}
}

func TestStartFailureCloseDoesNotLeaveSocks(t *testing.T) {
	port := freePort(t)
	holder, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close()

	config, err := core.LoadConfig("json", bytes.NewReader(socksJSON(port)))
	if err != nil {
		t.Fatal(err)
	}
	inst, err := core.New(config)
	if err != nil {
		t.Fatal(err)
	}
	startErr := inst.Start()
	if startErr == nil {
		_ = inst.Close()
		t.Fatal("Start should fail when port is already taken")
	}
	if err := inst.Close(); err != nil {
		t.Log("Close after failed Start:", err)
	}
	_ = holder.Close()
	time.Sleep(50 * time.Millisecond)
	live, hex := probeSocks(port)
	if live {
		t.Fatalf("failed Start+Close left SOCKS %s", hex)
	}
}
