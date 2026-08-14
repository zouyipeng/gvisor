// Copyright 2020 The gVisor Authors.
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

#define _GNU_SOURCE
#include <asm/sigcontext.h>
#include <asm/unistd.h>
#include <errno.h>
#include <linux/audit.h>
#include <linux/futex.h>
#include <linux/unistd.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/ucontext.h>

#include "atomic.h"
#include "sysmsg.h"
#include "sysmsg_offsets.h"
#include "sysmsg_offsets_arm64.h"

// TODO(b/271631387): These globals are shared between AMD64 and ARM64; move to
// sysmsg_lib.c.
struct arch_state __export_arch_state;
uint64_t __export_stub_start;
// Note: This flag doesn't do anything for ARM. See AMD64 equivalent.
uint64_t __export_disable_syscall_patching;

long __syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
  // ARM64 syscall interface passes the syscall number in x8 and the 6 arguments
  // in x0-x5. The return value is in x0.
  //
  // See: https://man7.org/linux/man-pages/man2/syscall.2.html
  register long x8 __asm__("x8") = n;
  register long x0 __asm__("x0") = a1;
  register long x1 __asm__("x1") = a2;
  register long x2 __asm__("x2") = a3;
  register long x3 __asm__("x3") = a4;
  register long x4 __asm__("x4") = a5;
  register long x5 __asm__("x5") = a6;
  __asm__ __volatile__("svc #0"
                       : "=r"(x0)
                       : "r"(x8), "0"(x0), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
                       : "memory", "cc");
  return x0;
}

static __inline void set_tls(uint64_t tls) {
  __asm__("msr tpidr_el0,%0" : : "r"(tls));
}

static __inline uint64_t get_tls() {
  uint64_t tls;
  __asm__("mrs %0,tpidr_el0" : "=r"(tls));
  return tls;
}

static __inline uint64_t get_vbar_el0_fgt() {
  uint64_t vbar;
  // VBAR_EL0_FGT = sys_reg(3, 3, 11, 1, 0).
  __asm__("mrs %0,s3_3_c11_c1_0" : "=r"(vbar));
  return vbar;
}

long sys_futex(uint32_t *addr, int op, int val, struct __kernel_timespec *tv,
               uint32_t *addr2, int val3) {
  return __syscall(__NR_futex, (long)addr, (long)op, (long)val, (long)tv,
                   (long)addr2, (long)val3);
}

static void gregs_to_ptregs(ucontext_t *ucontext,
                            struct user_regs_struct *ptregs) {
  // Set all registers.
  for (int i = 0; i < 31; i++ ) {
    ptregs->regs[i] = ucontext->uc_mcontext.regs[i];
  }
  ptregs->sp = ucontext->uc_mcontext.sp;
  ptregs->pc = ucontext->uc_mcontext.pc;
  ptregs->pstate = ucontext->uc_mcontext.pstate;
}

static void ptregs_to_gregs(ucontext_t *ucontext,
                            struct user_regs_struct *ptregs) {
  for (int i = 0; i < 31; i++ ) {
    ucontext->uc_mcontext.regs[i] = ptregs->regs[i];
  }
  ucontext->uc_mcontext.sp = ptregs->sp;
  ucontext->uc_mcontext.pc = ptregs->pc;
  ucontext->uc_mcontext.pstate = ptregs->pstate;
}

void __export_start(struct sysmsg *sysmsg, void *_ucontext) {
  panic(0x11111111, 0);
}

void __export_sighandler(int signo, siginfo_t *siginfo, void *_ucontext) {
  ucontext_t *ucontext = _ucontext;
  void *sp = sysmsg_sp();
  struct sysmsg *sysmsg = sysmsg_addr(sp);

  if (sysmsg != sysmsg->self) panic(STUB_ERROR_BAD_SYSMSG, 0);
  int32_t thread_state = atomic_load(&sysmsg->state);

  uint32_t ctx_state = CONTEXT_STATE_INVALID;
  struct thread_context *ctx = NULL, *old_ctx = NULL;
  if (thread_state == THREAD_STATE_INITIALIZING) {
    // Find a new context and exit to restore it.
    init_new_thread();
    goto init;
  }

  // If the current thread is in the syshandler fast path, an interrupt has to
  // be postponed, because sysmsg can't be changed. The fast path re-checks
  // ctx->interrupt before resuming. See __syshandler below.
  if (signo == SIGCHLD && thread_state != THREAD_STATE_NONE) {
    return;
  }

  ctx = sysmsg->context;
  old_ctx = sysmsg->context;

  ctx->signo = signo;

  gregs_to_ptregs(ucontext, &ctx->ptregs);

  // Signal frames for ARM64 include 8 byte magic header before the floating
  // point context.
  //
  // See: arch/arm64/include/uapi/asm/sigcontext.h
  const uint64_t kFpsimdContextSize =
      sizeof(struct fpsimd_context) - sizeof(struct _aarch64_ctx);
  struct fpsimd_context *fpctx =
      (struct fpsimd_context *)&ucontext->uc_mcontext.__reserved;
  uint8_t *fpStatePointer = (uint8_t *)&fpctx->fpsr;

  // Verify the header.
  if (fpctx->head.magic != FPSIMD_MAGIC ||
      __export_arch_state.fp_len < kFpsimdContextSize ||
      fpctx->head.size != sizeof(struct fpsimd_context)) {
    panic(STUB_ERROR_FPSTATE_BAD_HEADER,
          ((uint32_t *)&ucontext->uc_mcontext.__reserved)[0]);
  }

  memcpy(ctx->fpstate, fpStatePointer, kFpsimdContextSize);
  ctx->tls = get_tls();
  ctx->siginfo = *siginfo;
  ctx->err = 0;
  switch (signo) {
    case SIGSYS: {
      ctx_state = CONTEXT_STATE_SYSCALL;
      if (siginfo->si_arch != AUDIT_ARCH_AARCH64) {
        // gVisor doesn't support x32 system calls, so let's change the syscall
        // number so that it returns ENOSYS. The value added here is just a
        // random large number which is large enough to not match any existing
        // syscall number in linux.
        ctx->ptregs.regs[8] += 0x86000000;
      }
      break;
    }
    case SIGSEGV: {
      unsigned char *base = &ucontext->uc_mcontext.__reserved[0];
      size_t offset = 0;
      while (1) {
        struct _aarch64_ctx *head = (struct _aarch64_ctx *)(base + offset);
        if (head->magic == ESR_MAGIC) {
          ctx->err = ((struct esr_context *)head)->esr;
          break;
        }
        if (head->magic == 0 || head->magic == EXTRA_MAGIC) break;
        offset += head->size;
      }
    }
    // fallthrough
    case SIGBUS:
    case SIGCHLD:
    case SIGFPE:
    case SIGTRAP:
    case SIGILL:
      ctx_state = CONTEXT_STATE_FAULT;
      break;
    default:
      return;
  }

init:
  for (;;) {
    ctx = switch_context(sysmsg, ctx, ctx_state);

    if (atomic_load(&ctx->interrupt) != 0) {
      // This context got interrupted while it was waiting in the queue.
      // Setup all the necessary bits to let the sentry know this context has
      // switched back because of it.
      atomic_store(&ctx->interrupt, 0);
      ctx_state = CONTEXT_STATE_FAULT;
      ctx->signo = SIGCHLD;
      ctx->siginfo.si_signo = SIGCHLD;
    } else {
      break;
    }
  }

  if (old_ctx != ctx || ctx->last_thread_id != sysmsg->thread_id) {
    ctx->fpstate_changed = 1;
  }
  restore_state(sysmsg, ctx, _ucontext);
}

// On ARM restore_state sets up a correct restore from the sighandler by
// populating _ucontext.
void restore_state(struct sysmsg *sysmsg, struct thread_context *ctx,
                   void *_ucontext) {
  ucontext_t *ucontext = _ucontext;
  struct fpsimd_context *fpctx =
      (struct fpsimd_context *)&ucontext->uc_mcontext.__reserved;
  uint8_t *fpStatePointer = (uint8_t *)&fpctx->fpsr;

  if (atomic_load(&ctx->fpstate_changed)) {
    memcpy(fpStatePointer, ctx->fpstate, __export_arch_state.fp_len);
    fpctx[1].head.size = 0;
    fpctx[1].head.magic = 0;
  }
  ptregs_to_gregs(ucontext, &ctx->ptregs);
  set_tls(ctx->tls);
  // Diagnostic: sample VBAR_EL0_FGT and the guest PSTATE just before
  // dispatching the guest so the sentry can verify the kernel configured FGT
  // (see subprocess.go switchToApp). PSTATE bit 14 (TINDEX_EL0_FGT) arms the
  // SVC->VBAR_EL0_FGT redirect; it is only enabled when the sentry has set it
  // in the guest context's PSTATE.
  ctx->fgt_vbar = get_vbar_el0_fgt();
  ctx->fgt_pstate = ctx->ptregs.pstate;
  atomic_store(&sysmsg->state, THREAD_STATE_NONE);
}

// switch_context_arm64 is the fast-path wrapper of switch_context() with
// interrupt coordination (mirrors switch_context_amd64).
static struct thread_context *switch_context_arm64(
    struct sysmsg *sysmsg, struct thread_context *ctx,
    enum context_state new_context_state) {
  struct thread_context *old_ctx = sysmsg->context;

  for (;;) {
    ctx = switch_context(sysmsg, ctx, new_context_state);

    // After setting THREAD_STATE_NONE, the syshandler can be interrupted by
    // SIGCHLD. In this case the current context contains the actual state and
    // the sighandler can take control of it.
    atomic_store(&sysmsg->state, THREAD_STATE_NONE);
    if (atomic_load(&ctx->interrupt) != 0) {
      atomic_store(&sysmsg->state, THREAD_STATE_PREP);
      // This context got interrupted while it was waiting in the queue. Set up
      // the necessary bits to let the sentry know this context has switched
      // back because of it.
      atomic_store(&ctx->interrupt, 0);
      new_context_state = CONTEXT_STATE_FAULT;
      ctx->signo = SIGCHLD;
      ctx->siginfo.si_signo = SIGCHLD;
    } else {
      break;
    }
  }
  if (old_ctx != ctx || ctx->last_thread_id != sysmsg->thread_id) {
    ctx->fpstate_changed = 1;
  }
  return ctx;
}

// __syshandler is the C part of the FEAT_FGT fast path. It is called from
// fgt_handler_arm64.S with the current thread's sysmsg already loaded into the
// (already-saved) registers, after the guest state has been saved to
// ctx->ptregs/fpstate. It populates the syscall siginfo and switches to the
// next context; on return the assembly restores it and ERETs to the guest.
void __syshandler(struct sysmsg *sysmsg) {
  // Diagnostic: count FGT fast-path handler entries, observable from the sentry
  // via sysmsg->debug (see subprocess.go switchToApp).
  atomic_add(&sysmsg->debug, 1);

  // THREAD_STATE_PREP is set by the assembly entry to postpone interrupts.
  int state = atomic_load(&sysmsg->state);
  if (state != THREAD_STATE_PREP) panic(STUB_ERROR_BAD_THREAD_STATE, 0);

  struct thread_context *ctx = sysmsg->context;

  ctx->signo = SIGSYS;
  ctx->siginfo.si_addr = 0;
  ctx->siginfo.si_syscall = ctx->ptregs.regs[8];
  // Unlike amd64 (where %rax holds the syscall number, not an argument), on
  // arm64 x0/regs[0] is the *first syscall argument* as well as the return
  // value register. Do NOT overwrite it here: the sentry reads arg0 from
  // regs[0] via SyscallSaveOrig() before dispatching the syscall, and sets the
  // return value itself. The amd64 equivalent (rax = -ENOSYS) is only a
  // placeholder for the return register, which on arm64 would clobber arg0.
  ctx->tls = get_tls();

  atomic_store(&ctx->fpstate_changed, 0);
  ctx = switch_context_arm64(sysmsg, ctx, CONTEXT_STATE_SYSCALL_TRAP);

  set_tls(ctx->tls);
}

void verify_offsets_arm64() {
#define PTREGS_OFFSET offsetof(struct thread_context, ptregs)
  BUILD_BUG_ON(offsetof_thread_context_ptregs != PTREGS_OFFSET);
  BUILD_BUG_ON(offsetof_user_regs_regs0 !=
               offsetof(struct user_regs_struct, regs[0]));
  BUILD_BUG_ON(offsetof_user_regs_regs1 !=
               offsetof(struct user_regs_struct, regs[1]));
  BUILD_BUG_ON(offsetof_user_regs_regs2 !=
               offsetof(struct user_regs_struct, regs[2]));
  BUILD_BUG_ON(offsetof_user_regs_regs3 !=
               offsetof(struct user_regs_struct, regs[3]));
  BUILD_BUG_ON(offsetof_user_regs_regs4 !=
               offsetof(struct user_regs_struct, regs[4]));
  BUILD_BUG_ON(offsetof_user_regs_regs5 !=
               offsetof(struct user_regs_struct, regs[5]));
  BUILD_BUG_ON(offsetof_user_regs_regs6 !=
               offsetof(struct user_regs_struct, regs[6]));
  BUILD_BUG_ON(offsetof_user_regs_regs7 !=
               offsetof(struct user_regs_struct, regs[7]));
  BUILD_BUG_ON(offsetof_user_regs_regs8 !=
               offsetof(struct user_regs_struct, regs[8]));
  BUILD_BUG_ON(offsetof_user_regs_regs9 !=
               offsetof(struct user_regs_struct, regs[9]));
  BUILD_BUG_ON(offsetof_user_regs_regs10 !=
               offsetof(struct user_regs_struct, regs[10]));
  BUILD_BUG_ON(offsetof_user_regs_regs11 !=
               offsetof(struct user_regs_struct, regs[11]));
  BUILD_BUG_ON(offsetof_user_regs_regs12 !=
               offsetof(struct user_regs_struct, regs[12]));
  BUILD_BUG_ON(offsetof_user_regs_regs13 !=
               offsetof(struct user_regs_struct, regs[13]));
  BUILD_BUG_ON(offsetof_user_regs_regs14 !=
               offsetof(struct user_regs_struct, regs[14]));
  BUILD_BUG_ON(offsetof_user_regs_regs15 !=
               offsetof(struct user_regs_struct, regs[15]));
  BUILD_BUG_ON(offsetof_user_regs_regs16 !=
               offsetof(struct user_regs_struct, regs[16]));
  BUILD_BUG_ON(offsetof_user_regs_regs17 !=
               offsetof(struct user_regs_struct, regs[17]));
  BUILD_BUG_ON(offsetof_user_regs_regs18 !=
               offsetof(struct user_regs_struct, regs[18]));
  BUILD_BUG_ON(offsetof_user_regs_regs19 !=
               offsetof(struct user_regs_struct, regs[19]));
  BUILD_BUG_ON(offsetof_user_regs_regs20 !=
               offsetof(struct user_regs_struct, regs[20]));
  BUILD_BUG_ON(offsetof_user_regs_regs21 !=
               offsetof(struct user_regs_struct, regs[21]));
  BUILD_BUG_ON(offsetof_user_regs_regs22 !=
               offsetof(struct user_regs_struct, regs[22]));
  BUILD_BUG_ON(offsetof_user_regs_regs23 !=
               offsetof(struct user_regs_struct, regs[23]));
  BUILD_BUG_ON(offsetof_user_regs_regs24 !=
               offsetof(struct user_regs_struct, regs[24]));
  BUILD_BUG_ON(offsetof_user_regs_regs25 !=
               offsetof(struct user_regs_struct, regs[25]));
  BUILD_BUG_ON(offsetof_user_regs_regs26 !=
               offsetof(struct user_regs_struct, regs[26]));
  BUILD_BUG_ON(offsetof_user_regs_regs27 !=
               offsetof(struct user_regs_struct, regs[27]));
  BUILD_BUG_ON(offsetof_user_regs_regs28 !=
               offsetof(struct user_regs_struct, regs[28]));
  BUILD_BUG_ON(offsetof_user_regs_regs29 !=
               offsetof(struct user_regs_struct, regs[29]));
  BUILD_BUG_ON(offsetof_user_regs_regs30 !=
               offsetof(struct user_regs_struct, regs[30]));
  BUILD_BUG_ON(offsetof_user_regs_sp !=
               offsetof(struct user_regs_struct, sp));
  BUILD_BUG_ON(offsetof_user_regs_pc !=
               offsetof(struct user_regs_struct, pc));
  BUILD_BUG_ON(offsetof_user_regs_pstate !=
               offsetof(struct user_regs_struct, pstate));
#undef PTREGS_OFFSET
}
