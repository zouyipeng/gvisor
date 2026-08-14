# AMD64 systrap syshandler（syscall patching）详细流程

> 目的：把 AMD64 上 systrap 平台「syshandler」这个 fast path 的完整机制讲清楚，
> 作为理解/对照 ARM64 FEAT_FGT 优化的基础。所有代码引用均为 gvisor 仓库内路径。

---

## 0. 一句话结论

syshandler 是**两套正交机制的叠加**：

| 职责 | 机制 | 粒度 |
|---|---|---|
| 把 `syscall` 指令替换成"跳进 handler" | **usertrap 二进制 patch**：`mov $N,%eax; syscall`(7B) → `jmp *trap`(7B) | per-**syscall-site**（同一段代码所有线程共享） |
| 让 handler 找到"当前线程"的状态 | **`%gs` 段基址**指向本线程的 `struct sysmsg` | per-**thread** |

两者各自独立，缺一不可。**线程身份 100% 来自 `%gs`，与 trampoline 无关**——trampoline 是
per-syscall-site 的，里面嵌的是 sysno 和返回地址两个"站点常量"，不是线程身份。

fast path 的收益来源：syscall 从「陷入内核 → seccomp → SIGSYS 信号 → 构造/恢复信号帧 →
rt_sigreturn」变成「一条用户态 `jmp` 进出 handler」，全程**无信号帧、无 sigreturn、无 seccomp**。

---

## 1. 关键数据结构

### 1.1 `struct sysmsg`（`pkg/sentry/platform/systrap/sysmsg/sysmsg.go:117-162`，C 侧 `sysmsg.h:52-70`）

`%gs` 基址就指向这个 per-thread 结构。关键字段及其相对偏移（对应 trampoline 里的硬编码偏移）：

| 偏移 | 字段 | 用途 |
|---|---|---|
| `0x00` (0) | `Self` | sysmsg 自身地址（`__syshandler` 用它取回指针） |
| `0x08` (8) | `RetAddr` | 返回地址（guest RIP，syscall 下一条） |
| `0x10` (16) | `Syshandler` | `__export_syshandler` 入口地址 |
| `0x18` (24) | `SyshandlerStack` | per-thread 私有栈栈顶 |
| `0x20` (32) | `AppStack` | 保存的 guest SP |
| `0x28` (40) | `interrupt` | 推迟的中断标记 |
| `0x2c` (44) | `State` | `THREAD_STATE_*`（PREP/NONE/…） |
| `0x30` (48) | `Context` | 当前 `thread_context` 指针 |

### 1.2 `struct thread_context`（`sysmsg.h:84-103`，Go 侧 `sysmsg.go:232-284`）

sysmsg 线程当前正在运行的 guest context，字段：`fpstate`（FPU 状态）、`fpstate_changed`、
`ptregs`（完整寄存器集，x86 下含 `orig_rax/rax/rip/rsp/eflags/fs_base/gs_base/段寄存器`）、
`siginfo`、`signo`、`state`（`CONTEXT_STATE_*`）、`interrupt`、`thread_id`、`last_thread_id` 等。

### 1.3 usertrap 表（`usertrap_amd64.go:150`、`usertrap.go:28-29`）

- 映射在 **`0x60000`**（< 2GB，这样 `jmp *%ds:disp32` 的 32 位相对地址够得着）。
- `trapNR=256`、`trapSize=80`。每个 trap 槽是一段 **70 字节的 trampoline 机器码**。

---

## 2. 阶段 A：首次执行某处 syscall → 二进制 patch（一次性）

guest 第一次跑 `mov $N,%eax; syscall` 时，走的还是老路径，由 sentry 侧"学会"并 patch 这个站点。

### 2.1 seccomp → SIGSYS → sighandler 识别 pattern

1. `mov $N,%eax; syscall` → seccomp(`SECCOMP_RET_TRAP`) → SIGSYS → `__export_sighandler`
   （`sighandler_amd64.c:202`）。
2. `SIGSYS` 分支（`sighandler_amd64.c:250-317`）反汇编检查 `rip-8` 处 8 字节（读两次，
   用 `sysmsg->fault_jump` 保护读可能缺页的地址，`fault_jump` 机制见 §5.2），判定
   "可 patch" 需同时满足：
   - `[1] == 0xb8`（`mov imm32, %eax` 的 opcode）；
   - `[6..7] == 0f 05`（`syscall` 指令）；
   - `imm32 == siginfo->si_syscall == ptregs.rax`。
   命中则置 `ctx_state = CONTEXT_STATE_SYSCALL_NEED_TRAP`（新版枚举
   `ContextStateSyscallCanBePatched`）；同时 `ptregs.orig_rax = rax`、`ptregs.rax = -ENOSYS`。

### 2.2 sentry 侧触发 patch

3. sentry 的 `switchToApp`（`subprocess.go:812`）看到
   `ctx_state == sysmsg.ContextStateSyscallCanBePatched` → 置 `shouldPatchSyscall=true`
   （`subprocess.go:872-874`）。
4. sentry 调 `s.usertrap.PatchSyscall(ctx, ac, mm)`（`systrap.go:185`）。

### 2.3 `PatchSyscall`（`usertrap_amd64.go:190-290`）

5. 若 `task.Tracer() != nil`（被 ptrace 追踪）则跳过 patch（与 syshandler 不兼容，`:196-212`）。
6. `sysno = ac.SyscallNo()`；`patchAddr = ac.IP() - 7`（`mov`+`syscall` 共 7 字节）。
7. 读 `patchAddr` 处 7 字节 `prevCode`，确认 `prevCode[0] == 0xb8`（`:222-224`）。
8. `addTrapLocked`（`usertrap_amd64_unsafe.go:34-91`）构造 trampoline：
   - `newTrapLocked` 在 usertrap 表分配一个 80B 槽（`:35`）。
   - 生成 70 字节机器码（`:60-69`），嵌入三个运行时值（`:70-72`）：
     - `trap[40:48] = ac.IP()` —— **返回地址**（syscall 下一条）；
     - `trap[58:62] = sysno` —— **系统调用号**；
     - `trap[12:16]/[16:20]/[25:29]/[34:38]/[53:57]/[66:70]` —— 各 `msg.*` 字段偏移与常量。
   - 把 trampoline 写入 trap 槽（`:89`）。

   trampoline 等价汇编（`usertrap_amd64_unsafe.go:53-59` 的注释，也是 `syshandler_amd64.S:186-193` 开头注释）：

   ```asm
   mov    $ThreadStatePrep, %gs:msg.State    ; 置 PREP，推迟中断
   mov    %rsp, %gs:msg.AppStack             ; 存 guest SP
   mov    %gs:msg.SyshandlerStack, %rsp      ; 切到 per-thread 私有栈
   movabs $ret_addr, %rax
   mov    %rax, %gs:msg.RetAddr              ; 存返回地址
   mov    $sysno, %eax                       ; 重新物化 sysno（原 mov 已被 patch 掉）
   jmpq   *%gs:msg.Syshandler                ; 跳进 __export_syshandler
   ```

### 2.4 三步"半原子" patch（`usertrap_amd64.go:266-287`）

因为 7 字节没法原子写，且要保证并发线程在任意时刻读到的是"要么原指令、要么合法 jmp、要么
可检测的中间态"，分三步：

1. **第一步**：把 `syscall` 指令第一字节（`patchAddr+5`）替换为 **`0x06`（非法指令）**。
   这样已越过 `mov`、正要执行 `syscall` 的并发线程会在 `0x06` 处 fault（由 `HandleFault` 重启）。
2. **第二步**：替换除第一字节外的其余字节（保留 `mov` 的 opcode `0xb8`，把 imm32 段写成
   jmp 地址的低 4 字节）。此时首字节仍是 `0xb8`，线程仍把它当 `mov` 执行，无害。
3. **第三步**：替换第一字节为 jmp opcode `0xff`。此后所有线程读到完整合法的
   `jmp *%ds:disp32`。

> 关键技巧（`:247-265` 注释）：jmp 的 disp32 高位天然是 `0x06`（usertrap 表在 `0x60000`，
> 地址高两字节 = `0x6`，恰是非法指令），所以中间态的"半个 jmp"也能被 fault 检测到并重启。

---

## 3. 阶段 B：后续每次执行 = 纯用户态 fast path

patch 之后，任何线程再跑到这个站点就是一条 `jmp`：

### 3.1 trampoline（usertrap 表里 70 字节）

见 §2.3，做四件事：置 PREP → 存 guest SP → 切私有栈 → 存返回地址/恢复 sysno → `jmp` 进
`__export_syshandler`。**这一层是 per-syscall-site 的，线程身份不在这里。**

### 3.2 `__export_syshandler`（`syshandler_amd64.S:185-213`）

1. `prepare_enter_syshandler`（`:39-82`）：
   - 存 `rflags`（`pushfq`）与 `rcx`；
   - `%gs:msg.Context` → `%rcx` 得到 `&thread_context`；
   - 把 GP 寄存器（r15..rdi）、`cs/ss/fs/gs` 段、`eflags`、`rsp`（来自 `msg.AppStack`）、
     `rip`（来自 `msg.RetAddr`）**直接写进 `thread_context.ptregs`**；
   - `orig_rax = rax`。
2. `save_fpstate`（`:138-155`）：按 `arch_state.xsave_mode` 选 `xsaveopt/xsave/fxsave`，
   把 FPU 状态存入 `thread_context.fpstate`（无条件保存）。
3. `callq __syshandler`。

### 3.3 `__syshandler`（C，`sighandler_amd64.c:353-381`）

```c
sysmsg = %gs:0;                       // 取回 sysmsg 指针
assert(state == THREAD_STATE_PREP);   // 入口必须是 PREP
ctx = sysmsg->context;
ctx->signo = SIGSYS;
ctx->siginfo.si_syscall = ctx->ptregs.rax;  // = trampoline 里恢复的 sysno
ctx->ptregs.rax = -ENOSYS;                  // 返回值先置 ENOSYS
ctx->ptregs.fs_base = get_fsbase();         // 保存 fs 基址
ctx->fpstate_changed = 0;
ctx = switch_context_amd64(sysmsg, ctx, CONTEXT_STATE_SYSCALL_TRAP);  // ← 核心
set_fsbase(ctx->ptregs.fs_base);            // 若换了 context 需恢复 fs 基址
```

### 3.4 `switch_context_amd64`（`sighandler_amd64.c:166-197`）

```c
old_ctx = sysmsg->context;
for (;;) {
  ctx = switch_context(sysmsg, ctx, CONTEXT_STATE_SYSCALL_TRAP);  // sysmsg_lib.c:382
  atomic_store(&sysmsg->state, THREAD_STATE_NONE);                 // 允许中断了
  if (atomic_load(&ctx->interrupt) != 0) {   // 这个 context 在队列里被中断过
    atomic_store(&sysmsg->state, THREAD_STATE_PREP);
    atomic_store(&ctx->interrupt, 0);
    new_context_state = CONTEXT_STATE_FAULT;
    ctx->signo = SIGCHLD; ctx->siginfo.si_signo = SIGCHLD;
    ctx->ptregs.orig_rax = -1;
    // 循环再 switch 一次，把 FAULT 还给 sentry
  } else break;
}
if (old_ctx != ctx || ctx->last_thread_id != sysmsg->thread_id)
  ctx->fpstate_changed = 1;                   // context 换过，需恢复 FPU
```

- `switch_context()`（`sysmsg_lib.c:382-402`）做两件事：把旧 ctx 标成 `SYSCALL_TRAP`、
  `futex_wake` 唤醒等待它的 sentry goroutine；再 `get_context()`（`:318`）从 context queue /
  spinning queue 取下一个可运行的 ctx 返回。
- 注意返回的 `ctx` **可能是另一个 guest context**（sentry 可能切走了）。

### 3.5 返回：`asm_restore_state`（`syshandler_amd64.S:199-211`）

1. 重新 `%gs:msg.Context → %rcx`（**可能已换**）；
2. `restore_fpstate`（`:157-178`）：仅当 `fpstate_changed` 非 0 才 `xrstor/fxrstor`；
3. `prepare_exit_syshandler`（`:94-133`）：
   - 把新 ctx 的 `rsp/eflags` 压到私有栈；
   - `msg->ret_addr = ctx->ptregs.rip`；
   - 恢复段（仅当变化，段恢复很慢所以按需）；
   - 恢复所有 GP 寄存器（`rcx` 最后恢复）；
4. `popfq`（恢复 rflags）→ `movq 0(%rsp), %rsp`（恢复 guest rsp）→ `jmp *%gs:msg->ret_addr`
   （跳回 guest RIP）。

**全程没有 `iret`、没有 `rt_sigreturn`、没有信号帧**——就是用户态 `jmp` + 手动恢复寄存器。

---

## 4. 并发 / 竞态处理

- **patch 竞态**：三步 patch + `0x06` 非法指令。详见 §2.4。
- **`HandleFault`（`usertrap_amd64.go:304-347`）**：某线程 fault 在 `patchAddr+5` 附近时，
  sentry 读该处字节：若是「jmp 前 3 字节 + `0x06`」说明是 patch 中间态 → `ErrFaultRestart`
  （把 IP 拨回 `patchAddr` 重启到合法 jmp）；若 `rax == SYS_RESTART_SYSCALL` →
  `ErrFaultSyscall`（当系统调用处理）。
- **sighandler 里的 restart**（`sighandler_amd64.c:294-304`）：SIGSYS 时若读到首字节是
  `FAULT_OPCODE(0x06)`，说明另一线程正在 patch 这个站点，把 `rip -= 7` 直接返回重跑。

---

## 5. 中断 / 信号与 handler 的协调

### 5.1 THREAD_STATE_PREP / NONE

- trampoline 进入即置 `THREAD_STATE_PREP`（`:44`），表示"我正在 syshandler 里，sysmsg 结构
  此刻不完整，别让 sighandler 动它"。
- `__export_sighandler` 对 `SIGCHLD` 且 `state != THREAD_STATE_NONE` 时直接 return（`sighandler_amd64.c:223-225`），
  把中断推迟。
- `switch_context_amd64` 出来后置 `THREAD_STATE_NONE`，并检查 `ctx->interrupt` 是否需要补处理
  （§3.4）。

### 5.2 `sysmsg->fault_jump`（handler 自身缺页保护）

`fault_jump`（`sysmsg.h:64`）记录"handler 正在读/写的一个可能缺页地址的指令长度"。sighandler
在 SEGV/BUS 且 `fault_jump != 0` 时，把 `rip += fault_jump` 跳过那条读指令重试（`sighandler_amd64.c:228-232`）。
典型用于 §2.1 里读 guest 代码 `rip-8` 可能缺页的场景。

---

## 6. 与 ARM64 的对照（FGT 优化的定位）

| AMD64 syshandler | ARM64 + FGT |
|---|---|
| 入口重定向：二进制 patch `mov+syscall` → `jmp *trap`（x86 7B→7B 编码巧合） | **FGT 硬件重定向**：`svc` → `VBAR_EL0_FGT`，不陷 EL1（替代 patch） |
| per-thread 状态：**`%gs`**（x86-64 有 fs+gs 两个，guest 用 fs 做 TLS，gs 归 gVisor） | **缺失**：ARM64 只有 `tpidr_el0`(guest TLS)，无多余寄存器（需 `Tindex_EL0` 或 per-thread VBAR） |
| per-syscall-site trampoline（嵌 sysno+ret_addr） | 不需要（FGT 入口统一，sysno 已在 `x8`） |
| 返回：`jmp *msg->ret_addr` | 手写 sigreturn：写 `ELR_EL0/SPSR_EL0` + `ERET` |
| FPU：`xsaveopt`（有硬件跳过未改状态） | 手动保存 FPSIMD（`sighandler_arm64.c:127` 现只覆盖 NEON） |
| 中断协调：PREP/NONE + `ctx->interrupt` | 可移植同一套逻辑 |
| handler 内 fault：`fault_jump` | ARM64 暂无，需补 |

**核心结论**：FGT 只解决了"入口重定向"（§2/§3.1 的 patch 那一半）；而 syshandler 之所以能
per-thread 工作，靠的是 `%gs`（§1.1/§3.2 那一半）——这在 ARM64 上没有等价物，是需要单独
解决（内核侧提供 per-thread 身份）的唯一难点。其余（寄存器保存/恢复、switch_context、
中断舞步、返回路径）都是可移植的机械活。
