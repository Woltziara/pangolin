package main

/*
#include <stdint.h>
*/
import "C"

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"

	"github.com/xjasonlyu/tun2socks/v2/engine"
	"github.com/xjasonlyu/tun2socks/v2/tunnel/statistic"
)

var running atomic.Bool

//export HeyTun2SocksStart
func HeyTun2SocksStart(tunFd C.int, socksHost *C.char, socksPort C.int, mtu C.int) C.int {
	host := C.GoString(socksHost)
	if startTun2Socks(int(tunFd), host, int(socksPort), int(mtu)) != nil {
		return -1
	}
	return 0
}

//export HeyTun2SocksStop
func HeyTun2SocksStop() {
	stopTun2Socks()
}

//export HeyTun2SocksUploadBytes
func HeyTun2SocksUploadBytes() C.int64_t {
	return C.int64_t(statistic.DefaultManager.Snapshot().UploadTotal)
}

//export HeyTun2SocksDownloadBytes
func HeyTun2SocksDownloadBytes() C.int64_t {
	return C.int64_t(statistic.DefaultManager.Snapshot().DownloadTotal)
}

func main() {
	tunFd := flag.Int("tun-fd", -1, "inherited TUN fd")
	socksHost := flag.String("socks-host", "127.0.0.1", "SOCKS host")
	socksPort := flag.Int("socks-port", 10808, "SOCKS port")
	mtu := flag.Int("mtu", 1400, "TUN MTU")
	flag.Parse()

	if err := startTun2Socks(*tunFd, *socksHost, *socksPort, *mtu); err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
	stopTun2Socks()
}

func startTun2Socks(tunFd int, socksHost string, socksPort int, mtu int) error {
	if running.Load() {
		return nil
	}
	if tunFd < 0 || socksHost == "" || socksPort <= 0 || mtu <= 0 {
		return fmt.Errorf("invalid tun2socks arguments: tunFd=%d host=%q port=%d mtu=%d", tunFd, socksHost, socksPort, mtu)
	}

	engine.Insert(&engine.Key{
		MTU:      mtu,
		Device:   fmt.Sprintf("fd://%d", tunFd),
		Proxy:    fmt.Sprintf("socks5://%s:%d", socksHost, socksPort),
		LogLevel: "warn",
		// 开启 gvisor 接收窗口自动调优（默认关闭）。关闭时接收缓冲固定在 1MB，
		// 高 RTT / 高带宽链路上单流吞吐被窗口卡死（吞吐 ≈ 窗口/RTT）；
		// 打开后接收窗口按 BDP 自动增长到上限（4MB），显著提升下载速度。
		// 只开自动调优、不强制放大每连接默认缓冲，避免多连接下手机内存占用过高。
		TCPModerateReceiveBuffer: true,
	})
	engine.Start()
	running.Store(true)
	return nil
}

func stopTun2Socks() {
	if running.Swap(false) {
		engine.Stop()
	}
}
