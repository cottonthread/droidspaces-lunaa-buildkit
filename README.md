# Realme GT Master Edition Droidspaces 完整固件复刻指南

> [!NOTE] 适用范围
> 本指南记录在 Realme GT Master Edition（`lunaa` / `RE54ABL1` / Snapdragon 778G）上，基于 LineageOS 23.2 / Android 16，生成带Droidspaces兼容Kernel的完整OTA、target-files和fastboot images ZIP的成功路径。

> [!WARNING] “带Droidspaces固件”的准确含义
> 已确认固件内包含Droidspaces所需的Kernel kABI patch和配置，但**没有证据表明Droidspaces v6.4.5 userspace、应用或Magisk模块被嵌入系统镜像**。本次真机运行使用的是userdata中原有的Magisk 30.7、Droidspaces应用和Magisk模块。若要开箱即用，仍需另行集成或安装userspace组件。

公开版资料：

- 验证边界与已知限制：[验证摘要](docs/validation-summary.md)
- 精确 Droidspaces Kernel source commit：[`9da4bdfa0e5d73fce8ae282a2898d054dcd2df80`](https://github.com/cottonthread/android_kernel_oneplus_sm8350/commit/9da4bdfa0e5d73fce8ae282a2898d054dcd2df80)
- 原始命令记录、设备唯一标识、本地路径与完整构建产物仅保留在私有归档，不随本仓库发布。

设备标识不要混用：

| 标识 | 含义 |
|---|---|
| `lunaa` | LineageOS build target / device tree代号 |
| `RE54ABL1` | Android device与OTA `pre-device` |
| `RMX3360` | 产品型号 |
| `lahaina` | Qualcomm平台及fastboot product返回值 |
| `realme GT Master` | 部分vendor属性中的市场名称 |


## 0. 先读结论与边界

### 0.1 公开版产物策略

本公开仓库提供可审阅的冻结源码输入、patch、Kernel overlay 与复刻脚本，但**不分发此前构建的完整 OTA、images、target-files、git bundle 或 Magisk 修补镜像**。这些资产含旧构建身份或属于私有归档范围。

后续若发布可安装产物，只会在以通用 Android 与 Kernel 构建身份重建、完成独立校验后，作为单独的 Kernel-only Release 提供。

### 0.2 两种复刻模式

1. **冻结源码复刻模式**
   - 使用归档的resolved manifest固定全部revision。
   - 使用最终tracked diff和经过allowlist筛选的Kernel新增文件。
   - 目标是重现2026-08-25的源码状态和构建路径。

2. **向新源码移植模式**
   - 使用较新的LineageOS/device/vendor/Kernel分支。
   - 只移植本指南的逻辑修改，不假设旧patch能直接应用。
   - 所有VINTF、APEX、AVB和真机检查必须从零重做。

> [!CAUTION]
> 不要把旧manifest、旧vendor blobs和今天的新LineageOS HEAD随意混用。冻结源码复刻与forward-port必须明确二选一。

> [!IMPORTANT] 不是字节级reproducible build声明
> 现有资料没有固定host包版本、构建用户名/主机名、locale/timezone、构建时间和完整干净OUT状态，因此本指南承诺的是源码快照与逻辑路径可复刻，不承诺新产物SHA-256与2026-08-25产物逐字节一致。若要求bit-for-bit复现，还需容器化host、固定build identity/time并使用全新OUT验证。

### 0.3 已知审计缺口

- 原后处理中的OTA、payload、ZIP、VINTF和SHA-256检查有效。
- 原独立AVB检查**无效**：脚本以 `python3`执行host `avbtool`二进制，并用 `|| true`吞掉失败。
- `audit-status.txt`没有AVB字段，因此不得把原归档描述成“独立AVB审计通过”。
- 本指南已给出修正后的AVB调用和强制失败策略。

## 第一部分：用户手工复刻版

### 1. 安全前提

#### 1.1 构建与设备是两个独立阶段

- 完成构建不代表必须立即刷机。
- 构建、签名和审计可以在没有手机连接的情况下完成。
- 任何 `flash`、切槽、wipe或metadata操作都必须单独审批。

#### 1.2 槽位原则

- 只在一个测试槽安装新系统。
- 另一个槽保留已知良好系统和完整启动链。
- 不得混用不同构建的boot、vendor_boot、dtbo、vbmeta、vendor_dlkm和动态分区。
- metadata和userdata为两槽共享；切槽不等于加密状态隔离。
- `super`及dynamic partition metadata也是共享资源；救援槽不是完整物理隔离，只能作为尽力而为的回退入口。

#### 1.3 KeyMint/FBE原则

- boot image header中的OS patch level可能触发KeyMint/FBE key blob升级。
- 较新patch-level启动后，直接回到较旧header可能造成 `init_user0_failed`。
- 任何临时 `fastboot boot`也可能触发持久key升级；“不写分区”不等于“不会改变userdata/metadata中的安全状态”。

### 2. 已知成功环境

| 项目 | 实际值 |
|---|---|
| Host | Ubuntu 24.04.4 LTS / WSL2 / x86_64 |
| RAM | 约27–28 GiB |
| Swap | 48 GiB |
| 源码目录 | `$SRC_ROOT` |
| 输出目录 | 相对路径 `out-droidspaces-full` |
| JDK | 源码自带JDK 21 |
| 并发 | `-j4` |
| 文件系统 | 源码和OUT均在WSL ext4 VHDX内 |

建议至少准备：

- 32 GiB RAM或足够swap；
- 400 GiB以上可用磁盘；
- ext4或原生Linux文件系统；
- 不要把Android源码/Soong OUT直接放在NTFS/DrvFS目录。

#### 2.1 依赖模板

以下是本次环境使用的依赖集合；若某包在发行版中改名，以当前LineageOS构建文档为准：

```bash
sudo apt update
sudo apt install \
  bc bison build-essential ccache curl flex \
  g++-multilib gcc-multilib git git-lfs gnupg gperf imagemagick \
  lib32ncurses-dev lib32readline-dev lib32z1-dev \
  liblz4-tool libncurses-dev libsdl1.2-dev libssl-dev \
  libwxgtk3.0-gtk3-dev libxml2 libxml2-utils lzop pngcrush \
  rsync schedtool squashfs-tools xsltproc zip zlib1g-dev \
  python-is-python3 erofs-utils lz4 xxd \
  protobuf-compiler python3-protobuf libdw-dev libelf-dev libgnutls28-dev
```

### 3. 固定输入与BOM

#### 3.1 本次归档输入

本地归档目录：

```text
<host-workspace>/Droidspaces-full-20260825
```

关键输入：

| 文件 | SHA-256 | 用途 |
|---|---|---|
| `droidspaces-full-preflight-manifest-20260824.xml` | `72905b805c5d094c363fe7d78e032dd8bafceff1ae0948bd98eb049f6e0f8513` | 全部源码revision BOM |
| `droidspaces-final-tracked-20260825.diff` | `ed33681e0252513f1b0640d122a6058d6308366d8715c64e80820e5d2ba11b01` | 最终tracked修改 |
| `droidspaces-full-preflight-kernel-untracked.tar.gz` | `d3d4bb8e14ee20555b84f30530e625514b28060fd8f9b03799c0ef085f98c121` | Kernel新增文件，必须allowlist提取 |
| `run-droidspaces-full-build-attempt7-20260825.sh` | `f3ed57a33b53aa667626cb76ac87f3a011e201df011f49aa051c032d9c36cac8` | 实际成功增量构建断言 |

#### 3.2 七个设备相关项目

| 路径 | 仓库 | 分支 | 固定revision |
|---|---|---|---|
| `device/realme/lunaa` | `pjgowtham/android_device_realme_lunaa` | `lineage-23.2` | `b653f480d0d53d4144ed161450e28b24c4edd9e9` |
| `device/oneplus/sm8350-common` | `pjgowtham/android_device_oneplus_sm8350-common` | `lineage-23.2` | `8e8157557548dfa3494335092af097fea2903df2` |
| `hardware/oplus` | `pjgowtham/android_hardware_oplus` | `lineage-23.2` | `9ed73330d06ad8ef3aa4595f6ee49837928dfda6` |
| `kernel/oneplus/sm8350` | `pjgowtham/android_kernel_oneplus_sm8350` | `lineage-23.2` | `f96127f51a9a5cda38dd1b938d68d0c0593f3844` |
| `hardware/pixelworks/interfaces` | `pjgowtham/hardware_pixelworks_interfaces` | `lineage-22.2` | `d6d115740b25af00c3cf4fd9a580490a761d9372` |
| `vendor/oneplus/sm8350-common` | GitLab `pjgowtham/proprietary_vendor_oneplus_sm8350-common` | `lineage-23.2` | `6297e5b930f2a200199814e87866d515f0775d7b` |
| `vendor/realme/lunaa` | GitLab `pjgowtham/proprietary_vendor_realme_lunaa` | `lineage-23.2` | `091d584924b7174b54dc2ed8f0f3e6fd3a307a06` |

> [!NOTE]
> 完整LineageOS平台不仅有这7个项目。冻结源码复刻必须使用resolved manifest核对全部项目revision，而不是只固定上表。

### 4. 初始化与同步源码

先初始化LineageOS manifest仓库：

```bash
mkdir -p $SRC_ROOT
cd $SRC_ROOT

repo init \
  -u https://github.com/LineageOS/android.git \
  -b lineage-23.2 \
  --git-lfs \
  --no-clone-bundle
```

#### 4.1 冻结源码复刻模式：使用resolved manifest

冻结manifest已包含平台和七个设备相关项目的全部revision及remote定义。保留默认manifest备份，然后把冻结文件安装为当前静态manifest：

```bash
ROOT=$SRC_ROOT
INPUT_DIR=/path/to/Droidspaces-full-20260825

cd "$ROOT"
cp -L .repo/manifest.xml .repo/manifest.before-droidspaces.xml
test ! -e .repo/local_manifests || {
  echo 'Existing local manifests found; move them aside manually and review first.' >&2
  exit 1
}
rm -f .repo/manifest.xml
cp "$INPUT_DIR/droidspaces-full-preflight-manifest-20260824.xml" \
  .repo/manifest.xml

repo sync -c -j4 --force-sync --no-clone-bundle --no-tags
```

同步后必须执行第3.1节哈希核对并导出新的resolved manifest进行比较。若当前 `repo`实现拒绝静态 `.repo/manifest.xml`，不得悄悄退回最新HEAD；应停止，并把冻结XML放入一个本地manifest Git仓库后重新 `repo init -u file:///... -m <name>`。

#### 4.2 分支/forward-port模式：创建local manifest

若目标是使用当前分支而不是固定全部平台revision，创建：

```bash
mkdir -p .repo/local_manifests
cat > .repo/local_manifests/lunaa.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="github-pjgowtham" fetch="https://github.com/pjgowtham/"/>
  <remote name="gitlab-pjgowtham" fetch="https://gitlab.com/pjgowtham/"/>

  <project name="android_device_oneplus_sm8350-common"
           path="device/oneplus/sm8350-common"
           remote="github-pjgowtham" revision="lineage-23.2"/>
  <project name="android_device_realme_lunaa"
           path="device/realme/lunaa"
           remote="github-pjgowtham" revision="lineage-23.2"/>
  <project name="android_hardware_oplus"
           path="hardware/oplus"
           remote="github-pjgowtham" revision="lineage-23.2"/>
  <project name="android_kernel_oneplus_sm8350"
           path="kernel/oneplus/sm8350"
           remote="github-pjgowtham" revision="lineage-23.2"/>
  <project name="hardware_pixelworks_interfaces"
           path="hardware/pixelworks/interfaces"
           remote="github-pjgowtham" revision="lineage-22.2"/>
  <project name="proprietary_vendor_oneplus_sm8350-common"
           path="vendor/oneplus/sm8350-common"
           remote="gitlab-pjgowtham" revision="lineage-23.2"/>
  <project name="proprietary_vendor_realme_lunaa"
           path="vendor/realme/lunaa"
           remote="gitlab-pjgowtham" revision="lineage-23.2"/>
</manifest>
XML

repo sync -c -j4 --force-sync --no-clone-bundle --no-tags
```

> [!WARNING]
> 本模式不等于2026-08-25冻结源码复刻。旧diff只能先做 `git apply --check`；发生冲突时必须按逻辑移植并重新完成全部审计。

#### 4.3 同步后核对

同步后保存并比较：

```bash
repo manifest -r -o current-manifest.xml
repo status
```

冻结源码模式逐项目比较全部 `path → revision`：

```bash
python3 - "$INPUT_DIR/droidspaces-full-preflight-manifest-20260824.xml" \
  current-manifest.xml <<'PY'
import sys
import xml.etree.ElementTree as ET

def projects(path):
    result = {}
    for node in ET.parse(path).getroot().findall('project'):
        project_path = node.get('path', node.get('name'))
        if project_path in result:
            raise SystemExit(f'duplicate project path: {project_path}')
        result[project_path] = node.get('revision')
    return result

expected = projects(sys.argv[1])
actual = projects(sys.argv[2])
if expected != actual:
    missing = sorted(expected.keys() - actual.keys())
    extra = sorted(actual.keys() - expected.keys())
    changed = sorted(path for path in expected.keys() & actual.keys()
                     if expected[path] != actual[path])
    raise SystemExit({"missing": missing, "extra": extra,
                      "changed_revision": changed})
PY
```

冻结源码模式要求全部path/revision与resolved manifest一致；以下七个设备相关project还应显式复核：

```bash
for spec in \
  'device/realme/lunaa b653f480d0d53d4144ed161450e28b24c4edd9e9' \
  'device/oneplus/sm8350-common 8e8157557548dfa3494335092af097fea2903df2' \
  'hardware/oplus 9ed73330d06ad8ef3aa4595f6ee49837928dfda6' \
  'kernel/oneplus/sm8350 f96127f51a9a5cda38dd1b938d68d0c0593f3844' \
  'hardware/pixelworks/interfaces d6d115740b25af00c3cf4fd9a580490a761d9372' \
  'vendor/oneplus/sm8350-common 6297e5b930f2a200199814e87866d515f0775d7b' \
  'vendor/realme/lunaa 091d584924b7174b54dc2ed8f0f3e6fd3a307a06'
do
  set -- $spec
  test "$(git -C "$1" rev-parse HEAD)" = "$2" || exit 1
done
```

在应用任何patch前强制要求全树干净：

```bash
repo forall -e -c '
  test -z "$(git status --porcelain)" || {
    echo "DIRTY: $REPO_PATH" >&2
    git status --short >&2
    exit 1
  }
'
```

不要只查看 `repo status`后继续；任一已有tracked或untracked文件都可能污染复刻结果。

### 5. 应用最终源码修改

#### 5.1 最终修改涉及的项目

- `build/soong`
- `hardware/oplus`
- `kernel/configs`
- `kernel/oneplus/sm8350`
- `vendor/oneplus/sm8350-common`
- `vendor/realme/lunaa`
- `vendor/lineage`

#### 5.2 tracked diff不能直接在源码根一次性应用

归档diff包含多个 `### PROJECT ...`段，每段路径相对各自Git项目。可以使用以下脚本拆分并逐项目应用：

```bash
ROOT=$SRC_ROOT
INPUT=/path/to/droidspaces-final-tracked-20260825.diff
PATCH_DIR=/tmp/droidspaces-final-patches

rm -rf "$PATCH_DIR"
mkdir -p "$PATCH_DIR"

python3 - "$ROOT" "$INPUT" "$PATCH_DIR" <<'PY'
from pathlib import Path
import subprocess, sys

root = Path(sys.argv[1])
src = Path(sys.argv[2]).read_text().splitlines(keepends=True)
out = Path(sys.argv[3])

sections = {}
project = None
for line in src:
    if line.startswith("### PROJECT "):
        project = line.removeprefix("### PROJECT ").strip()
        sections[project] = []
    elif project is not None:
        sections[project].append(line)

for project, lines in sections.items():
    patch = out / (project.replace("/", "__") + ".patch")
    patch.write_text("".join(lines))
    subprocess.run(["git", "-C", str(root / project),
                    "apply", "--check", str(patch)], check=True)

for project in sections:
    patch = out / (project.replace("/", "__") + ".patch")
    subprocess.run(["git", "-C", str(root / project),
                    "apply", str(patch)], check=True)
PY
```

#### 5.3 安全提取Kernel新增文件

Kernel未跟踪归档包含两个不应恢复的条目：

- 一个由终端文本误生成的异常文件；
- `include/linux/sched.h.orig`。

不得把tar直接解压到Kernel树。只复制以下allowlist：

```bash
ROOT=$SRC_ROOT
KERNEL="$ROOT/kernel/oneplus/sm8350"
ARCHIVE=/path/to/droidspaces-full-preflight-kernel-untracked.tar.gz
TMP=$(mktemp -d)
tar -xzf "$ARCHIVE" -C "$TMP"

files=(
  Documentation/dev-tools/kfence.rst
  arch/arm64/include/asm/kfence.h
  arch/x86/include/asm/kfence.h
  include/linux/kfence.h
  include/trace/events/error_report.h
  kernel/trace/error_report-traces.c
  lib/Kconfig.kfence
  mm/kfence/Makefile
  mm/kfence/core.c
  mm/kfence/kfence.h
  mm/kfence/kfence_test.c
  mm/kfence/report.c
  scripts/as-version.sh
)

for file in "${files[@]}"; do
  test -f "$TMP/$file" || exit 1
  mkdir -p "$KERNEL/$(dirname "$file")"
  cp -a "$TMP/$file" "$KERNEL/$file"
done
chmod +x "$KERNEL/scripts/as-version.sh"
rm -rf "$TMP"
```

#### 5.4 修改逻辑摘要

##### Droidspaces Kernel 5.4 kABI

官方来源记录：Droidspaces-OSS `main` SHA：

```text
dfb6eca9255b1691b3ec0f230365daa0aae80f03
```

- SYSVIPC使用 `6_7_8` kABI reserve变体。
- 将 `task_struct` 的 `sysvsem/sysvshm`放入 `ANDROID_KABI_RESERVE(6/7/8)`。
- POSIX mqueue patch需适配本树只有 `ANDROID_KABI_RESERVE(1/2)`的 `user_struct`。
- `mq_bytes`使用reserve 1，reserve 2保留。

##### 有效defconfig

```text
kernel/oneplus/sm8350/arch/arm64/configs/vendor/lahaina-qgki_defconfig
```

最终必需/推荐配置：

```text
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
CONFIG_DEVTMPFS=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_USER_NS=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP_SET=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_TMPFS_XATTR=y
CONFIG_IP_NF_TARGET_REJECT=y
```

本5.4树没有 `CONFIG_NETFILTER_XT_TARGET_REJECT`，实际使用 `CONFIG_IP_NF_TARGET_REJECT=y`。

##### FCM补齐

```text
CONFIG_AS_IS_LLVM=y
CONFIG_NET_SCH_TBF=y
CONFIG_KFENCE=y
CONFIG_KFENCE_SAMPLE_INTERVAL=0
```

- assembler detection backport来源提交：`9c8324ac4b78d042a3346a1a859a62aad8d16711`。
- KFENCE为LineageOS sm8350的47提交累计backport；原记录只固定了范围首尾，逐提交清单未单独保存。

##### FCM 7目录映射

真正生成Android 5.4 FCM 7要求的是：

```text
kernel/configs/t/android-5.4/android-base.config
```

最终状态：

```bash
grep -qx 'CONFIG_SYSVIPC=y' \
  kernel/configs/t/android-5.4/android-base.config

grep -qx '# CONFIG_SYSVIPC is not set' \
  kernel/configs/r/android-5.4/android-base.config
```

这是自定义Droidspaces FCM policy，不能宣称符合未经修改的原始FCM 7策略。

##### lunaa快照兼容修复

- 删除7个已过期的Oplus `ndk_platform` prebuilt声明。
- ALS改用Android 16 `SecureLayerMode::Capture`。
- Oplus Optiga私有函数 `sha256`重命名为 `optiga_sha256`。
- boot jar allowlist增加 `net\.oneplus\.odm`与 `oplus\.content\.res`。
- 补入TBF、assembler detection和KFENCE backport。

这些是当前revision组合的修复，不应盲目应用到未来版本。

#### 5.5 相对OUT的Kernel O=修复

相对 `OUT_DIR=out-droidspaces-full`会被Kbuild相对 `make -C kernel/...`解析，导致错误嵌套目录和错误 `.config`。

正确修复位于：

```text
vendor/lineage/config/BoardConfigKernel.mk
```

核心逻辑：

```make
OUT_DIR_PREFIX := $(shell echo $(OUT_DIR) | sed -e 's|/target/.*$$||g')
KERNEL_BUILD_OUT_PREFIX :=
ifeq ($(filter /%,$(OUT_DIR_PREFIX)),)
    KERNEL_BUILD_OUT_PREFIX := $(BUILD_TOP)/
endif
```

- 相对OUT：加 `$(BUILD_TOP)/`。
- 绝对OUT：不重复加前缀。
- 不要把全局 `OUT_DIR`强改成Soong不接受的绝对外部目录。

#### 5.6 源码卫生检查

```bash
for project in \
  build/soong hardware/oplus kernel/configs kernel/oneplus/sm8350 \
  vendor/oneplus/sm8350-common vendor/realme/lunaa vendor/lineage
do
  git -C "$project" diff --check || exit 1
done

expected_untracked=$(cat <<'EOF'
Documentation/dev-tools/kfence.rst
arch/arm64/include/asm/kfence.h
arch/x86/include/asm/kfence.h
include/linux/kfence.h
include/trace/events/error_report.h
kernel/trace/error_report-traces.c
lib/Kconfig.kfence
mm/kfence/Makefile
mm/kfence/core.c
mm/kfence/kfence.h
mm/kfence/kfence_test.c
mm/kfence/report.c
scripts/as-version.sh
EOF
)
actual_untracked=$(git -C kernel/oneplus/sm8350 \
  ls-files --others --exclude-standard | LC_ALL=C sort)
test "$actual_untracked" = "$expected_untracked" || exit 1
```

### 6. 生成graph与预检

```bash
cd $SRC_ROOT

export OUT_DIR=out-droidspaces-full
export USE_CCACHE=1
export CCACHE_EXEC="$(command -v ccache)"
export CCACHE_DIR="$HOME/.cache/ccache"
export PATH="$PWD/prebuilts/jdk/jdk21/linux-x86/bin:$HOME/bin:$PATH"

source build/envsetup.sh
breakfast lunaa
```

> [!WARNING]
> 不要在 `source build/envsetup.sh`前启用 `set -u`。成功脚本使用 `set -eo pipefail`。

先构建Kernel与VINTF预检：

```bash
m -j4 bootimage check_vintf_compatible
```

#### 6.1 Kernel配置断言

```bash
KCONFIG="$OUT_DIR/target/product/lunaa/obj/KERNEL_OBJ/.config"

for config in \
  CONFIG_AS_IS_LLVM=y \
  CONFIG_NET_SCH_TBF=y \
  CONFIG_KFENCE=y \
  CONFIG_KFENCE_SAMPLE_INTERVAL=0 \
  CONFIG_SYSVIPC=y \
  CONFIG_POSIX_MQUEUE=y \
  CONFIG_IPC_NS=y \
  CONFIG_PID_NS=y \
  CONFIG_QCOM_SMEM=y \
  CONFIG_OPLUS_FEATURE_PROJECTINFO=y
do
  grep -qx "$config" "$KCONFIG" || exit 1
done
```

#### 6.2 Kernel OUT graph断言

```bash
python3 - <<'PY'
from pathlib import Path

root = Path.cwd().resolve()
ninja = Path('out-droidspaces-full/build-lineage_lunaa.ninja')
text = ninja.read_text(errors='replace')

absolute = f'O={root}/out-droidspaces-full/target/product/lunaa/obj/KERNEL_OBJ'
relative = 'O=out-droidspaces-full/target/product/lunaa/obj/KERNEL_OBJ'

absolute_count = text.count(absolute)
relative_count = text.count(relative)
if absolute_count < 20 or relative_count != 0:
    raise SystemExit({"absolute": absolute_count, "relative": relative_count})
PY
```

generated headers的 `O=`和 `clean_headers.sh`也必须使用源码根下同一绝对OUT。

#### 6.3 VINTF断言

```bash
VINTF_LOG="$OUT_DIR/target/product/lunaa/obj/PACKAGING/check_vintf_all_intermediates/check_vintf_compatible.log"
tail -n 1 "$VINTF_LOG" | grep -qx COMPATIBLE
```

确认FCM 7的5.4 Kernel要求中至少有一个block声明SYSVIPC，且所有实际声明该key的block都要求 `y`。同一版本的其他增量block可以不重复该key：

```bash
python3 - <<'PY'
import xml.etree.ElementTree as ET

path = ('out-droidspaces-full/target/product/lunaa/'
        'system/etc/vintf/compatibility_matrix.7.xml')
root = ET.parse(path).getroot()
blocks = []
for kernel in root.findall('kernel'):
    if kernel.attrib.get('version', '').startswith('5.4'):
        values = []
        for config in kernel.findall('config'):
            if config.findtext('key') == 'CONFIG_SYSVIPC':
                values.append(config.findtext('value'))
        blocks.append(values)
declaring_blocks = [values for values in blocks if values]
if (not blocks or not declaring_blocks or
        any(values != ['y'] for values in declaring_blocks)):
    raise SystemExit({"CONFIG_SYSVIPC declarations in 5.4 blocks": blocks})
PY
```

#### 6.4 APEX allowed-deps排序门控

本次快照中baseline与生成列表均为1708项，集合完全相同，差异只有排序。

`new-allowed-deps.txt`可能要到完整 `bacon`首次触发该门控时才生成。文件尚不存在时不要自行合成：先继续构建；若且仅若构建在该门控停止，再运行下面的集合检查与规范化，然后重新执行同一构建。

只允许规范化输出树：

```text
out-droidspaces-full/soong/apex/depsinfo/new-allowed-deps.txt
```

禁止修改：

```text
packages/modules/common/build/allowed_deps.txt
```

```bash
python3 - <<'PY'
from pathlib import Path

base = Path('packages/modules/common/build/allowed_deps.txt')
new = Path('out-droidspaces-full/soong/apex/depsinfo/new-allowed-deps.txt')

base_lines = [x for x in base.read_text(errors='replace').splitlines()
              if x and not x.startswith('#')]
new_lines = [x for x in new.read_text(errors='replace').splitlines()
             if x and not x.startswith('#')]

if len(base_lines) != 1708 or len(new_lines) != 1708:
    raise SystemExit({"base_count": len(base_lines), "new_count": len(new_lines)})
if len(set(base_lines)) != len(base_lines):
    raise SystemExit("baseline contains duplicates")
if len(set(new_lines)) != len(new_lines):
    raise SystemExit("generated list contains duplicates")
if set(base_lines) != set(new_lines):
    raise SystemExit("APEX allowed-deps set changed")

new.write_text('\n'.join(base_lines) + '\n')
PY

rm -f out-droidspaces-full/soong/apex/depsinfo/new-allowed-deps.txt.check
```

只要出现新增、删除或重复项，必须停止，不得自动更新baseline。

### 7. 完整构建

推荐脚本：

为避免旧OUT污染，首次复刻应使用一个从未存在过的新 `OUT_REL`。本次构建使用 `out-droidspaces-full`；若复用同名增量OUT，只能称为恢复构建，不能作为干净复刻证据。

```bash
#!/usr/bin/env bash
set -eo pipefail

ROOT=$SRC_ROOT
OUT_REL=out-droidspaces-full
LOG="$ROOT/droidspaces-full-build.log"
EXIT_FILE="$ROOT/droidspaces-full-build.exit"

cd "$ROOT"
rm -f "$EXIT_FILE"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; printf "%s\n" "$rc" > "$EXIT_FILE"; exit "$rc"' EXIT

export OUT_DIR="$OUT_REL"
export USE_CCACHE=1
export CCACHE_EXEC="$(command -v ccache)"
export CCACHE_DIR="$HOME/.cache/ccache"
export PATH="$ROOT/prebuilts/jdk/jdk21/linux-x86/bin:$HOME/bin:$PATH"

source build/envsetup.sh
breakfast lunaa
m -j4 bacon
```

后台运行：

```bash
tmux new-session -d -s droidspaces-full-build \
  '$SRC_ROOT/run-droidspaces-full-build.sh'
```

成功条件：

```bash
test "$(cat $SRC_ROOT/droidspaces-full-build.exit)" = 0
```

> [!NOTE] `repo` 2.66+ 与 Ninja 只读沙箱
> `scripts/60-build.sh` 会在启动 `bacon` 前把 resolved manifest 导出到
> `$OUT_DIR/reproducibility/resolved-manifest-before-build.xml`。这不仅保存本次
> 源码身份，也会在可写环境中预热 `repo` 的 Git-config JSON 缓存。否则
> LineageOS 生成 `build-manifest.xml` 时可能在 Ninja 只读沙箱内尝试写入
> `~/.repo_.gitconfig.json`，并以 `Read-only file system` 失败。不要用
> `BUILD_BROKEN_SRC_DIR_IS_WRITABLE := true` 放宽整个源码树来绕过该问题。

> [!NOTE]
> 归档的attempt 7脚本直接运行已生成Ninja graph，是多次增量修复后的成功恢复脚本。全新环境应优先通过 `envsetup + breakfast + m`生成graph，不应假设旧graph存在。

### 8. 补建target-files与images ZIP

本分支 `bacon`成功后没有自动留下后处理要求的官方target-files ZIP。使用实际Ninja目标补建：

```bash
cd $SRC_ROOT
OUT=out-droidspaces-full
GRAPH="$OUT/combined-lineage_lunaa.ninja"
TARGET="$OUT/target/product/lunaa/obj/PACKAGING/target_files_intermediates/lineage_lunaa-target_files.zip"

prebuilts/build-tools/linux-x86/bin/ninja \
  -f "$GRAPH" -j4 "$TARGET"
```

生成images ZIP：

```bash
mapfile -t OTAS < <(compgen -G \
  "$OUT/target/product/lunaa/lineage-23.2-*-UNOFFICIAL-lunaa.zip")
test "${#OTAS[@]}" -eq 1 || {
  printf 'Expected exactly one OTA, found %s\n' "${#OTAS[@]}" >&2
  exit 1
}
OTA="${OTAS[0]}"
IMAGE_ZIP="$OUT/target/product/lunaa/$(basename "${OTA%.zip}")-images.zip"

"$OUT/host/linux-x86/bin/img_from_target_files" \
  "$TARGET" "$IMAGE_ZIP"
```

完整性：

```bash
unzip -t "$TARGET"
unzip -t "$IMAGE_ZIP"
```

### 9. 正确的构建后审计

#### 9.1 必须进入总状态的项目

```text
build_exit
ota_zip_test
ota_signature_check
target_files_zip_test
vintf_check
image_zip_generation
image_zip_test
avb_parse_boot
avb_parse_dtbo
avb_parse_vendor_boot
avb_parse_vbmeta
avb_parse_vbmeta_system
avb_parse_vbmeta_vendor
avb_verify_boot
avb_verify_dtbo
avb_verify_vendor_boot
avb_verify_chain
archive_sha256_verify
postbuild_exit
```

任何状态缺失、非0或工具缺失，都不得标记为完全审计成功。

#### 9.2 OTA与payload签名

```bash
ROOT=$SRC_ROOT
cd "$ROOT"
HOST="$ROOT/out-droidspaces-full/host/linux-x86/bin"
TARGET="$ROOT/out-droidspaces-full/target/product/lunaa/obj/PACKAGING/target_files_intermediates/lineage_lunaa-target_files.zip"
mapfile -t OTAS < <(compgen -G \
  "$ROOT/out-droidspaces-full/target/product/lunaa/lineage-23.2-*-UNOFFICIAL-lunaa.zip")
test "${#OTAS[@]}" -eq 1 || exit 1
OTA="${OTAS[0]}"

unzip -p "$OTA" META-INF/com/android/otacert > otacert.x509.pem
"$HOST/check_ota_package_signature" otacert.x509.pem "$OTA"
```

输出必须同时包含：

```text
Whole package signature VERIFIED
Payload signatures VERIFIED
```

#### 9.3 target-files VINTF

```bash
"$HOST/check_target_files_vintf" "$TARGET"
test "$?" -eq 0
```

#### 9.4 修正后的AVB解析与密码学验证

不要写：

```bash
python3 "$HOST/avbtool" ...
```

`info_image`只解析元数据，不验证签名或镜像数据。必须从最终images ZIP提取实际刷写镜像，先解析，再以预期key执行 `verify_image`。

归档根目录还有另一套同名镜像；其中7个条目与最终images ZIP不同，不得拿根目录镜像替代实际刷写集做结论。

本次test-key构建的模板：

```bash
AVB="$HOST/avbtool"
test -x "$AVB"
KEY="$ROOT/external/avb/test/data/testkey_rsa4096.pem"
test -f "$KEY"

IMAGE_ZIP=/absolute/path/to/lineage-23.2-20260825-UNOFFICIAL-lunaa-images.zip
IMAGES=$(mktemp -d)
AUDIT=/absolute/path/to/avb-audit
mkdir -p "$AUDIT"
unzip -q "$IMAGE_ZIP" -d "$IMAGES"

for image in \
  boot.img dtbo.img vendor_boot.img \
  vbmeta.img vbmeta_system.img vbmeta_vendor.img
do
  "$AVB" info_image --image "$IMAGES/$image" \
    > "$AUDIT/avb-$image.txt" || exit 1
done

for image in boot.img dtbo.img vendor_boot.img; do
  "$AVB" verify_image --image "$IMAGES/$image" --key "$KEY" \
    > "$AUDIT/verify-$image.txt" 2>&1 || exit 1
done

"$AVB" verify_image \
  --image "$IMAGES/vbmeta.img" \
  --key "$KEY" \
  --expected_chain_partition "vbmeta_system:2:$KEY" \
  --expected_chain_partition "vbmeta_vendor:5:$KEY" \
  --follow_chain_partitions \
  > "$AUDIT/verify-vbmeta-chain.txt" 2>&1 || exit 1
```

> [!WARNING]
> `vbmeta_system`、`vbmeta_vendor`、rollback location及key路径必须先从当前 `info_image`和 `META/misc_info.txt`确认，不能在新源码或私钥版本中照抄。私钥版本必须为每个信任域提供对应预期key材料。

额外检查：

- algorithm和公钥；
- rollback index与location；
- chained partition；
- hash/hashtree descriptors；
- vbmeta flags；
- boot/vendor_boot/dtbo fingerprint和patch-level props；
- `system/system_ext/product/vendor/odm/vendor_dlkm`数据是否经follow-chain验证；
- `verify_image`成功只证明镜像与预期key/descriptor一致，不证明解锁bootloader会强制执行验证。

#### 9.5 SHA-256

```bash
sha256sum "$OTA" "$TARGET" "$IMAGE_ZIP" > SHA256SUMS
sha256sum -c SHA256SUMS
```

### 9.6 生成公开 Kernel-only Release 包

只有 `scripts/60-build.sh`、`scripts/70-package.sh` 和 `scripts/80-audit.sh`
全部成功，且审计目录以原子方式生成后，才能运行：

```bash
ROOT=$SRC_ROOT \
OUT_REL=out-droidspaces-full \
AUDIT_DIR="$SRC_ROOT/droidspaces-audit" \
BUILD_EXIT_FILE="$SRC_ROOT/droidspaces-full-build.exit" \
POSTBUILD_EXIT_FILE="$SRC_ROOT/droidspaces-postbuild.exit" \
EXPECTED_KERNEL_COMMIT=9da4bdfa0e5d73fce8ae282a2898d054dcd2df80 \
KERNEL_SOURCE_URL=https://github.com/cottonthread/android_kernel_oneplus_sm8350/commit/9da4bdfa0e5d73fce8ae282a2898d054dcd2df80 \
bash scripts/90-package-kernel-release.sh
```

`80-audit.sh` 会安全解析 `70-package.sh` 生成的三键数据清单，不执行其中内容；
只有在 build/postbuild 两个独立 exit 文件均真实为0且所有检查成功后，才以
`RENAME_NOREPLACE` 原子发布审计目录。schema v2 attestation 绑定 Kernel commit、
OTA、target-files、images ZIP、两种 `boot.img`、Kernel `Image`、最终 config、
resolved manifest、固定 AVB 公钥及证据文件、两个 exit 文件和20项审计账本。
发布模式拒绝通过环境变量覆盖 AVB key 或其固定摘要。

最终可分发 `boot.img` 取自已审计的 images ZIP，并必须与 target-files 内的
`IMAGES/boot.img` 字节完全一致。产品目录的 `boot.img` 是中间产物，releasetools
会重组其 ramdisk，因此不要求两份 boot 整体相同；但两者内嵌 Kernel 都必须与
公开包中的 `Image` 字节完全一致。

`90-package-kernel-release.sh` 会拒绝：

- 缺失、非零、重复、未知或顺序错误的20项审计账本；
- 与当前归档、boot、Image、config、manifest、两个 exit 文件、公开审计证据、AVB key 或 ledger 不一致的 schema v2 attestation；
- 带 `-dirty` 的 Kernel release；
- 不是 `android@repro-build` 的 Kernel 编译身份；
- 未通过完整 preflight 配置门禁的最终 `.config`；
- 不干净或不匹配指定精确 commit 的 Kernel 工作树；
- images ZIP 与 target-files 中不一致的分发 boot；
- 内嵌 Kernel 与 `Image` 不一致，或无法以固定 AOSP test key 验证的 boot；
- ramdisk 中不安全路径、Magisk、ADB key、授权 key、常见私钥或凭据标记；
- 无法完整解析的串接 cpio archive，以及 trailer 后无法解释的非零数据；
- 已存在的普通文件、目录或 dangling symlink 形式的同名发布资产。

公开 ZIP 只包含：

- 与本次 ROM build 精确匹配、未经 Magisk 修补的分发 `boot.img`；
- 原始 arm64 `Image`；
- 最终 `kernel.config` 与 `resolved-manifest.xml`；
- 精确源码、构建身份、boot/Image 绑定、ramdisk 清单与 AVB 证据；
- 完整固件审计账本、attestation、安装边界和包内 `SHA256SUMS`。

ZIP 会先在 release 目录同一文件系统中生成并完整解压复核。脚本把 ZIP 与
`.sha256` 放入同一个私有暂存目录并再次验签，然后以
`renameat2(RENAME_NOREPLACE)` 将完整目录一次性原子发布。中断不会留下单边资产，
并且任何既有同名发布目录都不会被覆盖。

> [!WARNING] 安装与Root边界
> 此包不是 AnyKernel 包，也没有在任意 ROM 上做通用兼容验证。刷入未修补的
> `boot.img` 会替换当前 boot，包括现有 Magisk 修补。需要 root 的用户应自行
> 使用可信的 Magisk 安装对**该精确 `boot.img`**重新修补并验证。项目不分发
> Magisk 预修补镜像。AOSP test-key 构建不得作为安全重锁 bootloader 的依据。

> [!IMPORTANT] 不公开完整固件归档
> `70-package.sh` 和 `80-audit.sh` 所需的 OTA、target-files 与 images ZIP 只用于
> 离线完整性、VINTF、FCM、签名和 AVB chain 审计；它们包含 proprietary vendor
> 内容，不作为公开 Release 资产上传。

### 10. 长期日用的私有release keys阶段

> [!CAUTION] 当前没有已验证的lunaa私钥签名实现
> 以下是必须完成的设计阶段，不是可以盲目复制的发布命令。本次成功固件仍使用AOSP test keys。

#### 10.1 先盘点所有签名域

从target-files读取：

```text
META/apkcerts.txt
META/apexkeys.txt
META/misc_info.txt
META/otakeys.txt
```

至少规划：

- platform；
- release/OTA；
- shared；
- media；
- networkstack；
- 每个APEX key；
- Recovery OTA trust；
- AVB boot、dtbo、vendor_boot、vbmeta、vbmeta_system、vbmeta_vendor等key。

#### 10.2 密钥原则

- 离线生成、强密码保护；
- 私钥不放入源码树、Git、Vault或公开日志；
- 至少两份分离的加密备份；
- 后续OTA永久沿用同一身份；
- 不建议所有信任域共用同一私钥。

#### 10.3 target-files重签模板

```text
HOST=out-droidspaces-full/host/linux-x86/bin
KEY_DIR=/secure/offline/android-release-keys

"$HOST/sign_target_files_apks" \
  -o \
  -d "$KEY_DIR" \
  unsigned-target_files.zip \
  signed-target_files.zip

"$HOST/ota_from_target_files" \
  -k "$KEY_DIR/releasekey" \
  signed-target_files.zip \
  signed-ota.zip
```

此模板未包含lunaa每个AVB partition的最终key映射，正式使用前必须完成并验证该映射。

该代码块是设计伪代码，不是可直接发布的命令。必须先枚举全部APK/APEX映射、OTA/Recovery证书和AVB key override，并在signed target-files中逐项检查证书与key digest。

#### 10.4 当前AVB策略特别警告

当前 `META/misc_info.txt`包含：

```text
avb_vbmeta_args=--set_hashtree_disabled_flag --set_verification_disabled_flag --padding_size 4096
```

因此：

- 换成私有key不等于恢复完整验证；
- 解锁bootloader仍会显示Verified Boot orange；
- 自定义root of trust和重锁能力没有验证；
- 不得直接尝试重锁bootloader。

#### 10.5 从test keys迁移

若旧安装确实使用已归档证书指纹所对应的pjgowtham release identity，则从该identity到AOSP testkey、再到用户私有key，可能造成系统应用签名和userdata权限数据库冲突。不能仅凭运行时 `user/release-keys` spoofed fingerprint判断签名身份。

建议：

1. 完整备份数据；
2. 在非主槽或备用设备验证私有签名构建；
3. 为首次迁移准备干净userdata初始化；
4. 后续永不更换私钥身份，除非实施经过验证的key rotation方案。

### 11. 可选真机安装阶段

> [!CAUTION]
> 本节不是构建成功的必要步骤。没有用户对精确设备、槽位和wipe边界的明确授权时，禁止执行。

#### 11.1 安装前检查

- serial唯一且匹配；
- product为 `lahaina`；
- 当前槽为已知良好救援槽；
- 救援槽successful且非unbootable；
- Bootloader已解锁；
- 电量充足；
- 已备份救援槽启动链、metadata及raw super；
- images ZIP通过SHA-256。

> [!WARNING]
> dynamic partition metadata和内容位于共享 `super`。目标槽参数不能提供完整物理隔离；槽B只能视为尽力而为的救援入口，极端失败可能需要raw super恢复。

#### 11.2 本次成功命令

```bash
fastboot -s SERIAL \
  --slot a \
  --skip-secondary \
  --skip-reboot \
  update lineage-23.2-20260825-UNOFFICIAL-lunaa-images.zip
```

禁止添加：

```text
-w
--force
--disable-verity
--disable-verification
```

写入后、首次重启前：

- 确认目标槽没有unbootable；
- 读取并比对救援槽启动链哈希；
- 失败时只切回救援槽，不修写救援槽。

这里的“首次重启前”是指最终Android启动前。`fastboot update`本身可能在bootloader与fastbootd之间内部重启；`--skip-reboot`只阻止完成后的最终重启。若shared super metadata受损，仅切槽可能不足。

本次槽B安装后哈希保持来自当时会话中的root分区回读，但当前归档没有单独保存六项post-install哈希对照文件。新的自动流程必须把回读值、预期值和比较结果写入独立日志。

#### 11.3 Droidspaces userspace

若固件只包含兼容Kernel，还需要：

- Magisk或另一套经过验证的root方案；
- Droidspaces应用；
- Droidspaces daemon/init模块；
- `droidspaces check`；
- 实际容器生命周期测试。

### 12. 人工复刻完成清单

- [ ] resolved manifest与预期一致
- [ ] tracked diff逐项目应用成功
- [ ] Kernel新增文件只从allowlist恢复
- [ ] 七个项目 `git diff --check`通过
- [ ] Kernel必需config全部存在
- [ ] Kernel `O=`没有嵌套相对OUT
- [ ] APEX集合无新增/删除，只处理排序
- [ ] VINTF日志末行为 `COMPATIBLE`
- [ ] `bacon`退出0
- [ ] target-files和images ZIP生成成功
- [ ] OTA/payload签名通过
- [ ] target-files VINTF退出0
- [ ] 从最终images ZIP提取镜像，AVB解析与 `verify_image`均成功并进入状态表
- [ ] 所有最终产物SHA-256已保存并复核
- [ ] test-key或release-key安全级别已明确记录

---

## 第二部分：Codex/自动化机器人复刻版

### 13. 机器人任务契约

#### 13.1 输入变量

```text
ROOT=$SRC_ROOT
OUT_REL=out-droidspaces-full
PRODUCT=lineage_lunaa
DEVICE=lunaa
BUILD_JOBS=4
INPUT_DIR=<manifest/diff/kernel-untracked归档所在目录>
ARCHIVE=<最终产物目录>
```

机器人必须先验证所有输入是绝对路径、目录存在且位于允许的sandbox内。

#### 13.2 不可自动决定的事项

- 是否修改源码树中用户已有变更；
- 是否生成或读取私有key；
- 是否连接手机；
- 是否flash、切槽或wipe；
- 是否覆盖已知良好槽；
- 是否接受FCM、APEX或AVB策略偏差。

遇到以上事项必须停止并请求明确授权。

### 14. 机器人阶段状态机

| 阶段 | 必须断言 | 停止条件 | 产物 |
|---|---|---|---|
| P0 输入冻结 | manifest/diff/tar及SHA存在 | 缺文件、哈希不符 | 输入报告 |
| P1 主机预检 | Linux x86_64、依赖、空间、RAM/swap、ext4 | 资源不足、OUT在DrvFS | 环境报告 |
| P2 源码同步 | 全部revision可解析 | 任一project缺失或HEAD不符 | resolved manifest |
| P3 修改应用 | patch check与allowlist成功 | patch冲突、异常未跟踪文件 | per-project diff |
| P4 源码卫生 | 全部 `git diff --check=0` | 空白错误或意外项目变更 | 状态清单 |
| P5 Graph/OUT | Kernel `O=`为源码根绝对OUT | 旧相对嵌套路径非0 | graph审计 |
| P6 Kernel | 所有必需config存在 | olddefconfig丢配置、链接缺符号 | `.config`报告 |
| P7 APEX | 集合完全相同 | 新增、删除、重复、baseline被改 | 集合差异报告 |
| P8 VINTF | 5.4 SYSVIPC全为y且COMPATIBLE | 任一mismatch | matrix与日志 |
| P9 完整构建 | `BUILD_EXIT=0` | Ninja/OOM/I/O/空间失败 | OTA与完整日志 |
| P10 target-files | 官方target ZIP和images ZIP完整 | ZIP缺失或测试失败 | 两个ZIP |
| P11 签名审计 | OTA、payload、VINTF全为0 | 工具缺失或状态缺项 | 审计日志 |
| P12 AVB | 最终images ZIP的 `info_image`与 `verify_image`全部退出0 | 错镜像集、Python误调用、`|| true`、key/descriptor异常 | AVB解析与验证报告 |
| P13 SHA归档 | 所有产物哈希复核 | 任一不一致 | `SHA256SUMS` |
| P14 设备阶段 | 用户单独授权且救援备份完成 | 槽位/serial/备份不符 | 设备预检；默认不执行 |

### 15. 机器人强制断言

#### 15.1 输入哈希

```bash
test "$(sha256sum "$INPUT_DIR/droidspaces-full-preflight-manifest-20260824.xml" | awk '{print $1}')" = \
  72905b805c5d094c363fe7d78e032dd8bafceff1ae0948bd98eb049f6e0f8513

test "$(sha256sum "$INPUT_DIR/droidspaces-final-tracked-20260825.diff" | awk '{print $1}')" = \
  ed33681e0252513f1b0640d122a6058d6308366d8715c64e80820e5d2ba11b01

test "$(sha256sum "$INPUT_DIR/droidspaces-full-preflight-kernel-untracked.tar.gz" | awk '{print $1}')" = \
  d3d4bb8e14ee20555b84f30530e625514b28060fd8f9b03799c0ef085f98c121
```

#### 15.2 路径与资源

```bash
test -d "$ROOT/.repo"
test "$(stat -f -c %T "$ROOT")" = ext2/ext3
test "$(free -b | awk '/^Swap:/ {print $2}')" -ge 42949672960
test "$(df -PB1 "$ROOT" | awk 'NR==2 {print $4}')" -ge 429496729600
```

资源阈值是本次WSL保守值；调整必须由用户明确批准并记录。

#### 15.3 修改白名单

机器人只允许预期项目发生源码修改：

```text
build/soong
hardware/oplus
kernel/configs
kernel/oneplus/sm8350
vendor/oneplus/sm8350-common
vendor/realme/lunaa
vendor/lineage
```

其他project出现修改时停止。

#### 15.4 构建退出码

- tmux session消失不等于构建成功。
- 必须读取独立exit文件。
- exit文件缺失视为状态未知，不得归档为成功。

### 16. 机器人监控策略

构建放在detached tmux，监控器只读：

```bash
while tmux has-session -t droidspaces-full-build 2>/dev/null; do
  date
  free -h
  df -h "$ROOT"
  stat -c 'log_size=%s' "$ROOT/droidspaces-full-build.log" 2>/dev/null || true
  tail -n 3 "$ROOT/droidspaces-full-build.log" 2>/dev/null || true
  sleep 300
done
```

原则：

- 远离结束阶段：5分钟一次；
- 接近打包、签名或失败点：1分钟一次；
- 不用短timeout杀死前台构建；
- 不因日志暂时无输出重启任务。

### 17. 机器人审计状态文件

建议格式：

```text
build_exit=0
ota_zip_test=0
ota_signature_check=0
target_files_zip_test=0
vintf_check=0
image_zip_generation=0
image_zip_test=0
avb_parse_boot=0
avb_parse_dtbo=0
avb_parse_vendor_boot=0
avb_parse_vbmeta=0
avb_parse_vbmeta_system=0
avb_parse_vbmeta_vendor=0
avb_verify_boot=0
avb_verify_dtbo=0
avb_verify_vendor_boot=0
avb_verify_chain=0
archive_sha256_verify=0
postbuild_exit=0
```

状态解析器必须满足：

- 所有预期key存在；
- 所有值为0；
- `TOOL_MISSING`、空值和缺项都算失败；
- 禁止 `|| true`绕过强制审计。

### 18. 机器人禁止事项

- 禁止跳过 `checkvintf`。
- 禁止修改 `r/android-5.4`冒充FCM 7修复。
- 禁止把自定义matrix描述成原始Android FCM合规。
- 禁止在APEX集合不同的情况下自动更新baseline。
- 禁止把全局OUT改成Soong不接受的绝对外部目录。
- 禁止在 `source envsetup.sh`前启用 `set -u`。
- 禁止盲目解压Kernel未跟踪归档。
- 禁止把失败归档标记为成功。
- 禁止用Python执行host `avbtool`二进制。
- 禁止把 `info_image`元数据解析描述成密码学验证。
- 禁止审计归档根目录镜像后推断最终images ZIP内刷写镜像已通过。
- 禁止吞掉签名、VINTF、AVB或哈希失败。
- 禁止把boot-format镜像写入vendor_boot。
- 禁止混搭不同构建的启动链和动态分区。
- 禁止自动连接或写手机。
- 禁止修改救援槽。
- 禁止自动Factory reset、wipe userdata或metadata。
- 禁止读取、输出、上传或提交release private keys。
- 禁止把metadata镜像、KeyMint材料或用户数据放入公开归档。

### 19. 机器人最终报告模板

```markdown
## Build identity
- Manifest SHA-256:
- Source diff SHA-256:
- Kernel extra-files SHA-256:
- Build start/end:
- Host resources:

## Outputs
- OTA path/size/SHA-256:
- Target-files path/size/SHA-256:
- Images ZIP path/size/SHA-256:

## Mandatory checks
- Kernel config:
- OUT graph:
- APEX set equality:
- VINTF:
- OTA/payload signature:
- AVB:
- ZIP tests:
- SHA verification:

## Security classification
- test-keys or release-keys:
- AVB flags:
- Bootloader assumptions:
- Known audit gaps:

## Device actions
- Performed: no / yes with explicit approval reference
- Target slot:
- Rescue boot-chain readback and shared-super changes:
- Wipe performed: no / yes with separate approval

## Remaining risks
- Stability:
- Signing continuity:
- Droidspaces userspace/container lifecycle:
```

### 20. 不能从现有记录完全确认的内容

- 原执行记录所称Droidspaces-OSS SYSVIPC/POSIX patch的原始文件名、下载URL和逐条应用命令没有完整保存。
- 原执行记录所称47个KFENCE commit的逐项列表没有单独保存，只保存了最终修改和新增文件。
- Kernel未跟踪归档包含两个无效条目，必须使用本指南allowlist。
- 原后处理没有完成有效的独立AVB审计。
- 私有release keys、每个AVB partition的key映射、Recovery key迁移和OTA key rotation尚未实际实施。
- 没有证明Droidspaces userspace被嵌入固件；真机使用的是userdata中已有模块。
- 自定义AVB root of trust、green Verified Boot和安全重锁bootloader均未验证。

> [!TIP] 复刻完成定义
> 只有在源码身份、Kernel/FCM、OUT graph、APEX、VINTF、完整构建、target-files、OTA/payload签名、最终刷写镜像集的AVB解析与密码学验证、SHA-256全部通过后，才能称为“完整固件生成与独立审计成功”。真机安装和长期稳定性是后续独立阶段。
