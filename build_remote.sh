#!/bin/bash
#
# gVisor 构建 + rootfs 打包 (cpio.raw + ext4)
# 前置依赖: bazel clang busybox cpio gzip gcc mkfs.ext4
#
set -e

GVISOR_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="/tmp/gvisor-test"
ROOTFS_SIZE="${ROOTFS_SIZE:-256M}"
TARGET_ARCH="${TARGET_ARCH:-aarch64}"  # aarch64 or x86_64

# ============================================================
# 1. 构建 runsc
# ============================================================
echo "=== 构建 runsc (${TARGET_ARCH}) ==="
cd "$GVISOR_DIR"

BAZEL_CONFIG=""
CC="gcc"
if [ "$TARGET_ARCH" = "aarch64" ]; then
    BAZEL_CONFIG="--config=aarch64"
    CC="aarch64-linux-gnu-gcc"
fi

bazel build -c opt \
    $BAZEL_CONFIG \
    --repo_env=GOPROXY=https://goproxy.cn,direct \
    --action_env=GOPROXY=https://goproxy.cn,direct \
    //runsc

RUNSC=$(bazel cquery -c opt \
    $BAZEL_CONFIG \
    --output=starlark --starlark:file=tools/show_paths.bzl \
    //runsc)
echo "runsc: $RUNSC"

# ============================================================
# 2. 组装 rootfs 内容
# ============================================================
echo "=== 组装 rootfs ==="
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/initramfs"/{bin,usr/bin,usr/sbin,proc,sys,dev,tmp,etc}

# runsc
cp "$RUNSC" "$OUTPUT_DIR/initramfs/runsc"
chmod +x "$OUTPUT_DIR/initramfs/runsc"

# busybox
BUSYBOX=""
if [ "$TARGET_ARCH" = "aarch64" ]; then
    BUSYBOX="$OUTPUT_DIR/busybox-arm64"
    if [ ! -f "$BUSYBOX" ]; then
        BUSYBOX_URL="http://ports.ubuntu.com/ubuntu-ports/pool/main/b/busybox/busybox-static_1.36.1-6ubuntu3.1_arm64.deb"
        echo "下载 ARM64 busybox ..."
        wget -q "$BUSYBOX_URL" -O "$OUTPUT_DIR/busybox-arm64.deb"
        dpkg -x "$OUTPUT_DIR/busybox-arm64.deb" "$OUTPUT_DIR/busybox-extract"
        cp "$OUTPUT_DIR/busybox-extract/usr/bin/busybox" "$BUSYBOX"
        rm -rf "$OUTPUT_DIR/busybox-arm64.deb" "$OUTPUT_DIR/busybox-extract"
    fi
else
    BUSYBOX="/usr/bin/busybox"
fi
cp "$BUSYBOX" "$OUTPUT_DIR/initramfs/bin/busybox"

# 用宿主编译 busybox 创建 symlink (symlink 无架构差别)
# 不能用 ARM64 busybox 创建 symlink，因为宿主编译没法直接运行
/bin/busybox --install -s "$OUTPUT_DIR/initramfs/bin/"
# 修复所有 symlink 指向 /bin/busybox
cd "$OUTPUT_DIR/initramfs/bin"
for link in *; do
  if [ -L "$link" ] && [ "$link" != "busybox" ]; then
    ln -sf /bin/busybox "$link"
  fi
done
cd "$GVISOR_DIR"

# syscallbench (交叉编译)
$CC -static -O2 -Wall \
    "$GVISOR_DIR/images/benchmarks/syscallbench/syscallbench.c" \
    -o "$OUTPUT_DIR/initramfs/syscallbench"

# FGT 性能对比脚本
cp "$GVISOR_DIR/bench_fgt.sh" "$OUTPUT_DIR/initramfs/bench_fgt.sh"
chmod +x "$OUTPUT_DIR/initramfs/bench_fgt.sh"

	# init: 进 shell，不自动跑 gVisor
	cat > "$OUTPUT_DIR/initramfs/init" << 'INIT'
#!/bin/sh
export PATH=/bin:/usr/bin:/sbin:/usr/sbin
mount -t proc  proc /proc
mount -t sysfs sysfs /sys
echo ""
echo "===== gVisor ARM64 Shell ====="
echo "  /runsc          -- gVisor sandbox"
echo "  /syscallbench   -- syscall benchmark"
echo "  /bench_fgt.sh   -- FGT 开/关性能对比 (./bench_fgt.sh [loops] [runs])"
echo "  /gvisor-test.sh -- 一键测试脚本"
echo ""
exec /bin/sh
INIT
	chmod +x "$OUTPUT_DIR/initramfs/init"

	# gVisor 测试脚本
	cat > "$OUTPUT_DIR/initramfs/gvisor-test.sh" << 'TEST'
#!/bin/sh
echo "===== Kernel Info ====="
uname -a
echo "===== CPU Info ====="
grep -E "processor|model|CPU" /proc/cpuinfo | head -10
echo "===== Memory Info ====="
free -m 2>/dev/null || head -5 /proc/meminfo

echo ""
echo "===== [1/2] Running gVisor (systrap) with FGT ENABLED ====="
/runsc --TESTONLY-unsafe-nonroot --rootless --network none \
    --debug --alsologtostderr \
    --platform=systrap \
    do /syscallbench
FGT_ENABLED_RC=$?
echo "===== FGT enabled exit code: $FGT_ENABLED_RC ====="

echo ""
echo "===== [2/2] Running gVisor (systrap) with FGT DISABLED ====="
/runsc --TESTONLY-unsafe-nonroot --rootless --network none \
    --debug --alsologtostderr \
    --platform=systrap \
    --systrap-disable-fgt \
    do /syscallbench
FGT_DISABLED_RC=$?
echo "===== FGT disabled exit code: $FGT_DISABLED_RC ====="

echo ""
echo "===== Summary ====="
echo "FGT enabled  exit code: $FGT_ENABLED_RC"
echo "FGT disabled exit code: $FGT_DISABLED_RC"
TEST
	chmod +x "$OUTPUT_DIR/initramfs/gvisor-test.sh"

# ============================================================
# 3. 打包 cpio.raw (无压缩)
# ============================================================
echo "=== 打包 cpio.raw ==="
cd "$OUTPUT_DIR/initramfs"
find . | cpio -v -o -c -R root:root > "$OUTPUT_DIR/initramfs.cpio"
cd -

# ============================================================
# 4. 制作 ext4 镜像 (可 mount)
# ============================================================
echo "=== 制作 ext4 镜像 ==="
EXT4_IMG="$OUTPUT_DIR/rootfs.ext4"
rm -f "$EXT4_IMG"

# 估算所需大小 (内容大小 + 30% 余量)
CONTENT_SIZE=$(du -sk "$OUTPUT_DIR/initramfs" | awk '{print $1}')
NEED_SIZE=$((CONTENT_SIZE * 130 / 100))K
FALLBACK_SIZE=$(echo "$ROOTFS_SIZE" | sed 's/M/000K/;s/G/000000K/')
if [ "$(echo "$NEED_SIZE" | sed 's/K//')" -gt "$(echo "$FALLBACK_SIZE" | sed 's/K//')" ]; then
    IMG_SIZE="$NEED_SIZE"
else
    IMG_SIZE="$ROOTFS_SIZE"
fi

echo "  内容: ${CONTENT_SIZE}K, 镜像大小: $IMG_SIZE"
truncate -s "$IMG_SIZE" "$EXT4_IMG"
mkfs.ext4 -d "$OUTPUT_DIR/initramfs" -O ^has_journal "$EXT4_IMG"

echo ""
echo "=============================================="
echo "  构建完成!"
echo "=============================================="
echo "  runsc:       $RUNSC"
echo "  initramfs.cpio: $OUTPUT_DIR/initramfs.cpio ($(du -h $OUTPUT_DIR/initramfs.cpio | cut -f1))"
echo "  rootfs.ext4: $EXT4_IMG ($(du -h $EXT4_IMG | cut -f1))"
echo ""
echo "  ext4 挂载:"
echo "    sudo mount $EXT4_IMG /mnt"
echo ""
echo "  QEMU (ext4 rootfs, 推荐 8G 内存):"
if [ "$TARGET_ARCH" = "aarch64" ]; then
echo "    qemu-system-aarch64 -M virt -m 8G -cpu cortex-a57 \\"
echo "      -bios <UEFI.fd> \\"
echo "      -kernel <vmlinuz> \\"
echo "      -drive file=$EXT4_IMG,format=raw,if=virtio \\"
echo "      -append 'root=/dev/vda rw console=ttyAMA0 init=/init panic=-1' \\"
echo "      -nographic -no-reboot"
else
echo "    qemu-system-x86_64 -M pc -m 8G -kernel <vmlinuz> \\"
echo "      -drive file=$EXT4_IMG,format=raw,if=virtio \\"
echo "      -append 'root=/dev/vda rw console=ttyS0 init=/init panic=-1' \\"
echo "      -nographic -no-reboot"
fi
echo "=============================================="
