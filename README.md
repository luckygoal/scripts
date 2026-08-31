# GOST v3 智能代理与探针防御一键管理脚本

基于 [go-gost/gost](https://github.com/go-gost/gost) v3 的自动化管理脚本，专为 Linux VPS 设计。

## 特性
- 🚀 **智能环境检测**：自动扫描系统已有的 SSL 证书（acme.sh / certbot / v2ray-agent 等）及已有静态伪装站点。
- 🔒 **HTTPS (TLS) & HTTP 双协议**：支持普通 HTTP 代理与高度伪装的 HTTPS/TLS 代理。
- 🛡️ **探针防御 (Probe Resistant)**：未授权探测/普通浏览器直接访问时，自动返回 `200 OK` 并展示伪装网站，防止主动探测与端口扫描。
- ⚡ **无缝共存**：支持与现有的 Nginx、Xray (VLESS+TLS) 等服务共存，互不干扰。
- 🔄 **完备的生命周期管理**：提供可视化交互菜单与命令行子命令（启动/停止/重启/日志/连通性测试）。

## 一键安装与使用

### 快速运行
\`\`\`bash
wget -N --no-check-certificate https://raw.githubusercontent.com/luckygoal/scripts/main/gost.sh && chmod +x gost.sh && ./gost.sh
\`\`\`

### 快捷子命令
脚本安装完成后会自动注册 \`gost\` 全局命令：
- \`gost\` : 打开管理交互菜单
- \`gost status\` : 查看当前代理连接信息与配置
- \`gost test\` : 测试代理连通性并输出出口 IP
- \`gost log\` : 查看 GOST 实时运行日志
- \`gost probe on\` : 开启探针防御（直接展示伪装网站）
- \`gost probe off\` : 关闭探针防御（返回 HTTP 407）
- \`gost restart\` : 重启 GOST 服务
\`\`\`
****
