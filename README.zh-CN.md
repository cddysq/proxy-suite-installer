[English](./README.md) | [中文](./README.zh-CN.md)

# Proxy Suite Installer

一键安装 [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)，并配套一组 Shell 命令，统一管理终端工具的代理状态。

## 快速开始

**在线安装**（推荐）：

```bash
curl -fsSL https://proxy.wusaqi.me/install.sh | bash
```

或者克隆后本地运行：

```bash
git clone https://github.com/cddysq/proxy-suite-installer.git
bash proxy-suite-installer/install.sh
```

安装完成后，打开新终端并运行：

```bash
proxy on          # 启动 Clash Verge + 开启代理
proxy test        # 验证端口和出站连通性
proxy status      # 查看紧凑状态概览
proxy off         # 停止一切并清理环境变量
```

## 环境要求

| 平台 | 前置条件 |
|------|---------|
| **WSL / Linux** | `bash`、`curl`、`awk`、`sed`、`grep`、`cut` — Ubuntu/Debian/Fedora 均已预装 |
| **macOS** | `bash`、`curl`、`hdiutil` — macOS 自带；已适配 Intel 和 Apple Silicon |

## 安装选项

| 参数 | 说明 |
|------|------|
| `--latest` | 安装时从 GitHub API 获取最新 Clash Verge 版本 |
| `--version <tag>` | 指定安装版本（如 `v2.4.7`） |
| `--skip-clash-install` | 仅刷新代理命令套件，跳过 Clash 下载 |
| `--no-modify-shell` | 不修改 `.bashrc` / `.zshrc` |
| `--skip-font-install` | 跳过 Linux CJK 字体安装 |
| `--shell-file <path>` | 仅修改指定的 Shell 配置文件 |
| `--force` | 即使版本已匹配也强制重新安装 |
| `--yes` | 自动确认所有提示 |
| `-h`、`--help` | 显示帮助信息 |

## 命令说明

| 命令 | 说明 |
|------|------|
| `proxy on` | 启动 Clash Verge，写入环境文件，配置 git/npm/pnpm/yarn/pip 代理和 APT 代理（Linux） |
| `proxy off` | 停止 Clash Verge，删除环境文件，清除工具代理 |
| `proxy status` | 显示紧凑的日常状态 |
| `proxy status -v` | 显示详细诊断信息（端口、配置、环境变量、工具代理） |
| `proxy test [URL]` | 验证本地端口和出站 HTTP/SOCKS5 连通性（默认 `https://api.github.com/meta`） |
| `proxy update` | 重新运行安装器以就地刷新命令套件 |
| `proxy uninstall` | 移除本地命令套件、Shell 集成和运行时文件 |

## 工作原理

```
install.sh
 ├── 下载并校验 Clash Verge Rev (.deb/.rpm/.dmg)
 ├── 通过 apt/dnf/rpm 安装包 或 复制 .app 到 /Applications
 ├── 写入 7 个脚本到 ~/bin/
 │    ├── clash-proxy-lib.sh      (共享函数库)
 │    ├── clash-proxy-on.sh       (启用流程)
 │    ├── clash-proxy-off.sh      (禁用流程)
 │    ├── clash-proxy-status.sh   (状态展示)
 │    ├── clash-proxy-test.sh     (连通性检查)
 │    ├── proxy                   (统一 CLI 入口)
 │    └── proxy-uninstall         (清理工具)
 ├── 在 .bashrc / .zshrc 中写入托管代码块
 └── 将安装元数据写入 ~/.local/share/proxy-suite-installer/
```

**托管代码块** 使用 `# >>> marker >>>` / `# <<< marker <<<` 分隔符。重新安装时原地替换 — 不会重复，无需手动清理。

**SHA256 校验** 通过 GitHub Release API 响应中的 `digest` 字段验证下载文件的完整性。

## 更新

```bash
proxy update             # 从原始 install.sh 刷新命令套件
# 或
bash install.sh --force  # 完整重装，包括 Clash Verge 二进制文件
```

## 卸载

```bash
proxy uninstall
# 或
bash uninstall.sh
```

交互式提示让你选择是否同时移除 Clash Verge 应用和配置数据。

## 常见问题

| 问题 | 解决方法 |
|------|---------|
| `proxy: command not found` | 打开新终端，或运行 `source ~/.bashrc` |
| `proxy on` 提示 "failed to launch" | 检查 WSLg 是否可用：`echo $DISPLAY` |
| `proxy test` 显示端口未监听 | 先启动 Clash Verge GUI，或执行 `proxy status -v` 排查 |
| 当前 Shell 环境变量未加载 | 使用 Shell 函数 `proxy on`，而非在子 Shell 中运行 |

## 文件说明

| 文件 | 用途 |
|------|------|
| `install.sh` | 一键安装入口 |
| `uninstall.sh` | 便捷封装，委托给已安装的 `proxy-uninstall` |
| `versions.env` | 维护者使用的版本锁定文件 |
| `.gitattributes` | 强制 LF 换行符，确保 WSL/macOS 兼容 |
| `.editorconfig` | 编辑器格式化规则 |
| `.shellcheckrc` | ShellCheck 静态检查配置 |

## 许可证

[MIT](./LICENSE)
