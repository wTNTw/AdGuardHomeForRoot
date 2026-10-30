// rawrst: 用原始的 IPPROTO_RAW socket 发一个伪造源地址的 TCP RST，
// 打印 sendto 的 errno。用来判断 AdGuardHome 注入 RST 时的 EPERM
// 是不是系统层面的 netfilter 丢弃。
package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"net"
	"os"
	"syscall"
)

func csum(b []byte) uint16 {
	var s uint32
	for i := 0; i+1 < len(b); i += 2 {
		s += uint32(binary.BigEndian.Uint16(b[i:]))
	}
	if len(b)%2 == 1 {
		s += uint32(b[len(b)-1]) << 8
	}
	for s>>16 != 0 {
		s = (s & 0xffff) + (s >> 16)
	}
	return ^uint16(s)
}

func main() {
	srcS := flag.String("src", "", "伪造的源 IPv4")
	dstS := flag.String("dst", "", "目的 IPv4")
	sport := flag.Int("sport", 44444, "源端口")
	dport := flag.Int("dport", 443, "目的端口")
	flag.Parse()

	src := net.ParseIP(*srcS).To4()
	dst := net.ParseIP(*dstS).To4()
	if src == nil || dst == nil {
		fmt.Println("need -src and -dst IPv4")
		os.Exit(2)
	}

	pkt := make([]byte, 20+20)

	// IPv4 头
	pkt[0] = 0x45
	binary.BigEndian.PutUint16(pkt[2:], uint16(len(pkt)))
	pkt[8] = 64 // TTL
	pkt[9] = syscall.IPPROTO_TCP
	copy(pkt[12:16], src)
	copy(pkt[16:20], dst)
	binary.BigEndian.PutUint16(pkt[10:], csum(pkt[0:20]))

	// TCP 头（RST, ACK）
	tcp := pkt[20:]
	binary.BigEndian.PutUint16(tcp[0:], uint16(*sport))
	binary.BigEndian.PutUint16(tcp[2:], uint16(*dport))
	binary.BigEndian.PutUint32(tcp[8:], 1)
	tcp[12] = 0x50
	tcp[13] = 0x14 // RST|ACK

	pseudo := make([]byte, 12+len(tcp))
	copy(pseudo[0:4], src)
	copy(pseudo[4:8], dst)
	pseudo[8] = 0
	pseudo[9] = syscall.IPPROTO_TCP
	binary.BigEndian.PutUint16(pseudo[10:], uint16(len(tcp)))
	copy(pseudo[12:], tcp)
	binary.BigEndian.PutUint16(tcp[16:], csum(pseudo))

	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.IPPROTO_RAW)
	if err != nil {
		fmt.Printf("socket: %v\n", err)
		os.Exit(1)
	}
	defer syscall.Close(fd)

	sa := &syscall.SockaddrInet4{Port: *dport}
	copy(sa.Addr[:], dst)

	err = syscall.Sendto(fd, pkt, 0, sa)
	if err != nil {
		fmt.Printf("RESULT=FAIL errno=%v (%v)\n", err, err.(syscall.Errno))
		os.Exit(1)
	}

	fmt.Println("RESULT=OK")
}
