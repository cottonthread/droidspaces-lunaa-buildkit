# 验证摘要（公开版）

本文件只保留可复核的技术结论；原始命令记录、主机路径、设备唯一标识和本地归档信息不随公开版发布。

## 构建范围

- 设备：Realme GT Master Edition（lunaa / RMX3360）。
- 基线：LineageOS 23.2 / Android 16，冻结 revision 见 [`../manifests/frozen-20260825.xml`](../manifests/frozen-20260825.xml)。
- Kernel：基于 pjgowtham 的 `android_kernel_oneplus_sm8350` 固定 revision，并应用本仓库的 Kernel patch 与 overlay。
- 构建类型：`userdebug/test-keys` 研究构建；私有 release-key 身份和安全重锁不在已验证范围内。

## 2026-08-26 公开身份重建（历史离线审计）

使用通用 Android/Kernel 构建身份和独立 OUT 完成了完整构建、打包与修正后的构建后审计。以下哈希只标识本地验证产物；本仓库当前不分发这些含 proprietary vendor 内容的完整归档。

| 产物 | 大小（字节） | SHA-256 |
|---|---:|---|
| `lineage-23.2-20260826-UNOFFICIAL-lunaa.zip` | `1925832722` | `58a40ba5d7ecd0b3c7daabb8fc53c39ed63d4641f304284039559e7da04fedfd` |
| `lineage_lunaa-target_files.zip` | `4435556997` | `78d1d0e1f5980f67cb305762009af85a349a970244330839132f50fe1c7b9eae` |
| `lineage-23.2-20260826-UNOFFICIAL-lunaa-images.zip` | `2309737068` | `d16967e09d8ad0d7ad1f5b90ccc268461e7f07bf8b81ead56a23c048d28ff64f` |

强制审计账本共19项，全部为0；额外的FCM SYSVIPC断言也通过。已完成：

- OTA、target-files和images ZIP完整性测试；
- OTA whole-package及A/B payload签名验证；
- target-files VINTF检查；
- FCM 7的Android 5.4要求中，所有实际声明的`CONFIG_SYSVIPC`值均为`y`；
- 从最终images ZIP提取`boot`、`dtbo`、`vendor_boot`、`vbmeta`、`vbmeta_system`和`vbmeta_vendor`进行AVB元数据解析；
- 以预期AOSP test key验证`boot`、`dtbo`、`vendor_boot`及完整vbmeta chain；
- 三个最终归档的SHA-256生成与复核。

上述AVB结论证明最终镜像与预期test key及descriptor一致，不证明解锁bootloader会强制执行验证，也不证明可以安全重锁。

## 2026-08-28 Kernel-only Release 构建与离线审计

使用冻结源码、全新 OUT 和通用 Android/Kernel 构建身份完成了公开 Kernel-only
Release 的构建及离线审计。Kernel 源码固定为精确 commit
[`9da4bdfa0e5d73fce8ae282a2898d054dcd2df80`](https://github.com/cottonthread/android_kernel_oneplus_sm8350/commit/9da4bdfa0e5d73fce8ae282a2898d054dcd2df80)。

- Kernel release：`5.4.302-qgki-g9da4bdfa0e5d`，无 `-dirty`。
- Kernel 编译身份：`android@repro-build`。
- 完整 build 与 postbuild exit 均为0，20项审计账本全部为0。
- OTA、target-files 与 images ZIP 的 SHA-256 分别为
  `a945fd383607288d079896c82d5085a18200f5f940abd0070e380539ab4eac76`、
  `ac92d9d17a5556d7f450ba68965a9639db38591135e6169996ea68e3ad5275e4`、
  `4b9f233e895754520f99f6a800e41316ada62bb57f81f940ff496e82de985265`。
- 分发 `boot.img` 同时来自 images ZIP 与 target-files，SHA-256 为
  `618fb69e7ce0d71097542638936c3dd2aa4a1ae1da1c48949e3982c5105d6b81`。
- 分发 boot 和产品中间 boot 的内嵌 Kernel 均与公开 `Image` 字节一致；
  `Image` SHA-256 为 `c3279b9bd45d900b847b3c7e6baa70a2f72bee113627284484d4f4c90d8d26ad`。
- AVB 使用固定的 AOSP test-key 公钥身份，公钥摘要为
  `7728e30f50bfa5cea165f473175a08803f6a8346642b5aa10913e9d9e6defef6`。
- v1 attestation 仅保留为历史诊断证据，不用于发布。修订后的 `80-audit.sh`
  已成功生成 schema v2 attestation；v2 还绑定 Kernel commit、最终 config、
  resolved manifest、两个 exit 文件、boot binding、AVB 摘要证据与审计账本。
- schema v2 审计独立 exit 为0，20项账本全部为0；审计目录以
  `RENAME_NOREPLACE` 原子、no-clobber 发布。
- 最终 Kernel-only ZIP 为
  `droidspaces-lunaa-kernel-5.4.302-qgki-g9da4bdfa0e5d-20260828.zip`，大小
  `42,413,354` 字节，SHA-256 为
  `3242507af2af005fac8ac58d521ef4d459dac7d6ac092fd8c3fc23b7c4f0a431`。
- 最终 ZIP 已独立通过完整性、内外哈希、14文件 allowlist、boot/Image 绑定、
  boot AVB、ramdisk 尾部与敏感标记扫描；无符号链接或额外文件。

本节记录构建、schema v2 离线审计和 Kernel-only 打包成功，不代表 GitHub Release
已经创建，也不增加新的真机刷写结论。最终公开资产只包含 Kernel-only ZIP 及其
校验文件；完整 OTA、target-files 与 images ZIP 含 proprietary vendor 内容，只供
离线审计，不公开分发。

## 已验证的真机范围（2026-08-25构建）

- 构建成功，生成OTA、images与target-files。
- Magisk root可用。
- Droidspaces v6.4.5 daemon、MainActivity和两次`droidspaces check`均通过。
- 已做短时启动、屏幕/触摸、Wi-Fi、FBE userdata与相机基础路径检查。

## 尚未验证 / 不应据此宣称

- 尚未完整验证Droidspaces容器的创建、启动、停止、重启和删除生命周期。
- 尚未验证Turnip、Virgl或其他Droidspaces GPU加速路径。
- 尚未完成长期待机、反复冷启动、休眠唤醒、蜂窝、蓝牙、GNSS、热管理与功耗测试。
- Droidspaces userspace、应用与Magisk模块不由本系统镜像自动提供；它们必须由使用者单独安装并验证。
- 2026-08-28公开身份重建未执行新的真机刷写测试；其结论目前限于离线构建与审计。
- 私有release keys、签名身份迁移、自定义AVB root of trust、green Verified Boot及安全重锁均未验证。

因此，若向Droidspaces社区设备表提交条目，当前状态应为 **部分可用**，而非“正常运行”。

## 公开构建身份

`scripts/60-build.sh`默认设置Android的`BUILD_USERNAME` / `BUILD_HOSTNAME`和Kernel的`KBUILD_BUILD_USER` / `KBUILD_BUILD_HOST`为通用值（`android` / `repro-build`）。公开发布任何二进制产物前仍必须重新确认许可边界、身份清理和对应产物哈希。
