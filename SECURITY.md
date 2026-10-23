# Security policy

## 这套工具的性质

`winremote-deploy-kit` 会在目标 Windows 主机上开启一个**远程完全控制端点**
（SYSTEM 实例为全权限）。它被设计用于**受控环境**：自有设备、局域网内的运维通道、
隔离实验环境。

请不要把它暴露在公网。跨网络场景请使用虚拟内网（Tailscale / ZeroTier / WireGuard）
并在目标实例上加 `--ip-allowlist`。

## 凭据处理

- auth key 由安装脚本随机生成，写入 `C:\ProgramData\winremote\authkey.txt`，
  ACL 限制为 Administrators + SYSTEM
- auth key **只以 `Authorization: Bearer <key>`** 形式传输，务必配合 TLS
  （`--ssl-certfile` / `--ssl-keyfile`）或在虚拟内网中使用
- 仓库内**不包含任何真实凭据**；`.gitignore` 已排除 `authkey.txt` / `*.env`

## 已知的边界

- **锁屏不是安全边界**：会话内实例可以截取并操作锁屏界面；
  UAC 提权提示与 `Ctrl+Alt+Del` 安全桌面是拦得住的
- 目标端 `pyautogui.FAILSAFE` 被禁用（见上游实现），自动化失控时需人工结束进程

## 报告问题

发现安全问题请开 issue 或私下联系维护者，不要在公开渠道贴出可复现的攻击细节。
