# GitHub CDN Worker

使用 Cloudflare Workers 代理 GitHub 公开 Raw 文件和 Release 附件，作为后续 CDN 的代理源站。此目录对应仓库 `NzflpKfnjos/demo`；部署后，将文件链接替换为下列加速地址即可，无需修改 GitHub 仓库设置。

## 部署

```sh
cd github-cdn
npm install
npx wrangler login
npm run deploy
```

部署成功后会输出 Worker 地址，例如 `https://github-cdn.<你的子域>.workers.dev`。也可以在 Cloudflare 的 Workers & Pages 中创建名为 `github-cdn` 的 Worker，把 `src/worker.js` 的全部内容粘贴到编辑器并部署。

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

## CDN 缓存

Worker 仅流式代理，不使用 Cache API，不设置缓存 TTL，也不输出 `X-Cache`。原有 `RAW_CACHE_TTL`、`RELEASE_CACHE_TTL` 变量已移除。

代理响应会移除上游的 `Cache-Control`、`CDN-Cache-Control`、`Cloudflare-CDN-Cache-Control`、`Surrogate-Control`、`Expires`、`Age` 和缓存状态头，缓存策略交由后续 CDN 配置。保留 `ETag`、`Last-Modified`、`Content-Type`、`Content-Length` 等文件元数据，以及 Range 请求和部分响应支持。Worker 自身生成的首页和错误响应同样不设置缓存控制头。

接入 CDN 时，把 Worker 域名设为源站，按需要配置文件缓存时间、查询参数缓存键和错误响应缓存策略。GitHub 原链接中间的 `https://` 必须原样保留，避免 CDN 将路径中的连续斜杠合并。查询参数不会转发给 GitHub。

分支、tag 或 `latest` 更新后的刷新与过期策略由 CDN 管理；固定内容建议使用 commit SHA 或不覆盖的 Release 版本。

## 上游限制

只接受拼接的 HTTPS Raw 文件直链与 GitHub Release 附件直链，不接受其他域名、GitHub 网页或任意 URL。旧的 `/raw/OWNER/REPO/REF/FILE` 和 `/release/OWNER/REPO/TAG/ASSET` 格式仍兼容。初始上游固定为 `raw.githubusercontent.com`、`github.com`；最多跟随 5 次 HTTPS 重定向，域名仅允许这两者及 `release-assets.githubusercontent.com`、`objects.githubusercontent.com`。不转发 Cookie、Authorization 或任意查询参数，不支持私有仓库、Git clone、GitHub API 或网页代理。

此服务允许下载任何公开 GitHub 仓库中符合路径格式的文件；如需只服务自有仓库，可在 `resolveUpstream` 增加 owner/repo 限制。Cloudflare 与 GitHub 的可达性、限流和服务状态仍会影响下载速度。
