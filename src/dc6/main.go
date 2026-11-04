// dc6: transparent TCP bridge that lets an IPv4-only client (mtg) reach
// Telegram datacenters over IPv6 through the provider NAT64 prefix.
//
// iptables REDIRECTs the IPv4 destinations into this listener; SO_ORIGINAL_DST
// recovers the address the client wanted, and the connection is re-established
// to <prefix>::<ipv4> over IPv6.
package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	nPrefix       = "2a01:4f8:c2c:123f:64:5"
	listenAddr    = "127.0.0.1:19191"
	soOriginalDst = 80
)

func originalDst(fd int) (string, int, error) {
	var sa [16]byte
	l := uint32(16)
	_, _, errno := syscall.Syscall6(syscall.SYS_GETSOCKOPT,
		uintptr(fd), uintptr(syscall.SOL_IP), uintptr(soOriginalDst),
		uintptr(unsafe.Pointer(&sa[0])), uintptr(unsafe.Pointer(&l)), 0)
	if errno != 0 {
		return "", 0, errno
	}
	port := int(binary.BigEndian.Uint16(sa[2:4]))
	ip := net.IPv4(sa[4], sa[5], sa[6], sa[7])
	return ip.String(), port, nil
}

func v4ToPrefix(ip string) string {
	v4 := net.ParseIP(ip).To4()
	if v4 == nil {
		return ""
	}
	return fmt.Sprintf("%s:%x:%x", nPrefix,
		binary.BigEndian.Uint16(v4[0:2]), binary.BigEndian.Uint16(v4[2:4]))
}

func handle(c net.Conn) {
	defer c.Close()
	tcp, ok := c.(*net.TCPConn)
	if !ok {
		return
	}
	raw, err := tcp.SyscallConn()
	if err != nil {
		return
	}
	var dstIP string
	var dstPort int
	var oerr error
	_ = raw.Control(func(fd uintptr) {
		dstIP, dstPort, oerr = originalDst(int(fd))
	})
	if oerr != nil {
		log.Printf("original destination unavailable: %v", oerr)
		return
	}
	target := net.JoinHostPort(v4ToPrefix(dstIP), fmt.Sprint(dstPort))
	up, err := net.DialTimeout("tcp6", target, 10*time.Second)
	if err != nil {
		log.Printf("dial %s failed: %v", target, err)
		return
	}
	defer up.Close()
	log.Printf("bridge %s (%s:%d) -> %s", c.RemoteAddr(), dstIP, dstPort, target)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _, _ = io.Copy(up, c) }()
	go func() { defer wg.Done(); _, _ = io.Copy(c, up) }()
	wg.Wait()
}

func main() {
	ln, err := net.Listen("tcp4", listenAddr)
	if err != nil {
		log.Fatalf("listen %s: %v", listenAddr, err)
	}
	log.Printf("dc6 listening on %s, prefix %s::/96", listenAddr, nPrefix)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go handle(c)
	}
}
