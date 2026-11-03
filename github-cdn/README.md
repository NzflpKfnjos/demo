# GitHub CDN Worker

使用 Cloudflare Workers 代理 GitHub 公开 Raw 文件和 Release 附件，并用 Cache API 缓存响应。此目录对应仓库 `NzflpKfnjos/demo`；部署后，将文件链接替换为下列加速地址即可，无需修改 GitHub 仓库设置。

## 部署

```sh
cd github-cdn
npm install
npx wrangler login
npm run deploy
```

部署成功后会输出 Worker 地址，例如 `https://github-cdn.<你的子域>.workers.dev`。也可以在 Cloudflare 的 Workers & Pages 中创建名为 `github-cdn` 的 Worker，把 `src/worker.js` 的全部内容粘贴到编辑器并部署；不设置环境变量时使用默认缓存时间。

本地开发运行 `npm run dev`，测试运行 `npm test`。生产环境可在 Cloudflare 控制台给 Worker 绑定自定义域名。

## 加速链接

在 Worker 域名后加 `/`，直接拼接完整 GitHub 直链即可，无需改写原链接路径。

当前已部署地址：`https://github-cdn.1878966904.workers.dev`。更新代码后运行 `npm run deploy` 使新格式生效。

| 用途 | GitHub 原地址 | 加速地址 |
| --- | --- | --- |
| 当前仓库文件 | `https://raw.githubusercontent.com/NzflpKfnjos/demo/main/README.md` | `https://github-cdn.1878966904.workers.dev/https://raw.githubusercontent.com/NzflpKfnjos/demo/main/README.md` |
| 指定版本附件 | `https://github.com/NzflpKfnjos/demo/releases/download/v1.0.0/app.zip` | `https://github-cdn.1878966904.workers.dev/https://github.com/NzflpKfnjos/demo/releases/download/v1.0.0/app.zip` |
| 最新版本附件 | `https://github.com/NzflpKfnjos/demo/releases/latest/download/app.zip` | `https://github-cdn.1878966904.workers.dev/https://github.com/NzflpKfnjos/demo/releases/latest/download/app.zip` |

示例文件、分支和版本需要在仓库中实际存在。路径中的文件名、版本等含特殊字符时应按路径段进行 URL 编码。目前分支名或 tag 不支持包含 `/`。

```sh
curl -I 'https://github-cdn.1878966904.workers.dev/https://raw.githubusercontent.com/NzflpKfnjos/demo/main/README.md'
curl -L 'https://github-cdn.1878966904.workers.dev/https://github.com/NzflpKfnjos/demo/releases/download/v1.0.0/app.zip' -o app.zip
```

## 缓存规则

在 `wrangler.toml` 的 `[vars]` 中配置，或在控制台设置同名变量，修改后重新部署：

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `RAW_CACHE_TTL` | `3600` | Raw 文件边缘缓存秒数 |
| `RELEASE_CACHE_TTL` | `86400` | Release 附件边缘缓存秒数，包含 `latest` |

仅缓存完整 GET 请求的 `200` 响应。`Cache-Control` 的 `s-maxage` 为上述边缘缓存时间，浏览器 `max-age` 最多 300 秒。`X-Cache` 表示 `HIT`、`MISS` 或 `BYPASS`。HEAD 可读取已有缓存；Range 请求透传上游以支持断点续传，不缓存部分响应；错误响应设置 `no-store`。

同一分支、tag 或 `latest` 更新后，旧内容可能保留到缓存到期。需要稳定内容时使用 commit SHA 或固定且不覆盖的 Release 版本；`latest` 更新频繁时建议缩短 Release TTL。查询参数会被忽略，不能用 `?v=...` 刷新缓存。

Cache API 缓存按 Cloudflare 数据中心独立存储，不保证每次命中，也不提供 Tiered Cache。超出 Cloudflare 套餐缓存大小限制的文件仍会尝试流式代理，但不会成功写入缓存；实际可下载大小与吞吐还受 Workers 平台限制。缓存写入失败不影响正常代理。

## 上游限制

只接受拼接的 HTTPS Raw 文件直链与 GitHub Release 附件直链，不接受其他域名、GitHub 网页或任意 URL。旧的 `/raw/OWNER/REPO/REF/FILE` 和 `/release/OWNER/REPO/TAG/ASSET` 格式仍兼容。初始上游固定为 `raw.githubusercontent.com`、`github.com`；最多跟随 5 次 HTTPS 重定向，域名仅允许这两者及 `release-assets.githubusercontent.com`、`objects.githubusercontent.com`。不转发 Cookie、Authorization 或任意查询参数，不支持私有仓库、Git clone、GitHub API 或网页代理。

此服务允许下载任何公开 GitHub 仓库中符合路径格式的文件；如需只服务自有仓库，可在 `resolveUpstream` 增加 owner/repo 限制。Cloudflare 与 GitHub 的可达性、限流和服务状态仍会影响下载速度。
