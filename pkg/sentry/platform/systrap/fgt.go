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

package systrap

import (
	"runtime"

	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/hostarch"
	"gvisor.dev/gvisor/pkg/log"
	"gvisor.dev/gvisor/pkg/sentry/arch"
	"gvisor.dev/gvisor/pkg/sentry/platform/systrap/sysmsg"
)

// fgtEnabled controls whether FEAT_FGT is enabled for new stub processes.
// Defaults to false; SetFGTEnabled(true) activates it on ARM64.
var fgtEnabled bool

// fgtPstateTindex is PSTATE bit 14 (TINDEX_EL0_FGT). When set in the guest
// PSTATE, the guest's SVC instructions are redirected to VBAR_EL0_FGT (the FGT
// fast path) instead of taking the normal EL0->EL1 path. The sentry must set
// this bit before dispatching the guest so the redirect is armed.
const fgtPstateTindex = uint64(1) << 14

// canEnableFGT returns true only on ARM64, where the FEAT_FGT hardware
// feature is available.
func canEnableFGT() bool {
	return runtime.GOARCH == "arm64"
}

// SetFGTEnabled sets the FEAT_FGT enable state. On non-ARM64 architectures
// the call is silently ignored.
func SetFGTEnabled(enable bool) {
	if enable && !canEnableFGT() {
		return
	}
	fgtEnabled = enable
	if enable {
		log.Infof("FEAT_FGT: enabled, will configure VBAR_EL0_FGT on stub creation")
	} else {
		log.Infof("FEAT_FGT: disabled")
	}
}

// FGTEnabled returns whether FEAT_FGT is enabled.
func FGTEnabled() bool {
	return fgtEnabled
}

// fgtHandlerAddr returns the address of __export_fgt_handler (the shared
// fast-path handler) in the stub address space.
func fgtHandlerAddr() uint64 {
	offset := uint64(sysmsg.Sighandler_blob_offset____export_fgt_handler)
	return uint64(stubSysmsgStart) + offset
}

// alignExecMapEndForFGT ensures the executable mapping covers the FGT
// handler page.
func alignExecMapEndForFGT(stubSysmsgStart, stubExecMapEnd uintptr) uintptr {
	if !fgtEnabled {
		return stubExecMapEnd
	}
	handlerOffset := uint64(sysmsg.Sighandler_blob_offset____export_fgt_handler)
	handlerEnd, _ := hostarch.PageRoundUp(stubSysmsgStart + uintptr(handlerOffset) + hostarch.PageSize)
	if handlerEnd > stubExecMapEnd {
		return handlerEnd
	}
	return stubExecMapEnd
}

// injectFGTEnable injects a prctl(71, 1, addr) call into the given thread via
// ptrace, enabling FEAT_FGT with VBAR_EL0_FGT = addr. addr must be 4KB-aligned
// and is the thread's per-thread entry stub. Called when creating sysmsg
// threads.
func injectFGTEnable(t *thread, addr uint64) error {
	if !fgtEnabled {
		return nil
	}
	log.Infof("FEAT_FGT: injectFGTEnable prctl(71, 1, 0x%x) tid=%d", addr, t.tid)
	_, err := t.syscallIgnoreInterrupt(&t.initRegs, unix.SYS_PRCTL,
		arch.SyscallArgument{Value: 71},
		arch.SyscallArgument{Value: 1},
		arch.SyscallArgument{Value: uintptr(addr)},
		arch.SyscallArgument{Value: 0},
		arch.SyscallArgument{Value: 0},
		arch.SyscallArgument{Value: 0},
	)
	if err != nil {
		log.Warningf("FEAT_FGT: injectFGTEnable failed: tid=%d err=%v", t.tid, err)
	} else {
		log.Infof("FEAT_FGT: injectFGTEnable OK tid=%d VBAR_EL0_FGT=0x%x", t.tid, addr)
	}
	return err
}
