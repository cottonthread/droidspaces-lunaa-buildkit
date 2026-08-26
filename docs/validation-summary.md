# 验证摘要（公开版）

本文件只保留可复核的技术结论；原始命令记录、主机路径、设备唯一标识和本地归档信息不随公开版发布。

## 构建范围

- 设备：Realme GT Master Edition（lunaa / RMX3360）。
- 基线：LineageOS 23.2 / Android 16，冻结 revision 见 [`../manifests/frozen-20260825.xml`](../manifests/frozen-20260825.xml)。
- Kernel：基于 pjgowtham 的 `android_kernel_oneplus_sm8350` 固定 revision，并应用本仓库的 Kernel patch 与 overlay。
- 构建类型：`userdebug/test-keys` 研究构建；私有 release-key 身份和安全重锁不在已验证范围内。

## 2026-08-26 公开身份重建

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
- 2026-08-26公开身份重建未执行新的真机刷写测试；其结论目前限于离线构建与审计。
- 私有release keys、签名身份迁移、自定义AVB root of trust、green Verified Boot及安全重锁均未验证。

因此，若向Droidspaces社区设备表提交条目，当前状态应为 **部分可用**，而非“正常运行”。

## 公开构建身份

`scripts/60-build.sh`默认设置Android的`BUILD_USERNAME` / `BUILD_HOSTNAME`和Kernel的`KBUILD_BUILD_USER` / `KBUILD_BUILD_HOST`为通用值（`android` / `repro-build`）。公开发布任何二进制产物前仍必须重新确认许可边界、身份清理和对应产物哈希。
