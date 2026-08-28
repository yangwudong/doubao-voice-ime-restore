# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-08-28

首个公开版本。

### 新增

- 监听输入法切换通知，在豆包语音输入结束后自动切回原输入法
- 通过豆包语音浮窗的尺寸与位置推断语音会话的起止，无需任何系统权限
- 按键结束语音时走更短的防抖路径（0.12 s），静音超时走默认防抖（0.35 s）
- 空闲时完全跳过窗口轮询，CPU 占用约为 0
- `install.sh` / `uninstall.sh`：安装为用户级 LaunchAgent，开机自启，日志写入 `~/Library/Logs`
- `curl … | bash` 一键安装：自动从 GitHub Releases 拉取最新通用二进制，支持 `DVR_VERSION` 指定版本、`DVR_MIRROR` 指定镜像前缀
- 命令行参数 `--quiet` / `--help` / `--version`
- arm64 + x86_64 通用二进制，由 GitHub Actions 构建并发布

[1.0.0]: https://github.com/yangwudong/doubao-voice-ime-restore/releases/tag/v1.0.0
