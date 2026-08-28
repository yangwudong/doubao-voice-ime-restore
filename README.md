# DoubaoVoiceRestore

**让豆包输入法只负责语音输入，不接管你的键盘。**

[![CI](https://github.com/yangwudong/doubao-voice-ime-restore/actions/workflows/ci.yml/badge.svg)](https://github.com/yangwudong/doubao-voice-ime-restore/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/yangwudong/doubao-voice-ime-restore?sort=semver)](https://github.com/yangwudong/doubao-voice-ime-restore/releases)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 11+](https://img.shields.io/badge/macOS-11%2B-black)

English: [README.en.md](README.en.md)

## 痛点

豆包输入法的全局语音输入很好用：在任何输入框里按住快捷键（默认右 `⌥`）说话，文字直接落到光标处。

但它有一个让人恼火的副作用——**为了完成语音识别，macOS 必须把当前输入法切换成豆包，而豆包用完之后不切回去。** 语音浮窗关闭了，输入法却停在豆包上。你敲下一个字才发现输入法不对，只能手动切回去。每一次都要切。

我想要的行为很简单：

> **豆包只管语音输入这一件事。浮窗关闭后，应该还是我自己那个天天用的输入法（搜狗、微信、系统拼音，随便哪个）。**

通义千问输入法就是这样做的，豆包不是。`DoubaoVoiceRestore` 是一个约 300 行的后台常驻程序，专门补上这个行为。

## 效果对比

| 操作 | 不装本工具 | 装了本工具 |
| --- | --- | --- |
| 按住语音快捷键 | 切到豆包 | 切到豆包 |
| 说话、文字上屏 | 正常 | 正常 |
| 语音浮窗关闭 | **仍然停在豆包** | 约 0.3 秒后自动切回你原来的输入法 |
| 接着敲键盘 | 输入法是错的，手动切 | 输入法就是你选的那个 |

## 工作原理

三次只读观察 + 一次公开 API 调用，全程不碰豆包：

| 步骤 | 使用的系统接口 | 说明 |
| --- | --- | --- |
| 1. 记住你原来的输入法 | `kTISNotifySelectedKeyboardInputSourceChanged` | 监听输入法切换通知；当输入法变成豆包时，记下切换前那个 |
| 2. 判断语音会话开始 | `CGWindowListCopyWindowInfo` | 检测豆包在屏幕底部画出的小尺寸语音浮窗。**只读窗口的位置和尺寸，不读屏幕内容**，因此不需要「屏幕录制」权限 |
| 3. 判断语音会话结束 | 同上 | 豆包的所有窗口都消失后，防抖等待约 0.3 秒 |
| 4. 切回去 | `TISSelectInputSource` | 系统公开 API，选回第 1 步记住的输入法 |

另外用 `CGEventSource.secondsSinceLastEventType` 查询「距离上一次按键过了多少秒」，用来区分「你按键主动结束语音」和「静音超时结束」，前者切回得更快（0.12 秒）。这个接口**只返回一个时间差，拿不到按了哪个键**，无法用于记录击键。

**不修改豆包的任何文件、不注入豆包进程、不需要 `sudo`。** 豆包正常升级不受影响；万一豆包改版导致浮窗判定失效，后果只是「没切回去」，退化成不装本工具的状态。

### 需要哪些权限

**一个都不需要。** 不需要「辅助功能」、不需要「输入监控」、不需要「屏幕录制」、不需要管理员密码、不联网。上面用到的全部是无特权的公开接口。

## 环境要求

- macOS 11 Big Sur 及以上（在 macOS 15 / Apple Silicon 上开发与验证）
- 已安装豆包输入法，并已开启「豆包输入法设置 → 语音输入 → 全局唤起语音」

## 安装

### 一键安装（推荐）

```sh
curl -fsSL https://raw.githubusercontent.com/yangwudong/doubao-voice-ime-restore/main/scripts/install.sh | bash
```

脚本会从 [Releases](https://github.com/yangwudong/doubao-voice-ime-restore/releases) 下载最新版的通用二进制（arm64 + x86_64，Intel 和 Apple Silicon 都能用），装成用户级 LaunchAgent。**全程不需要 `sudo`。**

升级也是同一条命令：会先停掉旧实例，再装新版本。

<details>
<summary>习惯先审代码再执行（推荐做法）</summary>

```sh
curl -fsSL https://raw.githubusercontent.com/yangwudong/doubao-voice-ime-restore/main/scripts/install.sh -o install.sh
less install.sh          # 确认内容
bash install.sh
```

</details>

<details>
<summary>GitHub 访问不畅时（脚本走 jsDelivr，二进制走镜像）</summary>

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/yangwudong/doubao-voice-ime-restore@main/scripts/install.sh \
  | DVR_MIRROR=https://ghfast.top/ bash
```

</details>

可用的环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DVR_VERSION` | `latest` | 安装指定版本，例如 `v1.0.0` |
| `DVR_MIRROR` | 空 | GitHub 下载地址的镜像前缀，例如 `https://ghfast.top/` |

### 其他方式

**下载压缩包手动安装**：从 Releases 下载 zip，解压后执行 `bash install.sh`（脚本会直接用包里的二进制，不再联网）。

**从源码编译**：需要 Xcode Command Line Tools（`xcode-select --install`）。

```sh
git clone https://github.com/yangwudong/doubao-voice-ime-restore.git
cd doubao-voice-ime-restore
make install
```

同一个 `install.sh` 覆盖了这三种场景：优先用同目录下的二进制，其次用本机 Swift 编译，都没有才去下载 release。

### 安装了哪些东西

| 路径 | 用途 |
| --- | --- |
| `~/Library/Application Support/DoubaoVoiceRestore/DoubaoVoiceRestore` | 可执行文件 |
| `~/Library/LaunchAgents/io.github.yangwudong.doubao-voice-ime-restore.plist` | 开机自启的 LaunchAgent |
| `~/Library/Logs/DoubaoVoiceRestore.log` | 运行日志 |

全部在你的用户目录内，不写系统目录。

## 验证是否生效

1. 切到你平时用的输入法（例如搜狗拼音）
2. 按住豆包的语音快捷键说一句话
3. 松手或按任意键结束
4. 看菜单栏的输入法图标——应该已经自动变回搜狗

想看实时日志：

```sh
tail -f ~/Library/Logs/DoubaoVoiceRestore.log
```

正常工作时日志长这样：

```
2026-08-28 19:41:02.311 input source -> com.bytedance.inputmethod.doubaoime (state: idle)
2026-08-28 19:41:02.377 armed; will restore com.sogou.inputmethod.sogou.pinyin
2026-08-28 19:41:02.622 voice session started (pill detected)
2026-08-28 19:41:06.104 Doubao windows gone; restoring in 0.12s
2026-08-28 19:41:06.231 voice session ended; restored com.sogou.inputmethod.sogou.pinyin
```

确认后台进程在跑：

```sh
launchctl list | grep doubao-voice-ime-restore
```

## 推荐搭配：用 Input Source Pro 把豆包挡在切换圈外

本工具解决的是「语音结束后切回来」。但只要豆包被启用，还有另一半问题：**macOS 自带的 `⌃Space` 会在你启用的所有输入法之间轮转，豆包也在这个圈里，于是你会误切到豆包。**

[Input Source Pro](https://inputsource.pro)（免费开源，GPLv3，源码在 [runjuu/InputSourcePro](https://github.com/runjuu/InputSourcePro)）正好解决这一半：

```sh
brew install --cask input-source-pro
```

打开它 → 侧边栏 **Keyboard → Hot Keys**，按下图配置：

![Input Source Pro 的 Hot Keys 面板：ABC + 搜狗拼音 组成一个快捷键组绑定 ⌘Space，豆包输入法不在组内](docs/images/input-source-pro.png)

1. **最下面那一组是「快捷键组」**：只放你真正用来打字的那两个输入法（截图里是 `ABC` + `搜狗拼音`），给它绑一个切换键。此后这个键只在组内轮转，**永远不会切到豆包**。
   > 截图里用的是 `⌘Space`，前提是先把 Spotlight 的 `⌘Space` 改掉或关掉；不想动 Spotlight 就用 `⌃Space`，或者用 ISP 支持的「双击 `⇧`」这类修饰键手势。
2. **上面 Input Sources 列表里的「豆包输入法」保持 `Record Shortcut` 空着**——不给它任何快捷键，它就只能由豆包自己的语音键唤起。
3. 关掉系统自带的轮转，避免两边打架：**系统设置 → 键盘 → 键盘快捷键 → 输入法**，取消勾选「选择上一个输入法」和「选择输入菜单中的下一个输入法」。
4. 可选：**App Rules / Browser Rules** 可以按 App 或网站指定默认输入法（终端和 IDE 用英文，聊天软件用中文）。

**两者配合后的最终效果：豆包只可能由语音快捷键激活，而本工具在语音浮窗关闭的瞬间把输入法切回来。**

两个工具不能互相替代：Input Source Pro 的规则是在**切换 App 或网站**时触发的，而语音输入既不换 App 也不换输入框，所以它不会介入；本工具也不管日常切换。如果你在 App Rules 里给某个 App 设了默认输入法，那本工具切回去的就是它——不冲突。

## 卸载

```sh
curl -fsSL https://raw.githubusercontent.com/yangwudong/doubao-voice-ime-restore/main/scripts/uninstall.sh | bash
```

有本地文件的话也可以直接跑：

```sh
bash scripts/uninstall.sh   # 从源码目录
bash uninstall.sh           # 从解压出来的发布包
```

会停掉后台进程、删掉 LaunchAgent、可执行文件和日志。豆包本身不受任何影响。

## 参数微调

豆包没有提供「语音开始 / 结束」的通知，所以会话是靠浮窗的尺寸和位置推断出来的。如果豆包改版导致判定不准，改 [`Sources/DoubaoVoiceRestore/Tuning.swift`](Sources/DoubaoVoiceRestore/Tuning.swift) 里的常量后重新 `make install` 即可，其他代码里没有硬编码这些假设。

| 常量 | 默认值 | 含义 |
| --- | --- | --- |
| `pillMaxWidth` / `pillMaxHeight` | 280 / 64 | 语音浮窗的最大宽高（点）。浮窗变大了就调大 |
| `pillBottomBand` | 200 | 浮窗必须落在距屏幕底部这个范围内 |
| `sessionGoneDelay` | 0.35 s | 窗口消失后的默认防抖时间。切回太早就调大 |
| `sessionGoneDelayAfterKey` | 0.12 s | 你按键结束语音时的防抖时间 |
| `armGrace` | 3.0 s | 切到豆包后，等浮窗出现的最长时间。超时视为你手动切的，不做处理 |
| `pollInterval` | 0.06 s | 窗口轮询间隔（空闲时完全不轮询，CPU 占用约为 0） |

## 故障排查

| 现象 | 排查方向 |
| --- | --- |
| 完全没反应 | `launchctl list \| grep doubao-voice-ime-restore` 看进程是否在跑；再看日志尾部 |
| 日志里出现 `no pill within 3.0s` | 浮窗没被识别（豆包改版或多屏摆放问题）。调 `pillMaxWidth` / `pillMaxHeight` / `pillBottomBand` |
| 日志一直没有 `input source ->` | 豆包的全局语音没开启，或者语音快捷键实际上没有切换输入法 |
| 切回来太早（把语音截断了） | 调大 `sessionGoneDelay` |
| 切回来太慢 | 调小 `sessionGoneDelay` |
| 找不到豆包进程 | `pgrep -x DoubaoIme` 应该输出一个 PID；没有说明豆包输入法没在运行 |
| macOS 提示无法验证开发者 | 发布的二进制是 ad-hoc 签名、未做公证。`install.sh` 会自动清掉 quarantine 标记；仍不放心可以直接用 `make install` 从源码编译 |

## 开发

```sh
make            # 列出所有可用目标
make build      # 编译当前架构的 release 版本
make universal  # 编译 arm64 + x86_64 通用二进制
make run        # 前台运行，^C 停止（调试用）
make lint       # swift-format 检查
make fmt        # swift-format 格式化
make package    # 在 dist/ 里打出发布用的 zip
make clean      # 清理构建产物
```

代码结构：

```
Sources/DoubaoVoiceRestore/
├── main.swift          命令行参数与入口
├── Watchdog.swift      状态机：idle → arming → session → restoring
├── SystemProbes.swift  对系统接口的只读封装（输入法 / 窗口 / 按键活跃度）
└── Tuning.swift        全部可调常量
```

命令行参数：

```
DoubaoVoiceRestore [-q|--quiet] [-h|--help] [-v|--version]
```

`--quiet` 完全关闭日志输出（想让日志文件不再增长时可以在 plist 的 `ProgramArguments` 里加上）。

## 隐私

- **不联网。** 代码里没有任何网络调用。
- **不记录击键。** 只向系统查询「距上次按键过了多少秒」这一个数字，拿不到键值。
- **不读屏幕内容。** 窗口接口返回的只是位置和尺寸。
- 日志里只有时间戳、输入法的 bundle ID 和状态机的状态变化，没有你输入的任何内容。

## 致谢

- [Input Source Pro](https://github.com/runjuu/InputSourcePro) by [@runjuu](https://github.com/runjuu) —— 输入法切换体验的另一半，强烈推荐搭配使用
- 通义千问输入法 —— 语音输入后自动切回原输入法的行为参考

## 许可

[MIT](LICENSE)

## 声明

本项目是第三方独立工具，与字节跳动无关，未获得其授权或背书。「豆包」是字节跳动的商标，此处仅用于说明本工具的适用对象。
