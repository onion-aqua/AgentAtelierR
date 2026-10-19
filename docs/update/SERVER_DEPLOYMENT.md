# 自托管更新服务器部署说明

本文说明独立静态更新服务的部署方式。服务名和路径与本项目实现一致；地址、镜像摘要和密钥参数使用占位符。2026-10-19 已完成实际基础设施部署及隔离渠道的部分真机验收；范围和待完成项见文末及 [真机测试记录](DEVICE_TEST_2026-10-19.md)。正式渠道未发布。

## 部署边界

使用独立 Compose 项目 `agentatelier-updates`，配置目录为 `/opt/agentatelier-updates`，公开文件目录为 `/srv/agentatelier-updates/public`。静态 Nginx 通过已存在的外部 Docker 网络 `agent-relay_default` 接入现有边缘 Nginx。

静态容器不发布宿主机端口，以 `101:101` 运行，根文件系统只读，只把公开目录和静态配置只读挂入。签名私钥、SSH 凭据、发布配置和 agent-relay 数据不进入容器或公开目录。

现有边缘 Nginx 仅新增 `/updates/agentatelier/` 路由，验证配置后执行 graceful reload。保持现有 `/health`、`/v1/` 和 WebSocket 配置；不重启边缘容器，不修改 agent-relay 应用、数据库或环境变量。

## 静态容器配置

首先核实服务器上现有 Nginx 镜像的 RepoDigest，使用该已安装镜像的完整摘要，例如 `nginx@sha256:<CURRENTLY_INSTALLED_DIGEST>`。不能把 `latest` 标签当作固定版本，也不要为本次部署顺带升级既有边缘镜像。

正式模板为 [compose.yaml](../../tool/update/server/compose.yaml)，以下结构与模板使用相同的网络别名和路径。`UPDATE_NGINX_IMAGE` 应设为核实过的完整摘要，`UPDATE_EDGE_NETWORK` 为实际既有网络名称：

```yaml
name: agentatelier-updates
services:
  static:
    image: ${UPDATE_NGINX_IMAGE:?set installed nginx image digest}
    user: "101:101"
    read_only: true
    restart: unless-stopped
    entrypoint: ["nginx"]
    command: ["-g", "daemon off;", "-c", "/etc/nginx/nginx.conf"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=16m,uid=101,gid=101,mode=700
    volumes:
      - /opt/agentatelier-updates/nginx.conf:/etc/nginx/nginx.conf:ro
      - /srv/agentatelier-updates/public:/srv/updates/agentatelier:ro
    networks:
      edge:
        aliases: [agentatelier-updates]
networks:
  edge:
    external: true
    name: ${UPDATE_EDGE_NETWORK:?set existing edge network}
```

容器在内部监听 `8080`，配置中不添加 `ports`。完整模板还包含内部健康检查与日志轮转。示例直接运行 Nginx，避免依赖镜像入口脚本修改只读配置。启动前应核实实际镜像在 UID 101 下能够读取挂载文件，并具有健康检查使用的 `wget`；公开目录和文件需具有对应的读取/目录遍历权限，不能使用可写全局权限来解决权限错误。

正式静态配置为 [nginx.conf](../../tool/update/server/nginx.conf)。下面仅展示路径与缓存规则；部署使用完整模板，其中还限制请求方法、隐藏敏感扩展名和私有目录，并配置不记录 URL 或请求头的访问日志：

```nginx
worker_processes auto;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 512; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;
    sendfile on;
    etag on;
    gzip off;
    client_body_temp_path /tmp/client_body;
    proxy_temp_path /tmp/proxy;
    fastcgi_temp_path /tmp/fastcgi;
    uwsgi_temp_path /tmp/uwsgi;
    scgi_temp_path /tmp/scgi;
    server {
        listen 8080;
        server_name _;
        root /srv;
        autoindex off;
        disable_symlinks on;
        location = /updates/agentatelier/healthz {
            default_type text/plain;
            add_header Cache-Control "no-store" always;
            return 200 'agentatelier-updates ready\n';
        }
        location /updates/agentatelier/channels/ {
            add_header Cache-Control "no-store" always;
            try_files $uri =404;
        }
        location ~ (^|/)\. { deny all; }
        location ~ ^/updates/agentatelier/(?:releases|resources|artifacts|notes)/ {
            add_header Cache-Control "public, max-age=31536000, immutable";
            try_files $uri =404;
        }
        location /updates/agentatelier/diagnostics/ {
            add_header Cache-Control "no-store" always;
            try_files $uri =404;
        }
        location / { return 404; }
    }
}
```

真实稳定渠道文件路径为 `public/channels/android/stable.json`，公网对应 `/updates/agentatelier/channels/android/stable.json`。所有可变渠道入口使用 `no-store`。其他公开路径只放不可变内容；不要在长期缓存路径反复覆盖 `notes.md`、APK 或快照。健康探针不表示渠道已发布。

公开目录必须整目录挂载：渠道采用原子重命名发布时，单文件 bind mount 可能继续引用旧 inode，导致容器看不到新渠道。

## 接入现有 HTTPS 边缘

先启动静态容器，并从同一 Docker 网络验证内部健康探针和文件读取。正式路由模板为 [edge-location.conf](../../tool/update/server/edge-location.conf)，在实际生效的现有 HTTPS `server` 中新增该片段，其核心如下：

```nginx
location ^~ /updates/agentatelier/ {
    set $updates_upstream http://agentatelier-updates:8080;
    proxy_pass $updates_upstream;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Connection "";
    proxy_set_header Authorization "";
    proxy_set_header Cookie "";
    proxy_set_header Accept-Encoding "";
    proxy_buffering off;
    proxy_intercept_errors off;
    proxy_redirect off;
    proxy_read_timeout 120s;
}
```

变量形式的 `proxy_pass` 不指定 URI，保留完整公开前缀，例如 `/updates/agentatelier/channels/android/stable.json` 在静态容器中仍使用同一路径，最终读取挂载目录内的 `channels/android/stable.json`。不要改成移除前缀的另一种映射，也不要让该 location 落入既有网页的 HTML 回退逻辑。不要转发用户的 Authorization 或 Cookie 到公开静态服务。

此结构由既有边缘终止 TLS，静态容器只通过内部网络接收 HTTP。公网入口必须使用 `<HTTPS_ORIGIN>/updates/agentatelier/`；客户端继续验证系统证书链，不使用任意证书回调或公网 HTTP。

变更前保存生效配置及挂载信息。更新后在边缘容器内检查实际配置内容，执行 `nginx -t`，通过后执行 `nginx -s reload`。若既有配置采用单文件 bind mount，不能假设宿主机原子替换文件会更新容器内挂载；必须验证容器实际读取的配置。不要通过重建或重启边缘来绕过此检查。

边缘已有 `resolver 127.0.0.11` 时，模板中的变量上游通过 Docker DNS 动态解析。部署前需核实该 resolver 在实际作用域可用；今后重建静态容器导致 IP 变化时，仍应验证解析、路由和下载，不能仅凭服务别名认定连接已恢复。

自动部署入口为 [deploy_update_server.py](../../tool/update/server/deploy_update_server.py)。脚本要求已安装镜像摘要、既有网络名称和检查时的边缘配置 SHA-256，启动独立项目后再次确认边缘配置未变化，随后保持原 bind mount inode 写入、验证并 reload。它不会拉取镜像，也不会创建签名渠道；已有路由会拒绝重复部署，应先审查现状再制定升级操作。

## 首次引导与空渠道

部署基础设施时，仅准备 pending 客户端配置，暂不启用正式构建配置。已提供的 Gitee 仓库在独立 `codex/update-device-test` 分支承载测试渠道和说明，正式 Gitee 渠道尚未发布；不要将测试地址当作正式来源。其他未提供的来源设为 `null`。

首个真实发布之前，保持签名渠道文件缺席，返回明确的 404。不要生成假 APK、占位 hash、假版本或空资源快照来伪装基线。

当前客户端仅把 HTTP 200 的有效签名清单或有效渠道指针视为成功；404、204 和空 JSON 都会导致检查失败。失败不会弹出“发现新版本”，但版本中心会显示检查失败。因此健康探针就绪不等于更新渠道就绪。

首个引导构建应显式使用已验证的 pending 配置，先得到固定字节的真实 APK，再生成匹配的签名清单并发布 HTTPS 渠道；渠道验收通过后才分发这份原始 APK，并把对应配置设为后续正式构建配置。不要为了“等渠道就绪”先构建无配置包，也不要发布后重新编译同一发布身份。配置中包含固定的公钥、资源密钥标识白名单、渠道、发布序号与兼容标识。Ed25519 公钥使用 32 字节原始公钥的标准 Base64，不能填入 PEM 文本或完整 DER。

引导包必须完整安装一次。没有内置更新配置的包不能以后由服务器远程开启更新；仍需用户完整安装一个已配置版本。基线清单必须描述实际保存的引导制品，不重新构建出另一个 hash 后复用原发布身份。

## 本地签名与 SSH 上传

签名始终在本地完成。使用 `New-UpdateManifest.ps1` 和 `Test-UpdateManifest.ps1`，私钥参数使用 `<LOCAL_SIGNING_KEY_PEM>` 等本地占位值对应的实际路径。服务器不承担签名，不保存更新私钥，也不提供公网管理或上传 API。

发布按以下顺序执行：

1. 通过项目保护构建脚本生成真实 APK，或从受管理资源生成完整快照。只公开允许分发的资源及加密角色包。
2. 在本地确定唯一递增 `release_seq`、不可变 `release_id` 和制品信息，生成签名清单并验证签名、大小和所有 hash。
3. 通过已授权 SSH/SFTP 通道上传到未公开的暂存目录；逐项核对上传后的 hash。SSH 连接应核实主机身份，不关闭主机密钥校验。
4. 将不可变 APK、资源对象、快照、版本说明及发布清单放到最终路径，验证公网 HTTPS 可读、字节大小及 hash。
5. 最后将真实渠道候选写到渠道目录内的临时文件，再使用同一文件系统的原子重命名替换 `channels/android/stable.json`。不要跨文件系统移动，也不要直接写入客户端正在读取的正式渠道文件。
6. 复核渠道验签、目标制品和既有 relay 健康状态，再清理暂存文件。保留当前及仍被支持的旧制品，不因一次发布清空历史对象。

服务器发布入口为 [promote_channel.py](../../tool/update/server/promote_channel.py)。调用必须显式传入 `--required-channel`、预期 `key_id` 和本地可信公钥 PEM 文件的 SHA-256。脚本在独占锁内校验渠道、公钥、签名、完整制品引用和 hash，再以独立文件副本发布不可变对象、原子替换渠道。前期测试仅使用 `device-test`；用户随后明确要求正式发布，本次以全新签名身份发布 `stable` 序号 52，不复用测试签名或发布 ID。

### 隔离测试渠道发布命令

SSH 上传完成后，私有暂存目录应包含以下文件。`files/` 下的相对路径就是公开目录中的目标路径；`upload-plan.json` 的 `files` 列表逐项记录 `path`、`sha256`、`size`：

```text
/srv/agentatelier-updates/staging/<STAGE_ID>/
  upload-plan.json
  manifest.json
  payload.canonical.json
  public-key.pem
  files/
    releases/<RELEASE_ID>/manifest.json
    artifacts/<IMMUTABLE_APK_PATH>
    notes/<IMMUTABLE_NOTES_PATH>
    resources/<SNAPSHOT_AND_OBJECT_PATHS>   # 有资源更新时提供
```

`manifest.json` 必须与 `files/releases/<RELEASE_ID>/manifest.json` 完全一致。使用上传前、在本地确认可信的公钥 PEM 文件计算 SHA-256；这里需要完整 PEM 文件原始字节的 hash，而不是 32 字节原始公钥的 hash，也不要以暂存目录里未经确认的文件自行计算并充当信任依据。所有签名私钥继续留在本机。

以下仅展示已授权隔离测试渠道的调用形式，替换占位符后在服务器执行：

```bash
python3 <PROMOTE_SCRIPT_PATH>/promote_channel.py \
  --stage /srv/agentatelier-updates/staging/<STAGE_ID> \
  --expected-key-id <TRUSTED_KEY_ID> \
  --expected-public-key-sha256 <EXACT_LOCAL_PUBLIC_PEM_SHA256> \
  --required-channel device-test
```

脚本要求 Linux，全局文件锁串行化发布；目标文件独立复制、hash 复核并刷盘后才落地，既有不可变文件冲突即拒绝。APK、差分、资源清单及对象和缓存说明必须由上传计划或已存在的公开文件完整满足，全部通过后才原子切换渠道。测试 APK、签名清单、Gitee 分支和渠道必须一致。正式发布使用独立 `stable` 清单及默认 main 分支指针，不能将测试清单改名充当正式签名。

同序号或同 `release_id` 不得换成不同字节。版本说明如需修改，遵循不可变发布规则，使用新发布身份和序号。

## 验收与回滚

最低验收应记录：HTTPS 证书链、健康探针、渠道真实状态、文件 HEAD 长度与 ETag、Range 返回的 206 和 Content-Range、If-Range 不匹配时的完整 200、文件 hash、渠道缓存头、错误路径 404，以及原有 relay `/health` 和 WebSocket 路由未受影响。

首次基础设施阶段可使用明确命名的小测试文件验收 Range，测试文件不作为 APK 或更新清单。未发布真实渠道时，验收记录必须写明“基础设施就绪、更新渠道尚未发布”，不能声称应用在线升级已通过。

路由回滚时，还原保存的边缘配置，执行 `nginx -t` 并 graceful reload；确认原 relay 服务正常后，再停止独立静态项目。不要停止或重建整个 relay Compose 项目。

渠道一旦发布，客户端会保存最高信任的 `release_seq`，直接放回旧序号会触发防回放。内容回退应发布更高序号；APK 还必须使用更高 versionCode，资源回退则发布新的完整目标快照。保留旧配置与不可变制品用于分析，不能把删除服务端文件当作撤回已激活客户端内容的机制。

## 证书续期依赖

更新服务复用边缘 HTTPS 证书，其可用性依赖既有证书自动续期和续期后的 reload。若使用短有效期证书，应核实实际有效期、续期定时任务、挑战路径和失败告警，并验证更新路由没有遮挡挑战路径。证书到期时客户端会拒绝连接，不能通过关闭 TLS 校验补救。

部署期间仅核实并保留既有续期链路；续期工具或证书方案的变更应单独实施和验证。证书续期成功、边缘已加载新证书、远端系统信任链通过，是三个需要分别确认的结果。

## 2026-10-19 实际基础设施验收

独立静态容器已部署且健康，实际用户为 `101:101`、根文件系统只读、没有宿主机公开端口。现有边缘与 relay 容器的 ID、启动时间在部署前后一致；边缘只执行配置验证与平滑重载。

[verify_static_origin.py](../../tool/update/server/verify_static_origin.py) 对真实 HTTPS 服务完成 21 项检查：健康探针、系统 TLS 信任链、安全响应头、测试文件 hash、HEAD/ETag、Range 206、匹配与过期 If-Range、条件请求 304、不可变文件缓存、空渠道 no-store、隐藏与私有路径拒绝、目录索引限制、上传拒绝，以及原有 `/health`、`/v1/state`、`/v1/ws` 的预期响应。后两项为未鉴权 401，只证明路由仍在，不表示完整 PC 联动业务或带鉴权 WebSocket 会话已重新验收。

```powershell
python tool/update/server/verify_static_origin.py `
  --base-url <HTTPS_ORIGIN>/updates/agentatelier/ --check-relay
```

探针是明确命名的传输测试文本，不是 APK。`stable.json` 尚未发布，返回 404/no-store。客户端私有配置已加密校验并保留为忽略目录中的 pending 文件；正式配置未启用。Ed25519 私钥保留在本机仓库外，没有上传服务器。首个引导构建前应确认并备份此密钥，统一实际 `release_seq` 与 versionCode，再完成真实制品发布和设备更新验收。

已核实当前证书有效至 2026-10-25，既有 `agent-relay-cert-renew.timer` 有下一次运行计划；本次没有修改续期机制，也没有提前声称下一次续期必然成功。实际地址、密钥路径、服务器备份位置及详细验收 JSON 仅存于忽略的本地部署记录。

基础设施验收之后，已在隔离 `device-test` 渠道发布真实引导基线、资源和完整 APK 更新。Gitee 测试分支更新发现、17 个资源对象下载校验、重启激活及 Android 系统安装均已通过真机检查，实际已安装 build48 APK 的摘要与签名目标一致；见 [2026-10-19 真机测试记录](DEVICE_TEST_2026-10-19.md)。这些操作没有发布正式 `stable` 渠道，也没有更新 Gitee/GitHub Release 页面。
