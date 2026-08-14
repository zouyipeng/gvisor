# ARM64 FEAT_FGT 实现 syshandler（fast path）设计方案

> 目标：用 ARM64 上的 FEAT_FGT（SVC 重定向）复刻 AMD64 上 systrap 的「syscall patching」
> fast path，消除信号帧 / rt_sigreturn / seccomp 的开销。
> 前置理解见 `syshandler-amd64-flow.md`。

---

## 0. 一句话结论（AMD64 → ARM64 映射）

| AMD64 syshandler | ARM64 FEAT_FGT |
|---|---|
| 入口重定向：二进制 patch `mov+syscall` → `jmp *trap` | FGT 硬件：`svc` → `VBAR_EL0_FGT`（不陷 EL1） |
| **per-thread 身份：`%gs` 段基址** | **per-thread VBAR_EL0 → per-thread 入口 stub（把 sysmsg 指针烤进 stub）** |
| 私有栈切换：trampoline 里 `mov %gs:msg.SyshandlerStack, %rsp` | stub 里 `ldr x16,[x18,#syshandler_stack]; mov sp,x16` |
| 返回：`jmp *msg->ret_addr`（全程 EL0） | `eret`（写 ELR_EL0 / SPSR_EL0） |
| 寄存器保存：`prepare_enter_syshandler` 写 ptregs | 汇编 stp 写 `ctx->ptregs`（arm64 布局 regs[0..30]/sp/pc/pstate） |
| FP：`xsaveopt` | 手动 stp q0-q31 + fpsr/fpcr（首版不含 SVE） |
| 中断协调：PREP/NONE + `ctx->interrupt` | 移植同一套（sighandler_arm64.c 需补） |

**核心洞察**：VBAR_EL0 按线程粒度维护——这正好补上 ARM64 缺的那一半。
`%gs` 基址 = 每个线程一份、指向该线程的 `struct sysmsg`；ARM64 上用 **per-thread 入口 stub**
（每个线程的 VBAR 指向自己那份 stub，stub 里烤进该线程的 sysmsg 地址）做等价物。
**其余（保存/恢复寄存器、switch_context、中断舞步、返回）都是可移植的机械活。**

---

## 1. 内核语义（已确认）

1. **(P1)** `prctl(71, 1, addr)` 设置**调用线程**的 VBAR_EL0_FGT = `addr`（按线程维护），
   `addr` 需 4KB 对齐。（现有 `fgt.go` 已按此调用。）
2. **(P2)** FGT 使能后，`svc` 在 EL0 直接跳到 `VBAR_EL0_FGT`；硬件保存
   `ELR_EL0`=返回 PC、`SPSR_EL0`=guest PSTATE，**x0-x30 与 SP 原样保留**（SP=SP_EL0=guest SP）。
3. **(P3)** 进入 handler 时 FGT **自动关闭**：handler 内的 `svc`（如 switch_context 里的
   futex）走正常 EL0→EL1 路径（现有 forwarder 注释已确认）。
4. **(R1，已确认)** 返回时 FGT **仅在 ERET 重新使能**（`br` 不重新使能）→ 返回必须用
   `eret`（写 `elr_el0`/`spsr_el0` 后 eret），不用 `br`。
5. **(R2，已确认)** `ELR_EL0` / `SPSR_EL0` 在 EL0 可用 `mrs`/`msr` 读写（`msr elr_el0` /
   `msr spsr_el0` 均可）；`eret` 时 PC/PSTATE 由硬件从二者恢复，无需软件恢复。
6. **(R3，已确认)** 全量保存/恢复 x0-x30（含 x18，不依赖「guest 不用 x18」）：`x18` 兼作
   handler 的 sysmsg 基址，stub 进入时先把 guest 的原始 x18 压到私有栈、handler 内读入
   `ptregs.regs[18]`，返回前统一恢复；`x16/x17` 作 stub 引导 scratch。

---

## 2. 核心机制：per-thread 入口 stub = `%gs` 的等价物

每个 sysmsg 线程新增 **一页 4KB RX 的「FGT 入口 stub」**，VBAR_EL0 指向它。
stub 是固定字节模板，创建线程时**把该线程的 `sysmsg` 地址烤进 movz/movk 立即数**
（与 AMD64 trampoline 把 ret_addr/sysno 烤进模板同一种手法）。

```
（每个线程）                                  （共享，sysmsg blob 内）
┌─────────────────┐  VBAR_EL0 ──► ┌──────────────────────┐
│ per-thread stub │               │ __export_fgt_handler │
│  (4KB, RX)      │               │  (save/restore +     │
│  sysmsg ptr 烤入 │ ──br x16──►  │   call __syshandler) │
└─────────────────┘               └──────────────────────┘
```

stub 伪汇编（每线程一份，`#sysmsg` 为烤入值）：
```asm
movz x18, #lo16(sysmsg) ; movk x18,#hi(sysmsg),lsl#16 ; movk x18,#hi2,lsl#32 ; movk x18,#hi3,lsl#48
mov  x16, sp                        ; 存 guest SP
str  x16, [x18, #offsetof_sysmsg_app_stack]
ldr  x16, [x18, #offsetof_sysmsg_syshandler_stack]
mov  sp, x16                        ; 切到 per-thread 私有 syshandler 栈
ldr  x16, [x18, #offsetof_sysmsg_syshandler]   ; = __export_fgt_handler 地址
br   x16
```

关键点：
- **x18 就是 `%gs` 基址的角色**（永远指向当前线程的 sysmsg），handler 全程用它 `[x18,#off]`
  访问 sysmsg 字段，与 AMD64 的 `%gs:msg.*` 一一对应。
- stub 与 sysmsg 结构分离（stub 在 RX 页，sysmsg 在 RW 页），**避免 W^X**，与 AMD64 把
  trampoline(可执行) 与 sysmsg(可写) 分开保持一致。
- `sysmsg->syshandler` 字段复用：FGT 使能时指向 `__export_fgt_handler`（见 §4.2）。

---

## 2.1 线程切换与 VBAR / guest context 的区分

**结论：gVisor 内部的 context 切换不需要切换 VBAR，也不靠 VBAR 区分 guest context。**

### 2.1.1 两种「切换」，只有一种涉及 VBAR

| 切换 | 执行者 | 是否动 VBAR |
|---|---|---|
| 层 A：host 内核调度器在两个 sysmsg 线程（两个真实 Linux task）之间切换 | 内核 | 是，内核按 task 保存/恢复 VBAR_EL0_FGT（§1 P1） |
| 层 B：gVisor `switch_context()` 换 guest context（`sysmsg_lib.c:382`） | 同一 host 线程内的 C 代码 | 否，host 线程没变 |

- 每个 sysmsg 线程 = 一个真实 host Linux task（`createSysmsgThread()` → `ptraceThread.clone()`，
  `subprocess.go:256`/`:1071`）。VBAR_EL0_FGT 是它的寄存器状态，随内核调度保存/恢复。
- `switch_context()` 只是把「当前 host 线程服务的 guest 上下文」从 A 换成 B：标旧 ctx 完成 →
  `get_context()` 取下一个 ctx → 恢复其寄存器 → `eret`。全程不换 host 线程。

### 2.1.2 sysmsg 线程是「池」，M:N 映射到 guest 线程

不是 1:1。`sysmsgThreads map[uint32]*sysmsgThread`（`subprocess.go:169`）+ `maxSysmsgThreads`
是一个池，`kickSysmsgThread()` 按需增删（`subprocess.go:971`）。`thread_context` 有
`thread_id` / `last_thread_id` 字段（`sysmsg_lib.c:389-390`），`switch_context` 把它们写成
`INVALID_THREAD_ID` / `sysmsg->thread_id`，正是为了追踪「该 guest ctx 上次被哪个 sysmsg
线程跑过」。→ **身份必须绑在 host sysmsg 线程上，而不是 guest 线程上。**

### 2.1.3 区分 guest context：两级指针，一级静态、一级动态

```
SVC ──► VBAR_EL0_FGT ──► per-thread stub ──► x18 = sysmsg ──► sysmsg->context ──► thread_context
        (内核按 host 线程维护)   (烤死的指针，创建后不变)        (每次 get_context 改写)
                                    └ 回答「哪个 host 线程」          └ 回答「哪个 guest context」
```

- **第一级 `x18 → sysmsg`**：烤进 stub 的立即数，创建后不变，回答「跑在哪个 host sysmsg 线程上」。
- **第二级 `sysmsg->context`**：可变指针，回答「该 host 线程此刻正服务哪个 guest context」。

**无歧义的原因**：一个 host sysmsg 线程任意时刻只跑一个 guest context（单控制流），且
`sysmsg->context` 在 guest 代码开跑之前就被绑定——`queue_get_context()` 弹出 ctx 后第一件事
就是 `sysmsg->context = ctx`（`sysmsg_lib.c:241`），之后才恢复寄存器、`eret` 进 guest。于是
guest 后续 `SVC` 进 handler 时，`[x18,#context]` 读到的必然就是当前这个 ctx；只有下一次
`switch_context()`（必然发生在 trap 边界）才会改写它，且同时同步恢复下一个 ctx 的寄存器。
指针与寄存器状态在同一条路径、同一个边界一起换，永不错位。

### 2.1.4 与 AMD64 对照

AMD64 fast path 取 context（`syshandler_amd64.S:46`）：

```asm
movq %gs:offsetof_sysmsg_context, %rcx   ; %gs → sysmsg → context
```

ARM64 等价于：

```asm
ldr  x16, [x18, #offsetof_sysmsg_context] ; x18 → sysmsg → context
```

`%gs`（amd64）与 `x18`（arm64，由 stub 烤入）角色完全相同；「跑哪个 guest context」在两者上
都由 `sysmsg->context` 回答，该字段与 `get_context/switch_context` 协议是架构无关 C 代码，
arm64 直接复用，无需额外机制。

### 2.1.5 对 handler 的印证

handler 进入时必须**每次现读 `[x18, #context]`，不能缓存**（方案 §3.2 第 2 步正是 `ldr x16,
[x18, #context]`），因为同一 sysmsg 线程服务下一个 guest ctx 时该字段已被改写。

---

## 3. Fast path 完整流程

### 3.1 入口（stub，见 §2）
置 x18=sysmsg、存 guest SP 到 `sysmsg->app_stack`、切私有栈、`br` 进共享 handler。

### 3.2 共享 handler `__export_fgt_handler`（替换现在的 forwarder）
```
1. str  w16, [x18, #state]  = THREAD_STATE_PREP        ; 推迟中断
2. ldr  x16, [x18, #context]                            ; ctx = sysmsg->context
3. 存 guest SP/PC/PSTATE：
     ldr x17,[x18,#app_stack]  → ctx->ptregs.sp
     mrs x17,elr_el0           → ctx->ptregs.pc  (同时写 sysmsg->ret_addr)
     mrs x17,spsr_el0          → ctx->ptregs.pstate
4. stp 存 x0..x30 → ctx->ptregs.regs[0..30]（全量保存；x18 的 guest 值由 stub 先压私有栈，此处读回 regs[18]）
5. 存 FP：stp q0..q31 + fpsr/fpcr → ctx->fpstate（SVE 见 §4.5）
6. ctx->signo = SIGSYS；ctx->siginfo.si_syscall = x8；
   ctx->ptregs.regs[0] = -ENOSYS；ctx->tls = mrs tpidr_el0
7. call __syshandler        ; C：switch_context(SYSCALL_TRAP) + 中断舞步（§3.3）
8. 恢复新 ctx：FP(若 fpstate_changed)、x0..x30、tpidr_el0、NZCV
9. 返回：msr elr_el0, ctx->pc ; msr spsr_el0, ctx->pstate ; eret
```

### 3.3 `__syshandler`（新增 C，移植 AMD64 `sighandler_amd64.c:353-381` + `:166-197`）
与 `__export_sighandler` 的差异只有两点：
- context state 用 **`CONTEXT_STATE_SYSCALL_TRAP`**（而非 `SYSCALL`），sentry 据此区分
  "来自 fast path" 与 "来自信号路径"（对应 AMD64 的 `__syshandler`）。
- 加 **PREP/NONE + `ctx->interrupt` 中断舞步**（`switch_context_amd64` 那段 for 循环）：
  `switch_context` 出来后置 `THREAD_STATE_NONE`，若 `ctx->interrupt` 被置位则再 switch 一次
  把 FAULT 还给 sentry。

### 3.4 返回路径（已定：ERET）
- **ERET**：`msr elr_el0, ctx->pc ; msr spsr_el0, ctx->pstate ; eret`。
  FGT 只在 ERET 重新使能（§1 R1），因此返回必须走 ERET，不用 `br`。
- `ELR_EL0`/`SPSR_EL0` 在 EL0 可用 `msr` 写（§1 R2，已确认）；`eret` 由硬件恢复 PC/PSTATE。

**全程无信号帧、无 rt_sigreturn、无 seccomp** —— 与 AMD64 一样，只是入口/出口换成
SVC/ERET，中间是同一套 switch_context。

---

## 4. 实现步骤（按文件）

### 4.1 入口 stub（新）
- 新增 stub 字节模板（Go 常量或 `.S` + 运行时烤指针），结构见 §2。
- 在 `stub_unsafe.go` 的 per-thread 区旁、或 `subprocess.go` 的 `newSysmsgThread`（≈:1106）里，
  为每个线程分配一页 RX 并写入烤好指针的 stub，记录 stub 地址到 `sysmsgThread`。

### 4.2 `fgt.go` + `subprocess.go`
- `fgtHandlerAddr()`（`fgt.go:58`）改/增为「每线程 stub 地址」：`injectFGTEnable(t)` 用
  **该线程的 stub 地址**调 `prctl(71,1,stub)`。
- `subprocess.go:1159`：FGT 使能时把 `msg.Syshandler` 设为 `__export_fgt_handler`（共享
  handler 地址），供 stub 第 5 行 `ldr` 使用。
- `alignExecMapEndForFGT`（`fgt.go:65`）逻辑基本不变（共享 handler 仍在 blob 内 4KB 对齐）。

### 4.3 `sysmsg/fgt_handler_arm64.S`（重写）
- 删掉现在「保存 X0-X30 → 重发 SVC → ERET」的 forwarder，改为 §3.2 的真实 handler。
- 保留 `.balign 4096`（共享 handler 地址需 4KB 对齐）。
- 复用/参照 `syshandler_amd64.S` 的 `prepare_enter/exit_syshandler`、`save/restore_fpstate`
  结构，改写成 arm64 的 `stp`/`mrs`/`msr`。

### 4.4 偏移量（新 `sysmsg_offsets_arm64.h`）
- 现有 `sysmsg_offsets.h` 只有 sysmsg 字段偏移（`self/ret_addr/.../context`，通用）+ amd64 的
  ptregs 偏移。需新增 arm64 的 `offsetof_thread_context_ptregs_regsN` / `_sp` / `_pc` / `_pstate`
  （对应 `linux.PtraceRegs{Regs[31],Sp,Pc,Pstate}`，见 `ptrace_arm64.go:60`）。
- 在 `sysmsg_lib.c:verify_offsets()` 或 `sighandler_arm64.c` 加对应 `BUILD_BUG_ON`。

### 4.5 FP 状态（`sysmsg_arm64.go` ArchState + handler）
- `ArchState` 目前只有 `fpLen`（`sysmsg_arm64.go:35`）。首版只支持 FPSIMD（与现有 sighandler
  的 `kFpsimdContextSize` 一致），handler 用 `stp q0-q31` + `fpsr`/`fpcr` 保存/恢复。
- 首版不考虑 SVE：若 guest 启用 SVE 则禁用 FGT（走信号路径）或 panic，避免误保存。

### 4.6 `sighandler_arm64.c`（中断协调）
- 移植 AMD64 `sighandler_amd64.c:223-225` 的「SIGCHLD 且 `state != THREAD_STATE_NONE` 直接
  return」逻辑：fast path 里（state=PREP）到达的信号被推迟，由 handler 退出前检查
  `ctx->interrupt` 补处理。
- `switch_context` 本身（`sysmsg_lib.c:382`）架构无关，无需改。

### 4.7 seccomp
- `sysmsg_thread_arm64.go` 已放行 `prctl(71)`；sysmsg 线程的 futex/sched_yield 等已放行，
  无需新增。

---

## 5. 验证

1. **编译**：`bazel build //pkg/sentry/platform/systrap/...`（arm64 交叉或原生）。
2. **单测 stub 生成**：对烤指针逻辑写 Go 单测（给定 sysmsg 地址 → 反汇编/字节断言）。
3. **功能**：在带自定义内核的 arm64 机器上跑 systrap 集成测试（`runsc do` / syscall 测试），
   重点回归：多线程并发 syscall、`switch_context` 上下文迁移、信号中断（SIGCHLD）协调。
4. **正确性对照**：FGT 关 vs 开跑同一组 syscall 测试，结果一致。
5. **性能**：`runsc` syscall 延迟微基准，对比 FGT 关（走信号路径）与开（fast path），
   预期接近 AMD64 syshandler 的量级（消掉信号帧+sigreturn+seccomp）。

---

## 6. 待确认（内核侧语义，本地内核树没有该扩展，只能由内核侧确认）

已确认：**per-thread stub（烤指针）** 作身份机制；**仅 ERET 重新使能** FGT；
**`ELR_EL0`/`SPSR_EL0` 在 EL0 可 `msr`/`mrs`**；**全量保存 GPR（含 x18）**；
**首版不考虑 SVE（仅 FPSIMD）**。
