# BUILD-NETEASE — 网易云 / System Now Playing 构建说明

English summary below · 下方为详细中文步骤

---

## 设计选择 / Design choice

**默认推荐 Homebrew `media-control`（brew-based）**，可选捆绑 `mediaremote-adapter`。

| 方案 | 说明 |
|------|------|
| **brew `media-control`（推荐）** | 在 Mac 上 `brew install media-control`。Widget 运行时调用 CLI。无需把 framework 打进 `.pock`，避开签名/沙盒与 **仅 x86_64** 预编译库在 Apple Silicon 上不可用的问题。 |
| **捆绑 adapter（可选）** | 在本机用 CMake 编出 **arm64/universal** `MediaRemoteAdapter.framework`，放入 `vendor/`，由 Xcode 脚本拷进 `.pock`。与 TouchBarLyrics 相同：`/usr/bin/perl` + `mediaremote-adapter.pl`。 |

本仓库已 vendored：`lirik/Resources/mediaremote-adapter.pl`。  
**未**附带预编译 framework（上游 TouchBarLyrics 自带的是 x86_64，不适合 Apple Silicon）。

Lyrics 仍走 **LRCLIB**；只要拿到 title / artist / elapsed / duration，原有同步逻辑不变。

---

## 前置条件 Prerequisites

在 **macOS 15.x Apple Silicon** 上：

1. **Pock** — https://pock.app  
2. **Xcode（完整版，不只 Command Line Tools）** — PockKit / CocoaPods 编 `.pock` 需要完整 SDK。你已有 Swift 6.2.4 / CLT 时，若 `pod install` 或 `xcodebuild` 报找不到 macOS SDK / PockKit，请安装完整 Xcode 并执行：
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
3. **CocoaPods** — `sudo gem install cocoapods` 或 `brew install cocoapods`  
4. **media-control（推荐运行时依赖）**：
   ```bash
   brew install media-control
   # 若 formula 不在 core：brew tap ungive/media-control && brew install media-control
   ```
5. **网易云音乐** Mac 版（bundle id `com.netease.163music`）

可选（自包含 bundle）：CMake — `brew install cmake`

---

## 构建步骤 Build

```bash
# 1. 进入本补丁树（或你 clone 后的路径）
cd /path/to/lirik-netease

# 2.（可选）构建并安装 arm64 MediaRemoteAdapter.framework
# ./scripts/build-mediaremote-adapter.sh

# 3. CocoaPods
pod install

# 4. Release 构建（关闭用户脚本沙盒，与上游 README 一致）
xcodebuild -workspace lirik.xcworkspace -scheme lirik -configuration Release build \
  ENABLE_USER_SCRIPT_SANDBOXING=NO

# 产物通常在 DerivedData，或上游约定的 dist/。查找：
find ~/Library/Developer/Xcode/DerivedData -name 'lirik.pock' 2>/dev/null | head
# 若项目有拷贝到 dist 的脚本/习惯：ls dist/lirik.pock
```

打开 `lirik.xcworkspace`（**不是** `.xcodeproj`）也可在 Xcode 里 ⌘B。

开发团队：`project.pbxproj` 里有上游 `DEVELOPMENT_TEAM`。若签名失败，在 Xcode → Signing & Capabilities 改成你自己的 Team。

---

## 安装到 Pock Install

```bash
# 去掉隔离属性（否则会报 damaged / invalid-bundle）
xattr -cr /path/to/lirik.pock

# 安装
cp -R /path/to/lirik.pock ~/Library/Application\ Support/Pock/Widgets/
# 或双击 lirik.pock
```

1. 菜单栏 Pock → **Manage widgets...** → 启用 **Lirik**  
2. **Customize Pock...** → 把 Lirik 拖到 Touch Bar  

---

## 测试 网易云 Test with NetEase

1. 确认 Control Center「正在播放」能显示网易云当前曲目。  
2. 终端验证：
   ```bash
   media-control get --no-artwork
   # 应看到 title / artist / bundleIdentifier ≈ com.netease.163music
   ```
3. Pock → Lirik 偏好 → **Music Player Source** 选：
   - **System Now Playing (网易云/any)**，或  
   - **Auto-detect**
4. 播放一首在 [LRCLIB](https://lrclib.net) 上有歌词的歌 → Touch Bar 应出现同步歌词。  
5. **System** 路径**不需要**给网易云开 Automation。Spotify / Apple Music 的 AppleScript 路径仍可能需要 Automation。

查看日志：
```bash
log stream --predicate 'eventMessage CONTAINS "MediaControlBackend" OR eventMessage CONTAINS "NowPlayingWatcher"' --level debug
```

---

## 故障排查 Troubleshooting

| 现象 | 处理 |
|------|------|
| 无歌词、日志说 MediaControl unavailable | `brew install media-control`；确认 `/opt/homebrew/bin/media-control` 存在；重启 Pock |
| `media-control get` 为空 | 网易云未上报 Now Playing；换曲/开关一次播放；确认控制中心有正在播放 |
| 只有 Spotify/Music 有词 | 偏好改成 System / Auto；不要用 Spotify Only |
| 签名 / PockKit 失败 | 安装完整 Xcode；`xcode-select` 指向 Xcode；换 DEVELOPMENT_TEAM |
| 捆绑了 framework 但仍失败 | 用 `lipo -info` 确认是 **arm64** 或 universal，不要用 x86_64-only |

---

## English (short)

1. Install **Xcode**, **CocoaPods**, **Pock**, and `brew install media-control`.  
2. `pod install` then `xcodebuild -workspace lirik.xcworkspace -scheme lirik -configuration Release build ENABLE_USER_SCRIPT_SANDBOXING=NO`.  
3. Copy `lirik.pock` into `~/Library/Application Support/Pock/Widgets/`, `xattr -cr` it, enable in Pock.  
4. Set Lirik player source to **System Now Playing** or **Auto**. Play 网易云; lyrics still come from LRCLIB.  
5. Optional: `./scripts/build-mediaremote-adapter.sh` to bundle an arm64 framework instead of relying on brew.  
6. **No binary was built on the Linux patch box** — you must build on your Mac.


---

## GitHub Actions（推荐：不污染本机）

仓库已包含 `.github/workflows/build-pock.yml`。

1. 把本补丁树推到你的 GitHub 仓库（任意 public/private fork）。
2. Actions 页 → 选 **Build lirik.pock** → **Run workflow**（或 push 到 `main`/`netease`）。
3. 跑完后下载 Artifact **`lirik-netease-pock`**（内含 `lirik.pock` 与 zip）。
4. 本机：`xattr -cr lirik.pock`，拷进 `~/Library/Application Support/Pock/Widgets/`，装 Pock + `brew install media-control` 即可（无需本机 Xcode）。

CI 使用 ad-hoc / 关闭自动签名（无 Apple Developer 账号）。若 Gatekeeper 拦截，用 `xattr -cr`。
