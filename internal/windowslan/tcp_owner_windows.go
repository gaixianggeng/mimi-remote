//go:build windows

package windowslan

import (
	"encoding/binary"
	"net/netip"
	"unsafe"

	"golang.org/x/sys/windows"
)

var getTCPTable = windows.NewLazySystemDLL("iphlpapi.dll").NewProc("GetExtendedTcpTable")

func loopbackPeerPID(server, client netip.AddrPort) uint32 {
	// A dual-stack legacy listener may own the accepted IPv4 socket in tcp6.
	for _, family := range []int{windows.AF_INET, windows.AF_INET6} {
		buf := make([]byte, 16<<10)
		for attempt := 0; attempt < 4; attempt++ {
			size := uint32(len(buf))
			// TCP_TABLE_OWNER_PID_CONNECTIONS (4) returns MIB_TCP[6]ROW_OWNER_PID.
			status, _, _ := getTCPTable.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size)), 0, uintptr(family), 4, 0)
			if status == uintptr(windows.ERROR_INSUFFICIENT_BUFFER) && size > uint32(len(buf)) && size <= 8<<20 {
				buf = make([]byte, size)
				continue
			}
			if status == 0 {
				if pid := tablePeerPID(buf, family, server, client); pid != 0 {
					return pid
				}
			}
			break
		}
	}
	return 0
}

func tablePeerPID(table []byte, family int, server, client netip.AddrPort) uint32 {
	if len(table) < 4 {
		return 0
	}
	// Address and port fields have network byte order; DWORD state/PID do not.
	rowSize, addrBytes, localIP, localPort, remoteIP, remotePort, state, pidOffset := 24, 4, 4, 8, 12, 16, 0, 20
	if family == windows.AF_INET6 {
		rowSize, addrBytes, localIP, localPort, remoteIP, remotePort, state, pidOffset = 56, 16, 0, 20, 24, 44, 48, 52
	}
	want := binary.LittleEndian.Uint32(table[:4])
	rows := table[4:]
	if uint64(want) > uint64(len(rows)/rowSize) {
		return 0
	}
	for i := uint32(0); i < want; i++ {
		row := rows[:rowSize]
		rows = rows[rowSize:]
		if binary.LittleEndian.Uint32(row[state:]) != 5 || binary.BigEndian.Uint16(row[localPort:]) != server.Port() || binary.BigEndian.Uint16(row[remotePort:]) != client.Port() {
			continue
		}
		local, _ := netip.AddrFromSlice(row[localIP : localIP+addrBytes])
		remote, _ := netip.AddrFromSlice(row[remoteIP : remoteIP+addrBytes])
		if local.Unmap() == server.Addr().Unmap() && remote.Unmap() == client.Addr().Unmap() {
			return binary.LittleEndian.Uint32(row[pidOffset:])
		}
	}
	return 0
}
