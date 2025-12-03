# Docker 容器网络故障与 getaddrinfo 崩溃排查复盘

## 故障背景

在 Ubuntu 16.04 (Kernel 4.4) 宿主机上部署 Thumbor 图片服务时，外部请求返回 HTTP 500。

*   **宿主机环境**: Ubuntu 16.04.5 LTS / Kernel 4.4.0-93-generic
*   **容器镜像**: `ghcr.io/minimalcompact/thumbor:latest` (基于 Alpine Linux)
*   **现象**: Nginx 反代正常，但访问具体图片链接时直接报错 500。

## 排查步骤与分析逻辑

### 1. 区分 HTTP 状态码含义
首先检查 Nginx 日志，发现返回码为 **500 Internal Server Error**，而非 502 Bad Gateway。

*   **分析重点**:
    *   **502**: 通常代表网络层不可达，Nginx 无法连接到容器端口。
    *   **500**: 代表请求已成功到达容器，但容器内部程序处理时发生了崩溃或异常。
    *   **结论**: 排除 Nginx 到 Docker 的端口映射问题，故障点锁定在容器内部。

### 2. 容器内部网络测试
进入容器尝试访问外网，发现即便是简单的 `curl` 也会报错。

*   **测试命令**: `curl -vvv http://www.xxx.com`
*   **错误信息**:
    ```text
    getaddrinfo() thread failed to start
    * Could not resolve host: www.xxx.com
    ```
*   **尝试无效方案**:
    *   修改容器 DNS (8.8.8.8) -> 无效。
    *   配置 `extra_hosts` 写入 hosts 文件 -> 无效。
    *   检查宿主机 IPv4 转发 -> 正常。

### 3. 核心错误信息定位
**`getaddrinfo() thread failed to start`** 是本案的决定性证据。

*   **分析重点**:
    *   这不是常规的“域名解析超时”或“无法连接 DNS 服务器”。
    *   该报错表明程序在调用底层系统接口（getaddrinfo）去创建一个解析线程时，被操作系统直接拒绝或拦截了。
    *   即使配置了本地 hosts，程序在读取 hosts 之前就已经因为线程创建失败而崩溃，因此任何网络层面的配置（DNS/Hosts/Firewall）都无法修复此问题。

### 4. 根因分析：Alpine 与旧内核的兼容性陷阱
这是典型的 **New Alpine Image + Old Host Kernel** 兼容性问题。

*   **技术原理**:
    *   `ghcr.io/minimalcompact/thumbor` 镜像基于 **Alpine Linux**。Alpine 使用 `musl libc` 作为标准库。
    *   新版 Alpine 为了支持时间戳修复（Y2038问题）及性能优化，在进行 DNS 解析或线程创建时，会使用较新的 Linux 系统调用（System Calls，如 `clone3` 或特定 socket 调用）。
    *   宿主机运行在 **Linux Kernel 4.4** (Ubuntu 16.04)，内核版本较老。
    *   Docker 的默认安全配置文件（Seccomp Profile）在旧内核上无法识别这些新的系统调用，默认策略将其判定为“未授权操作”并进行拦截（返回 EPERM），导致线程创建失败。

## 解决方案

在不升级宿主机内核的前提下，必须放宽 Docker 对该容器的系统调用拦截。

修改 `docker-compose.yml`，为服务添加 `security_opt` 配置：

```yaml
services:
  thumbor:
    image: xxx
    # 关键配置：禁用 Seccomp 默认拦截文件，允许容器使用所有系统调用
    security_opt:
      - seccomp:unconfined
```

## 总结

1.  **排查方向**: 遇到容器网络问题，若 `curl` 报 `thread failed` 类错误，应立即停止排查网络路由，转而排查系统兼容性。
2.  **环境警示**: 在 CentOS 7 或 Ubuntu 16.04 等老旧宿主机上运行基于 **Alpine** 的最新镜像时，极易触发此类 Seccomp 拦截问题。
3.  **修复策略**: 针对此类底层系统调用拦截导致的崩溃，`seccomp:unconfined` 是最快且有效的临时解决方案。

## 参考链接
[Docker seccomp](https://docs.docker.com/engine/security/seccomp/)