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

// FEAT_FGT fast-path syscall handler.
//
// Entered from the per-thread stub (fgt_stub_arm64.S). On entry:
//   x18 = this thread's sysmsg
//   sp  = per-thread private syshandler stack, with guest x18 at [sp]
//   x0-x15, x19-x30 = guest registers (intact)
//   x16 = __export_fgt_handler address (clobbered by the stub tail)
//   x17 = private stack top - 8 (clobbered)
//   ELR_EL0 = guest return PC, SPSR_EL0 = guest PSTATE (custom FEAT_FGT
//     registers; see the #defines below)
//   FEAT_FGT is auto-disabled on entry, so nested SVCs (futex in
//   switch_context) take the normal EL0->EL1 path.
//
// This handler saves the guest's GPR + FPSIMD state into ctx->ptregs/fpstate,
// calls __syshandler (which does switch_context), then restores the (possibly
// different) returned context and returns to the guest via ERET (which
// re-enables FEAT_FGT). There is no signal frame and no rt_sigreturn.
//
// x16/x17 (IP0/IP1) are caller-saved scratch; the Linux AArch64 syscall ABI
// allows the kernel to clobber them, so the guest does not rely on their values
// across an SVC. We therefore use them as scratch and do not restore them.

#include "sysmsg_offsets.h"
#include "sysmsg_offsets_arm64.h"

// ELR_EL0 / SPSR_EL0 are FEAT_FGT-defined system registers holding the guest's
// exception-return state. They are not architectural ARM64 registers (standard
// ARM64 only has ELR_EL1/SPSR_EL1); their encodings come from the kernel
// extension. They share the op1=3 sys_reg bank with VBAR_EL0_FGT
// (sys_reg(3, 3, 11, 1, 0)); op2 distinguishes the three registers.
//   ELR_EL0  = sys_reg(3, 3, 11, 1, 1)
//   SPSR_EL0 = sys_reg(3, 3, 11, 1, 2)
#define ELR_EL0 s3_3_c11_c1_1
#define SPSR_EL0 s3_3_c11_c1_2

.globl __export_fgt_handler;
.type __export_fgt_handler, @function;
// The kernel requires the handler address to be 4KB-aligned.
.balign 4096, 0x00;
__export_fgt_handler:
  // Postpone interrupts: sysmsg->state = THREAD_STATE_PREP.
  mov  w16, #kTHREAD_STATE_PREP
  str  w16, [x18, #offsetof_sysmsg_state]

  // ctx = sysmsg->context.
  ldr  x17, [x18, #offsetof_sysmsg_context]

  // Save GP registers to ctx->ptregs. x16 = &ctx->ptregs.
  add  x16, x17, #offsetof_thread_context_ptregs
  stp  x0,  x1,  [x16, #offsetof_user_regs_regs0]
  stp  x2,  x3,  [x16, #offsetof_user_regs_regs2]
  stp  x4,  x5,  [x16, #offsetof_user_regs_regs4]
  stp  x6,  x7,  [x16, #offsetof_user_regs_regs6]
  stp  x8,  x9,  [x16, #offsetof_user_regs_regs8]
  stp  x10, x11, [x16, #offsetof_user_regs_regs10]
  stp  x12, x13, [x16, #offsetof_user_regs_regs12]
  stp  x14, x15, [x16, #offsetof_user_regs_regs14]
  // x16/x17 are scratch (see file header); store 0 so ptregs never holds stale
  // data. regs[18] holds the guest x18 pushed onto the private stack by the stub.
  str  xzr, [x16, #offsetof_user_regs_regs16]
  str  xzr, [x16, #offsetof_user_regs_regs17]
  ldr  x0,  [sp]                                // x0 = guest x18 (x0 already saved)
  str  x0,  [x16, #offsetof_user_regs_regs18]
  stp  x19, x20, [x16, #offsetof_user_regs_regs19]
  stp  x21, x22, [x16, #offsetof_user_regs_regs21]
  stp  x23, x24, [x16, #offsetof_user_regs_regs23]
  stp  x25, x26, [x16, #offsetof_user_regs_regs25]
  stp  x27, x28, [x16, #offsetof_user_regs_regs27]
  stp  x29, x30, [x16, #offsetof_user_regs_regs29]

  // Save SP / PC / PSTATE.
  ldr  x0, [x18, #offsetof_sysmsg_app_stack]    // guest SP
  str  x0, [x16, #offsetof_user_regs_sp]
  mrs  x0, ELR_EL0
  str  x0, [x16, #offsetof_user_regs_pc]
  mrs  x0, SPSR_EL0
  str  x0, [x16, #offsetof_user_regs_pstate]

  // Save FPSIMD: fpsr @ 0, fpcr @ 4, vregs[0..31] @ 8 (16 bytes each).
  mrs  x0, fpsr
  str  w0, [x17, #offsetof_thread_context_fpstate + 0]
  mrs  x0, fpcr
  str  w0, [x17, #offsetof_thread_context_fpstate + 4]
  add  x16, x17, #(offsetof_thread_context_fpstate + 8)
  stp  q0,  q1,  [x16, #0]
  stp  q2,  q3,  [x16, #32]
  stp  q4,  q5,  [x16, #64]
  stp  q6,  q7,  [x16, #96]
  stp  q8,  q9,  [x16, #128]
  stp  q10, q11, [x16, #160]
  stp  q12, q13, [x16, #192]
  stp  q14, q15, [x16, #224]
  stp  q16, q17, [x16, #256]
  stp  q18, q19, [x16, #288]
  stp  q20, q21, [x16, #320]
  stp  q22, q23, [x16, #352]
  stp  q24, q25, [x16, #384]
  stp  q26, q27, [x16, #416]
  stp  q28, q29, [x16, #448]
  stp  q30, q31, [x16, #480]

  // Call __syshandler(sysmsg). It runs switch_context and may return with a
  // different context in sysmsg->context. Keep sysmsg in x19 (callee-saved).
  mov  x19, x18
  mov  x0, x18
  bl   __syshandler

  // Reload (possibly new) context.
  mov  x18, x19
  ldr  x17, [x18, #offsetof_sysmsg_context]

  // Restore FPSIMD only if the sentry changed it for this context.
  ldr  x16, [x17, #offsetof_thread_context_fpstate_changed]
  cbz  x16, .Lfgt_fp_restored
  ldr  w16, [x17, #offsetof_thread_context_fpstate + 0]
  msr  fpsr, x16
  ldr  w16, [x17, #offsetof_thread_context_fpstate + 4]
  msr  fpcr, x16
  add  x16, x17, #(offsetof_thread_context_fpstate + 8)
  ldp  q0,  q1,  [x16, #0]
  ldp  q2,  q3,  [x16, #32]
  ldp  q4,  q5,  [x16, #64]
  ldp  q6,  q7,  [x16, #96]
  ldp  q8,  q9,  [x16, #128]
  ldp  q10, q11, [x16, #160]
  ldp  q12, q13, [x16, #192]
  ldp  q14, q15, [x16, #224]
  ldp  q16, q17, [x16, #256]
  ldp  q18, q19, [x16, #288]
  ldp  q20, q21, [x16, #320]
  ldp  q22, q23, [x16, #352]
  ldp  q24, q25, [x16, #384]
  ldp  q26, q27, [x16, #416]
  ldp  q28, q29, [x16, #448]
  ldp  q30, q31, [x16, #480]
.Lfgt_fp_restored:

  // Restore GP registers. x16/x17 are scratch (see file header), not restored.
  add  x16, x17, #offsetof_thread_context_ptregs
  ldp  x0,  x1,  [x16, #offsetof_user_regs_regs0]
  ldp  x2,  x3,  [x16, #offsetof_user_regs_regs2]
  ldp  x4,  x5,  [x16, #offsetof_user_regs_regs4]
  ldp  x6,  x7,  [x16, #offsetof_user_regs_regs6]
  ldp  x8,  x9,  [x16, #offsetof_user_regs_regs8]
  ldp  x10, x11, [x16, #offsetof_user_regs_regs10]
  ldp  x12, x13, [x16, #offsetof_user_regs_regs12]
  ldp  x14, x15, [x16, #offsetof_user_regs_regs14]
  ldr  x18, [x16, #offsetof_user_regs_regs18]
  ldp  x19, x20, [x16, #offsetof_user_regs_regs19]
  ldp  x21, x22, [x16, #offsetof_user_regs_regs21]
  ldp  x23, x24, [x16, #offsetof_user_regs_regs23]
  ldp  x25, x26, [x16, #offsetof_user_regs_regs25]
  ldp  x27, x28, [x16, #offsetof_user_regs_regs27]
  ldp  x29, x30, [x16, #offsetof_user_regs_regs29]

  // Set ELR_EL0 / SPSR_EL0 / guest SP and return (ERET re-enables FEAT_FGT).
  ldr  x17, [x16, #offsetof_user_regs_pc]
  msr  ELR_EL0, x17
  ldr  x17, [x16, #offsetof_user_regs_pstate]
  msr  SPSR_EL0, x17
  ldr  x17, [x16, #offsetof_user_regs_sp]
  mov  sp, x17
  eret

.size __export_fgt_handler, . - __export_fgt_handler
