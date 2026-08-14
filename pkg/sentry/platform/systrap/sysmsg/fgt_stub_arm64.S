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

// FEAT_FGT per-thread entry stub (template).
//
// This is a *template*. Each sysmsg thread gets its own copy of this stub at a
// distinct 4KB-aligned address, with __export_fgt_stub_sysmsg patched to point
// at that thread's `struct sysmsg`. VBAR_EL0_FGT (set via prctl(71, 1, addr))
// points at __export_fgt_stub. The sentry copies the bytes
// [__export_fgt_stub, __export_fgt_stub_sysmsg+8) from the sysmsg blob into a
// fresh RX page and patches the 8-byte literal with the thread's sysmsg
// address. See fgt_stub_arm64.go.
//
// On entry (after the guest's SVC is redirected here):
//   SP = guest SP; x0-x30 = guest registers; ELR_EL0/SPSR_EL0 = guest
//   PC/PSTATE. FEAT_FGT is auto-disabled by hardware.
//   x16/x17 (IP0/IP1) are caller-saved scratch; x18 is the platform register.
//
// The stub preserves guest x18 and guest SP, loads the thread's sysmsg into
// x18, records guest SP to sysmsg->app_stack, switches to the per-thread
// private syshandler stack (pushing guest x18 on top of it), and jumps to the
// shared handler __export_fgt_handler.

#include "sysmsg_offsets.h"

.globl __export_fgt_stub;
.type __export_fgt_stub, @function;
// 4KB-aligned so that the ADRP page-offset relocation survives being copied to
// a fresh page-aligned address (and so VBAR_EL0_FGT can point at it).
.balign 4096, 0x00;
__export_fgt_stub:
  mov  x16, x18                            // x16 = guest x18 (preserve)
  mov  x17, sp                             // x17 = guest SP (preserve)
  adrp x18, __export_fgt_stub_sysmsg       // page of the literal
  ldr  x18, [x18, :lo12:__export_fgt_stub_sysmsg]  // x18 = sysmsg
  str  x17, [x18, #offsetof_sysmsg_app_stack] // sysmsg->app_stack = guest SP
  // Diagnostic: count stub entries (high 32 bits of sysmsg->debug) so the
  // sentry can distinguish "SVC never redirected" from "stub entered but
  // crashed before reaching the handler". See subprocess.go switchToApp.
  ldr  w17, [x18, #(offsetof_sysmsg_debug + 4)]
  add  w17, w17, #1
  str  w17, [x18, #(offsetof_sysmsg_debug + 4)]
  ldr  x17, [x18, #offsetof_sysmsg_syshandler_stack] // x17 = private stack top
  str  x16, [x17, #-8]!                    // push guest x18; x17 = top - 8
  mov  sp, x17                             // SP = private stack
  ldr  x16, [x18, #offsetof_sysmsg_syshandler] // x16 = __export_fgt_handler
  br   x16

.balign 8;
__export_fgt_stub_sysmsg:
  .quad 0x0                                // patched per-thread with sysmsg address

.size __export_fgt_stub, . - __export_fgt_stub
