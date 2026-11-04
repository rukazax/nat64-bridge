// vpn4: gives AmneziaWG clients IPv4 connectivity through the provider NAT64.
//
// The host has no IPv4 route, but IPv6 traffic to the NAT64 prefix reaches the
// IPv4 internet. Clients' IPv4 packets are redirected here by iptables
// (REDIRECT keeps the original destination readable via SO_ORIGINAL_DST); every
// TCP connection is re-established to <prefix>::<ipv4> over IPv6, and DNS over
// UDP is relayed the same way.
//
// UDP other than DNS is not translated (see the README note).
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
	nPrefix    = "2a01:4f8:c2c:123f:64:5"
	tcpListen  = "0.0.0.0:19192"
	dnsListen  = "0.0.0.0:5353"
	dnsUpstream = "1.1.1.1:53"
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
	return net.IPv4(sa[4], sa[5], sa[6], sa[7]).String(), port, nil
}

func v4ToPrefix(ip string) string {
	v4 := net.ParseIP(ip).To4()
	if v4 == nil {
		return ""
	}
	return fmt.Sprintf("%s:%x:%x", nPrefix,
		binary.BigEndian.Uint16(v4[0:2]), binary.BigEndian.Uint16(v4[2:4]))
}

func handleTCP(c net.Conn) {
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
		log.Printf("original destination unavailable for %s: %v", c.RemoteAddr(), oerr)
		return
	}
	target := net.JoinHostPort(v4ToPrefix(dstIP), fmt.Sprint(dstPort))
	up, err := net.DialTimeout("tcp6", target, 12*time.Second)
	if err != nil {
		log.Printf("dial %s failed: %v", target, err)
		return
	}
	defer up.Close()
	log.Printf("tcp %s -> %s:%d via %s", c.RemoteAddr(), dstIP, dstPort, target)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _, _ = io.Copy(up, c) }()
	go func() { defer wg.Done(); _, _ = io.Copy(c, up) }()
	wg.Wait()
}

func serveTCP() {
	ln, err := net.Listen("tcp4", tcpListen)
	if err != nil {
		log.Fatalf("listen %s: %v", tcpListen, err)
	}
	log.Printf("vpn4 tcp listening on %s (prefix %s::/96)", tcpListen, nPrefix)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go handleTCP(c)
	}
}

// serveDNS relays UDP/TCP DNS queries to the NAT64 prefix. The reply returns
// through conntrack, so the client sees the answer from its own resolver.
func serveDNS() {
	addr, err := net.ResolveUDPAddr("udp4", dnsListen)
	if err != nil {
		log.Fatalf("resolve %s: %v", dnsListen, err)
	}
	pc, err := net.ListenUDP("udp4", addr)
	if err != nil {
		log.Fatalf("listen udp %s: %v", dnsListen, err)
	}
	log.Printf("vpn4 dns relay listening on %s -> %s via NAT64", dnsListen, dnsUpstream)
	upstream := net.JoinHostPort(v4ToPrefix("1.1.1.1"), "53")
	buf := make([]byte, 1500)
	for {
		n, client, err := pc.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		query := make([]byte, n)
		copy(query, buf[:n])
		go func(q []byte, cl *net.UDPAddr) {
			up, err := net.Dial("udp6", upstream)
			if err != nil {
				log.Printf("dns upstream dial: %v", err)
				return
			}
			defer up.Close()
			_ = up.SetDeadline(time.Now().Add(6 * time.Second))
			if _, err := up.Write(q); err != nil {
				return
			}
			resp := make([]byte, 1500)
			rn, err := up.Read(resp)
			if err != nil {
				return
			}
			_, _ = pc.WriteToUDP(resp[:rn], cl)
		}(query, client)
	}
}

func main() {
	go serveDNS()
	serveTCP()
}
