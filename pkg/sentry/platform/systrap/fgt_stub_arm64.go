// Copyright 2024 The gVisor Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//go:build arm64
// +build arm64

package systrap

import (
	"encoding/binary"
	"unsafe"

	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/hostarch"
	"gvisor.dev/gvisor/pkg/hostsyscall"
	"gvisor.dev/gvisor/pkg/sentry/arch"
	"gvisor.dev/gvisor/pkg/sentry/pgalloc"
	"gvisor.dev/gvisor/pkg/sentry/platform/systrap/sysmsg"
	"gvisor.dev/gvisor/pkg/sentry/usage"
)

// allocateFGTStub maps a fresh 4KB RX page into the *stub process* address
// space and bakes the calling thread's sysmsg pointer into the per-thread FGT
// entry stub template. It returns the stub-process address, which is used as
// VBAR_EL0_FGT.
//
// The page must be mapped in the stub process, not the sentry: the sentry does
// NOT share its address space with the sysmsg threads. The stub process is
// forked from the sentry without CLONE_VM, and the sysmsg threads share the
// stub process's VM via CLONE_VM (see forkStub and thread.clone). Mapping the
// stub only in the sentry leaves VBAR_EL0_FGT pointing at an address that is
// unmapped where the guest actually runs, causing a SEGV_MAPERR on the first
// redirected SVC.
func allocateFGTStub(t *sysmsgThread) (uint64, error) {
	// Allocate a page from the memory file so it can be mapped into both the
	// sentry (to bake the template) and the stub process (to execute it).
	opts := pgalloc.AllocOpts{Kind: usage.System, Dir: pgalloc.TopDown}
	fr, err := t.subproc.memoryFile.Allocate(uint64(hostarch.PageSize), opts)
	if err != nil {
		return 0, err
	}

	// Map the page read-write into the sentry so we can bake the template.
	sentryAddr, errno := hostsyscall.RawSyscall6(
		unix.SYS_MMAP,
		0,
		uintptr(hostarch.PageSize),
		uintptr(unix.PROT_READ|unix.PROT_WRITE),
		uintptr(unix.MAP_SHARED|unix.MAP_FILE),
		uintptr(t.subproc.memoryFile.FD()),
		uintptr(fr.Start))
	if errno != 0 {
		t.subproc.memoryFile.DecRef(fr)
		return 0, errno
	}
	bakeFGTStub(sentryAddr, t.msg.Self)

	// Map the same page read-execute into the stub process. The returned
	// address is the stub-process address that VBAR_EL0_FGT must point at.
	stubAddr, err := t.subproc.syscall(
		unix.SYS_MMAP,
		arch.SyscallArgument{Value: 0}, // let the kernel pick an address
		arch.SyscallArgument{Value: uintptr(hostarch.PageSize)},
		arch.SyscallArgument{Value: uintptr(unix.PROT_READ | unix.PROT_EXEC)},
		arch.SyscallArgument{Value: uintptr(unix.MAP_SHARED | unix.MAP_FILE)},
		arch.SyscallArgument{Value: uintptr(t.subproc.memoryFile.FD())},
		arch.SyscallArgument{Value: uintptr(fr.Start)})
	if err != nil {
		hostsyscall.RawSyscallErrno(unix.SYS_MUNMAP, sentryAddr, uintptr(hostarch.PageSize), 0)
		t.subproc.memoryFile.DecRef(fr)
		return 0, err
	}
	return uint64(stubAddr), nil
}

// bakeFGTStub copies the per-thread FGT stub template out of the sysmsg blob
// into the page at stubAddr and patches the __export_fgt_stub_sysmsg literal
// with sysmsgPtr. The template is position-independent: its ADRP resolves the
// literal relative to the stub's own (page-aligned) address, so the copy is
// valid at any page-aligned address.
func bakeFGTStub(stubAddr uintptr, sysmsgPtr uint64) {
	stubOff := int(sysmsg.Sighandler_blob_offset____export_fgt_stub)
	litOff := int(sysmsg.Sighandler_blob_offset____export_fgt_stub_sysmsg)
	n := litOff + 8 - stubOff

	dst := unsafe.Slice((*byte)(unsafe.Pointer(stubAddr)), n)
	copy(dst, sysmsg.SighandlerBlob[stubOff:stubOff+n])

	litAddr := stubAddr + uintptr(litOff-stubOff)
	binary.LittleEndian.PutUint64(
		unsafe.Slice((*byte)(unsafe.Pointer(litAddr)), 8),
		sysmsgPtr,
	)
}
