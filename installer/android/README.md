# Android 发行规范 (APK & AAB)

本目录定义 AuraDSP 面向 Android 平台的签名、打包与分发标准。

---

## 1. 产物矩阵与命名

所有由 Gradle / Flutter 编译生成的发布包统一输出至 `dist/`：

1. **GitHub Releases 直装包 (Sideload APK)**：
   - 通用胖包：`dist/AuraDSP-v<ver>-android-universal.apk`
   - 主流真机包（体积优化）：`dist/AuraDSP-v<ver>-android-arm64-v8a.apk`
   - 兼容老设备：`dist/AuraDSP-v<ver>-android-armeabi-v7a.apk`
2. **应用商店分发包 (Google Play Store)**：
   - 标准 AAB：`dist/AuraDSP-v<ver>.aab`

---

## 2. 密钥管理规范

- **私钥存储**：严禁提交私钥 `*.keystore` 至公共仓库。
- **本地构建**：由开发者在本地环境变量中指定或由 `key.properties` 引用。
- **CI/CD 流水线**：由 GitHub Secrets 提供 base64 编码的密钥字符串，流水线运行时动态恢复后执行 `jarsigner` / `apksigner`。

---

## 3. 打包命令标准

```bash
# 进入 Flutter 工程目录
cd app/auradsp_app

# 编译拆分架构 APK
flutter build apk --release --split-per-abi

# 编译全架构通用 APK
flutter build apk --release

# 编译 Google Play App Bundle
flutter build appbundle --release

# 产物自动归集到 dist/ 目录 (由后续 pack 脚本处理)
```

