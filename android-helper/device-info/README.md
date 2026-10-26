# 设备信息助手

此 APK 只用于 macOS 版设备信息面板按需读取 GAID，通过 Google Play 服务的官方 `AdvertisingIdClient.getAdvertisingIdInfo()` 调用。包名为 `com.songran.logcatmini.deviceinfo`，没有 Activity、后台服务、联网权限或 ID 持久化。唯一权限为 `com.google.android.gms.permission.AD_ID`。读取由已授权 ADB 对当前 Android 用户执行 instrumentation，结果仅通过 ADB 返回 Mac。

首次点击「读取 GAID」才会安装；已安装当前版本时复用。安装失败不会卸载已有应用，也不会尝试绕过手机的安装限制。可以在手机应用设置卸载「Logcat Mini 设备信息」，下次读取时会重新安装。

GAID 重置不在助手中执行。Mac 通过 Google Play 服务提供的 `com.google.android.gms.settings.ADS_PRIVACY` Activity 入口打开设置，由用户确认。没有使用 root、修改私有文件或清空 Google Play 服务数据。

在项目根目录构建（JDK 17、Android SDK 35、Gradle 8.13 或更新的兼容版本）：

```sh
GRADLE_BIN=/path/to/gradle bash scripts/build-device-info-helper.sh
```

依赖固定为 AGP 8.13.2、`com.google.android.gms:play-services-ads-identifier:18.2.0`，由 Google Maven 与 Maven Central 解析。产物复制到 `Sources/LogcatMini/Resources/DeviceInfo.apk`，随 Mac 应用打包；普通 Mac 构建使用内置 APK，无需 Android 构建环境。修改助手协议或实现时，同时递增 `versionCode` 和 `DeviceInfoService` 中的版本检查，然后重新构建 APK。签名使用本机 Android 调试密钥，密钥不随源码或应用分发；更换构建机签名后，旧版助手的升级可能需用户先自行卸载旧助手。

参考：[官方读取 API](https://developers.google.com/android/reference/com/google/android/gms/ads/identifier/AdvertisingIdClient)、[广告 ID 与全零行为](https://support.google.com/googleplay/android-developer/answer/6048248)、[Google APIs 使用条款](https://developers.google.com/terms)。
