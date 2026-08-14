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

#ifndef THIRD_PARTY_GVISOR_PKG_SENTRY_PLATFORM_SYSTRAP_SYSMSG_SYSMSG_OFFSETS_ARM64_H_
#define THIRD_PARTY_GVISOR_PKG_SENTRY_PLATFORM_SYSTRAP_SYSMSG_SYSMSG_OFFSETS_ARM64_H_

// LINT.IfChange

// On ARM64, struct user_regs_struct == struct user_pt_regs:
//   __u64 regs[31]; __u64 sp; __u64 pc; __u64 pstate;
// These are byte offsets relative to the start of the ptregs field (i.e.
// offsetof(struct user_regs_struct, ...)). The FGT handler loads &ctx->ptregs
// into a base register and uses these (scaled by the access width) as
// load/store immediates.

#define offsetof_user_regs_regs0 0x0
#define offsetof_user_regs_regs1 0x8
#define offsetof_user_regs_regs2 0x10
#define offsetof_user_regs_regs3 0x18
#define offsetof_user_regs_regs4 0x20
#define offsetof_user_regs_regs5 0x28
#define offsetof_user_regs_regs6 0x30
#define offsetof_user_regs_regs7 0x38
#define offsetof_user_regs_regs8 0x40
#define offsetof_user_regs_regs9 0x48
#define offsetof_user_regs_regs10 0x50
#define offsetof_user_regs_regs11 0x58
#define offsetof_user_regs_regs12 0x60
#define offsetof_user_regs_regs13 0x68
#define offsetof_user_regs_regs14 0x70
#define offsetof_user_regs_regs15 0x78
#define offsetof_user_regs_regs16 0x80
#define offsetof_user_regs_regs17 0x88
#define offsetof_user_regs_regs18 0x90
#define offsetof_user_regs_regs19 0x98
#define offsetof_user_regs_regs20 0xa0
#define offsetof_user_regs_regs21 0xa8
#define offsetof_user_regs_regs22 0xb0
#define offsetof_user_regs_regs23 0xb8
#define offsetof_user_regs_regs24 0xc0
#define offsetof_user_regs_regs25 0xc8
#define offsetof_user_regs_regs26 0xd0
#define offsetof_user_regs_regs27 0xd8
#define offsetof_user_regs_regs28 0xe0
#define offsetof_user_regs_regs29 0xe8
#define offsetof_user_regs_regs30 0xf0
#define offsetof_user_regs_sp 0xf8
#define offsetof_user_regs_pc 0x100
#define offsetof_user_regs_pstate 0x108

// LINT.ThenChange(sysmsg.h, sighandler_arm64.c, fgt_handler_arm64.S)

#endif  // THIRD_PARTY_GVISOR_PKG_SENTRY_PLATFORM_SYSTRAP_SYSMSG_SYSMSG_OFFSETS_ARM64_H_
