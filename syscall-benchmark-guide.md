# gVisor Syscall Benchmark 测试指南

使用 `syscallbench`（位于 `images/benchmarks/syscallbench/syscallbench.c`）测试 gVisor 下 getpid 系统调用的性能。

---

## 1. 前置条件

### 1.1 安装 runsc

```bash
# 下载预编译 runsc
curl -L -o /tmp/runsc https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/runsc
chmod +x /tmp/runsc && cp /tmp/runsc ~/bin/runsc

# 安装为 Docker 运行时
sudo ~/bin/runsc install --runtime=runsc
sudo systemctl restart docker
```

### 1.2 编译 syscallbench

```bash
gcc -O2 -o /tmp/syscallbench images/benchmarks/syscallbench/syscallbench.c
```

> 注意：`syscallbench` 依赖 x86_64 内联汇编，仅支持 amd64 架构。

---

## 2. 运行 Benchmark

### 2.1 原生环境（Native）

```bash
# getpid（通过 libc）
time /tmp/syscallbench --loops=10000000 --syscall=0

# getpidopt（内联汇编，跳过了 libc 和 vDSO）
time /tmp/syscallbench --loops=10000000 --syscall=1

# getpid + seccomp cacheable（内核可缓存 seccomp 结果）
time /tmp/syscallbench --loops=10000000 --syscall=0 --seccomp_cacheable

# getpid + seccomp uncacheable（检查参数，不可缓存）
time /tmp/syscallbench --loops=10000000 --syscall=0 --seccomp_notcacheable
```

### 2.2 gVisor 环境（runsc do）

使用 `runsc do` 直接在 gVisor 沙箱中运行命令，不需要 Docker：

```bash
echo "your_sudo_password" | sudo -S bash -c 'time ~/bin/runsc do --quiet /tmp/syscallbench --loops=10000000 --syscall=0'

echo "your_sudo_password" | sudo -S bash -c 'time ~/bin/runsc do --quiet /tmp/syscallbench --loops=10000000 --syscall=1'

echo "your_sudo_password" | sudo -S bash -c 'time ~/bin/runsc do --quiet /tmp/syscallbench --loops=10000000 --syscall=0 --seccomp_cacheable'

echo "your_sudo_password" | sudo -S bash -c 'time ~/bin/runsc do --quiet /tmp/syscallbench --loops=10000000 --syscall=0 --seccomp_notcacheable'
```

### 2.3 gVisor 环境（Docker 方式，需要网络）

如果网络可以访问 Docker Hub，也可以用 Docker 方式：

```bash
# 构建镜像
docker build -t benchmarks/syscallbench \
  -f images/benchmarks/syscallbench/Dockerfile.x86_64 \
  images/benchmarks/syscallbench/

# 在 runsc 运行时下运行
docker run --runtime=runsc --rm benchmarks/syscallbench \
  /usr/bin/syscallbench --loops=10000000 --syscall=0
```

### 2.4 gVisor 自带 Benchmark 框架（完整方式，需要 Bazel）

```bash
# 使用 gVisor 的 Makefile 框架
make run-benchmark \
  BENCHMARKS_TARGETS=//test/benchmarks/base:syscallbench_test \
  BENCHMARKS_FILTER=BenchmarkSyscallbench
```

---

## 3. syscallbench 命令行选项

```
Usage: syscallbench [options]
  -l, --loops <num>          Number of syscall loops, default 10000000
  -s, --syscall <num>        Syscall to run (default getpid)
      --seccomp_cacheable    Add a cacheable ALLOW seccomp filter
      --seccomp_notcacheable Add a non-cacheable ALLOW seccomp filter

Options:
  0) getpid
  1) getpidopt
```

---

## 4. 结果解读

在 10M loops 下的典型结果：

| 场景 | Native | gVisor | 倍率 |
|------|--------|--------|------|
| getpid (libc) | ~6.0s (600ns/call) | ~45.6s (4.56μs/call) | 7.6x |
| getpidopt (asm) | ~6.0s (600ns/call) | ~10.5s (1.05μs/call) | 1.8x |
| + seccomp cacheable | ~6.3s (630ns/call) | ~46.9s (4.69μs/call) | 7.4x |
| + seccomp uncacheable | ~7.0s (700ns/call) | ~47.3s (4.73μs/call) | 6.7x |

### 关键说明

- **getpidopt 在 gVisor 下更快**：内联汇编的 `syscall` 指令路径更短，gVisor 拦截效率更高
- **seccomp 在 gVisor 下开销不明显**：因为 gVisor 自己的 syscall 拦截已经覆盖了 seccomp 的功能
- **gVisor 的 syscall 截获开销**：主要由 sentry 进程的 ptrace/systrap 拦截 + Go 处理逻辑 + 实际执行三部分组成
- 测试结果受宿主机 CPU、内核版本、gVisor 版本和平台（systrap/KVM）影响

---

## 5. 扩展测试其他 Syscall

修改 `images/benchmarks/syscallbench/syscallbench.c`：

1. 在 `enum syscall_type` 中添加新的 syscall 类型
2. 在 `main()` 的 switch 中添加对应的 benchmark 循环
3. 重新编译测试

```c
enum syscall_type { get_pid, get_pid_opt, custom_syscall };

// 在 main() 中添加
case (int)custom_syscall:
    for (i = 0; i < loops; i++) syscall(SYS_write, 1, "x", 1);
    break;
```

```bash
gcc -O2 -o /tmp/syscallbench images/benchmarks/syscallbench/syscallbench.c
echo "123456" | sudo -S ~/bin/runsc do --quiet /tmp/syscallbench --loops=1000000 --syscall=2
```

---

## 6. QEMU aarch64 虚拟机测试

可用制作好的 rootfs + 内核在 QEMU 中一鍵测试：

### 6.1 文件说明

| 文件 | 说明 |
|------|------|
| `gvisor-bench-rootfs-openeuler-aarch64.cpio.gz` | 完整 rootfs（initramfs），含 Alpine + runsc + syscallbench |
| `openeuler_olk6.6/kernel/arch/arm64/boot/Image` | openEuler 6.6 aarch64 内核（已配好所需内核选项） |
| `images/benchmarks/syscallbench/syscallbench.c` | syscallbench 源码（已适配 x86_64 + aarch64） |

### 6.2 启动并运行

```bash
qemu-system-aarch64 \
  -machine virt \
  -cpu cortex-a72 \
  -m 2G \
  -nographic \
  -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
  -kernel /path/to/Image \
  -initrd /path/to/gvisor-bench-rootfs-openeuler-aarch64.cpio.gz \
  -append "console=ttyAMA0 root=/dev/ram rdinit=/init" \
  -nic none
```

进入 shell 后，直接运行：

```bash
run-benchmark          # 默认 1M loops
run-benchmark 10000000 # 自定 loop 数
```

脚本会自动执行 4 项测试并输出结果表格：

```
  native getpid:              Xs  (Y ns/call)
  native getpidopt:           Xs  (Y ns/call)
  gvisor getpid:              Xs  (Y ns/call)
  gvisor getpidopt:           Xs  (Y ns/call)
```

### 6.3 注意事项

- `runsc do` 需要 root 权限创建网络接口，可以用 `sudo` + `-S` 传密码
- WSL2 环境下测试结果可能略低于物理机
- 首次运行 `runsc do` 会拉取基础 rootfs（如果需要），可能较慢
- 测试建议关闭其他负载，取多次运行的平均值
- aarch64 QEMU 全系统模拟下 runsc sandbox 可能有兼容性问题，**真鲲鹏硬件上应该正常**
