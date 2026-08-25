# 验证摘要（公开版）

本文件只保留可复核的技术结论；原始命令记录、主机路径、设备唯一标识和本地归档信息不随公开版发布。

## 构建范围

- 设备：Realme GT Master Edition（lunaa / RMX3360）。
- 基线：LineageOS 23.2 / Android 16，冻结 revision 见 [`../manifests/frozen-20260825.xml`](../manifests/frozen-20260825.xml)。
- Kernel：基于 pjgowtham 的 `android_kernel_oneplus_sm8350` 固定 revision，并应用本仓库的 Kernel patch 与 overlay。
- 这是 `userdebug/test-keys` 的研究构建；独立 AVB 密码学验证和私有 release key 链不在验证范围内。

## 已验证

- 构建成功，生成 OTA、images 与 target-files。
- Magisk root 可用。
- Droidspaces v6.4.5 daemon、MainActivity 和两次 `droidspaces check` 均通过。
- 已做短时启动、屏幕/触摸、Wi-Fi、FBE userdata 与相机基础路径检查。

## 尚未验证 / 不应据此宣称

- 尚未完整验证 Droidspaces 容器的创建、启动、停止、重启和删除生命周期。
- 尚未验证 Turnip、Virgl 或其他 Droidspaces GPU 加速路径。
- 尚未完成长期待机、反复冷启动、休眠唤醒、蜂窝、蓝牙、GNSS、热管理与功耗测试。
- Droidspaces userspace、应用与 Magisk 模块不由本系统镜像自动提供；它们必须由使用者单独安装并验证。

因此，若向 Droidspaces 社区设备表提交条目，当前状态应为 **部分可用**，而非“正常运行”。

## 公开构建身份

`scripts/60-build.sh` 默认设置 Android 的 `BUILD_USERNAME` / `BUILD_HOSTNAME` 和 Kernel 的 `KBUILD_BUILD_USER` / `KBUILD_BUILD_HOST` 为通用值（`android` / `repro-build`）。公开发布的二进制产物必须来自该类无身份标识的构建，并在发布前重新审计。
