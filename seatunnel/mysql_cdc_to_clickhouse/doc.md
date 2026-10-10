# 使用 SeaTunnel 实现 MySQL CDC 同步数据到 ClickHouse

> 适用版本：SeaTunnel 2.3.13（Zeta Engine，Hazelcast 5.1）
> 部署形态：Docker Compose（1 master + 2 worker + client）
> 覆盖范围：集群部署（含 checkpoint / map-store 持久化）→ 同步配置 → 提交与验证 → 重启恢复 / 全量重刷

## 概述

本文介绍如何用 Apache SeaTunnel 2.3.13 以 Docker 集群模式，实现 MySQL 数据基于 CDC（Change Data Capture，变更数据捕获）实时同步到 ClickHouse。

整体链路：**MySQL（Binlog）→ SeaTunnel（CDC Source + 字段转换）→ ClickHouse**，SeaTunnel 读取 MySQL Binlog 捕获数据变更，经字段类型转换后写入 ClickHouse。

构建时在流程中直接落实三个设计（而不是事后打补丁）：

| 问题 | 本方案的选择 | 落实位置 |
|------|--------------|----------|
| 重启后任务怎么办？ | checkpoint 快照 + Hazelcast IMap 双持久化，落宿主机卷：既能人工 `-r` 续跑，也能自动恢复 | 步骤 1 |
| 数据会重复吗？ | ClickHouse Sink 是 at-least-once；目标表统一 ReplacingMergeTree + 主键，查询侧用 `FINAL` 去重 | 步骤 4、7 |
| 怎么续跑、怎么全量重刷？ | 标准配置为"新提交 = 全量重建"（`RECREATE_SCHEMA`）；运行中故障恢复一律用 `-r <jobId>`，不触发重建 | 步骤 4、7 |

## 前置条件

| 组件 | 要求 |
|------|------|
| MySQL | 5.7+ 或 8.0+，需开启 Binlog（ROW 格式） |
| ClickHouse | 已部署并可访问 |
| Docker & Docker Compose | 已安装 |
| Claude Code | 已安装（用于 AI 生成同步配置） |

---

## 步骤 1：部署 SeaTunnel 集群（并规划好持久化）

### 1.1 集群角色说明

| 角色 | 职责 |
|------|------|
| **Master** | 集群协调者，负责任务调度、REST API 接口（提交/停止任务） |
| **Worker** | 工作节点，执行实际的数据同步任务 |
| **Client** | 命令行客户端，用于向集群提交同步任务 |

### 1.2 提取容器内默认配置

SeaTunnel 官方镜像内包含默认的 `config/` 和 `lib/` 目录。首次部署时，先将这些文件提取到宿主机，之后所有修改都在宿主机（挂载进容器）进行。

**方法一：使用临时容器提取（推荐）**

```bash
docker create --name seatunnel-temp apache/seatunnel:2.3.13
docker cp seatunnel-temp:/opt/seatunnel/config ./seatunnel/config
docker cp seatunnel-temp:/opt/seatunnel/lib ./seatunnel/lib
docker rm seatunnel-temp
```

**方法二：使用具名卷提取**

```bash
docker run -d --name seatunnel-temp \
  -v seatunnel_config:/opt/seatunnel/config \
  -v seatunnel_lib:/opt/seatunnel/lib \
  apache/seatunnel:2.3.13

cp -r /var/lib/docker/volumes/seatunnel_config/_data/* ./seatunnel/config/
cp -r /var/lib/docker/volumes/seatunnel_lib/_data/* ./seatunnel/lib/

docker rm -f seatunnel-temp
docker volume rm seatunnel_config seatunnel_lib
```

### 1.3 持久化规划：两类数据、两个目录

编写 docker-compose 之前，先明确两类必须持久化的数据（都不能放容器内 `/tmp` 或可写层）：

| 数据 | 配置位置 | 丢了会怎样 | 需要挂载的节点 |
|------|----------|------------|----------------|
| checkpoint 快照（`-r` 续跑用） | `seatunnel.yaml` → `engine.checkpoint.storage` | 无法续跑，`-r` 静默降级为全量重跑 | master（HA 下为所有 master 候选） |
| 任务台账 IMap（自动恢复用） | `hazelcast-master.yaml` / `hazelcast-worker.yaml` → `map.engine*.map-store` | master 不知道任务存在，重启后不会自动恢复 | master + 所有 worker |

部署时规划两个宿主机目录，从一开始就挂载进容器：

```
data/
├── seatunnel-checkpoint   # checkpoint 快照（挂载给 seatunnel_master）
└── seatunnel-imap         # 任务台账 IMap（挂载给 master + 所有 worker）
```

> ⚠️ 两个目录都必须挂载宿主机卷，**不要**用容器内 `/tmp` 或容器可写层：`docker compose down/up`、重建容器都会丢。checkpoint 丢失后 `-r` 不报错、直接静默全量重跑，是最隐蔽的坑之一。

### 1.4 配置 checkpoint 存储（seatunnel.yaml）

编辑 `seatunnel/config/seatunnel.yaml`：

```yaml
seatunnel:
  engine:
    classloader-cache-mode: true
    history-job-expire-minutes: 1440
    backup-count: 1
    queue-type: blockingqueue
    print-execution-info-interval: 60
    print-job-metrics-info-interval: 60
    slot-service:
      dynamic-slot: true
    checkpoint:
      interval: 60000            # 引擎默认值，任务 env 可覆盖
      timeout: 600000
      storage:
        type: hdfs
        max-retained: 10         # 保留最近 10 个 checkpoint，便于回退
        plugin-config:
          namespace: /seatunnel/checkpoint   # 与 1.3 的挂载目录对应
          storage.type: local
          fs.defaultFS: file:///
    telemetry:
      metric:
        enabled: false
      logs:
        scheduled-deletion-enable: true
    http:
      enable-http: true          # v2 REST API / Web UI（后文运维命令都基于它）
      port: 8080
      enable-dynamic-port: false
      enable-basic-auth: true
      basic-auth-username: admin
      basic-auth-password: <按实际>
```

`interval` / `timeout` 取值经验（任务 `env` 可覆盖引擎值，优先级更高）：

| 参数 | 建议值 | 权衡 |
|------|--------|------|
| interval | 15000~60000 | 越小，恢复时的重复窗口越小，但 checkpoint 开销越大；全量快照数据量特别大时可取大值打底 |
| timeout | 120000~600000 | 全量阶段必须给足（≥600000 更稳），否则 `CheckpointException: Checkpoint expired before completing` |

interval 偏小（如 10s 级）叠加全量阶段，会出现 checkpoint 开销大、容易堆积的问题；timeout 偏小则全量阶段直接超时失败。

> 8080 端口的 HTTP 服务需要配合步骤 1.6 的端口映射；启用 basic-auth 后，调用 API 需带 `-u admin:<password>`。

### 1.5 配置任务自动恢复（map-store）

只配 checkpoint 存储，重启后还需要人工 `-r`。要让集群重启后任务自动恢复，需要开启 Hazelcast IMap 持久化。

先弄清各角色实际加载哪个配置文件：

| 启动角色 | 使用的配置 |
|----------|-----------|
| `-r master` | `config/hazelcast-master.yaml` |
| `-r worker` | `config/hazelcast-worker.yaml` |
| 不带角色 / hybrid | `config/hazelcast.yaml` |

本部署中 master 执行 `seatunnel-cluster.sh -r master`、worker 执行 `-r worker`，所以只需修改 `hazelcast-master.yaml` 和 `hazelcast-worker.yaml`，在各自 `hazelcast:` 根节点下追加（**两个文件内容保持一致**）：

```yaml
  map:
    # 高频更新的监控类 IMap 必须排除在持久化之外（精确名优先于 engine* 通配）
    engine_runningJobMetrics:
      map-store:
        enabled: false
    engine_finishedJobMetrics:
      map-store:
        enabled: false
    engine_checkpoint_monitor:
      map-store:
        enabled: false
    engine*:
      map-store:
        enabled: true
        initial-mode: LAZY      # ⚠️ 必须 LAZY，不要用官方示例的 EAGER
        factory-class-name: org.apache.seatunnel.engine.server.persistence.FileMapStoreFactory
        properties:
          type: hdfs
          namespace: /seatunnel/imap        # 与 1.3 的挂载目录对应
          clusterName: seatunnel-cluster
          storage.type: hdfs
          fs.defaultFS: file:///
```

- `engine*` 通配所有任务台账 IMap；
- **⚠️ 上面三个 metrics/monitor map 绝不能持久化**：file map-store 是 append-only WAL，metrics 每几秒全量重写一次，磁盘会无限膨胀（生产实测 11 天涨到 71G 写满磁盘，导致 checkpoint 失败、任务被引擎自动 cancel，见 [磁盘写满事故复盘](../incident_disk_full/doc.md)）；这些数据是临时监控数据，重启丢失无影响。精确名配置优先于 `engine*` 通配，因此显式关闭即可；
- `initial-mode` 必须用 `LAZY`：官方示例里的 `EAGER` 会让 master 启动时抛 NPE、REST（8080）起不来（见"常见问题排查"）；
- master 和所有 worker 都要配置，且都能访问对应目录；
- 只接受人工 `-r` 续跑、不需要自动恢复时，可跳过本节，仅保留 1.4 的 checkpoint 存储。

### 1.6 Docker Compose 配置

创建 `docker-compose.yml`，部署 1 Master + 2 Worker + 1 Client：

```yaml
services:
  seatunnel_master:
    image: apache/seatunnel:2.3.13
    container_name: seatunnel_master
    environment:
      # 集群成员列表（所有 master 和 worker 节点）
      - ST_DOCKER_MEMBER_LIST=seatunnel_master:5801,seatunnel_worker_1:5801,seatunnel_worker_2:5801
    volumes:
      - ./seatunnel/config:/opt/seatunnel/config
      - ./seatunnel/lib:/opt/seatunnel/lib
      - ./data/seatunnel-checkpoint:/seatunnel/checkpoint   # checkpoint 快照
      - ./data/seatunnel-imap:/seatunnel/imap               # 任务台账 IMap
    entrypoint: >
      /bin/sh -c "
      /opt/seatunnel/bin/seatunnel-cluster.sh -r master
      "
    ports:
      - "5801:5801"   # Hazelcast 集群通信端口
      - "8080:8080"   # v2 REST API / Web UI
    networks:
      - backend

  seatunnel_worker_1:
    image: apache/seatunnel:2.3.13
    container_name: seatunnel_worker_1
    environment:
      - ST_DOCKER_MEMBER_LIST=seatunnel_master:5801,seatunnel_worker_1:5801,seatunnel_worker_2:5801
    volumes:
      - ./seatunnel/config:/opt/seatunnel/config
      - ./seatunnel/lib:/opt/seatunnel/lib
      - ./data/seatunnel-imap:/seatunnel/imap               # worker 同样需要 IMap
    entrypoint: >
      /bin/sh -c "
      /opt/seatunnel/bin/seatunnel-cluster.sh -r worker
      "
    depends_on:
      - seatunnel_master
    networks:
      - backend

  seatunnel_worker_2:
    image: apache/seatunnel:2.3.13
    container_name: seatunnel_worker_2
    environment:
      - ST_DOCKER_MEMBER_LIST=seatunnel_master:5801,seatunnel_worker_1:5801,seatunnel_worker_2:5801
    volumes:
      - ./seatunnel/config:/opt/seatunnel/config
      - ./seatunnel/lib:/opt/seatunnel/lib
      - ./data/seatunnel-imap:/seatunnel/imap
    entrypoint: >
      /bin/sh -c "
      /opt/seatunnel/bin/seatunnel-cluster.sh -r worker
      "
    depends_on:
      - seatunnel_master
    networks:
      - backend

  seatunnel-client:
    image: apache/seatunnel:2.3.13
    container_name: seatunnel-client
    environment:
      # Client 只需连接 Master 即可提交任务
      - ST_DOCKER_MEMBER_LIST=seatunnel_master:5801
    tty: true
    volumes:
      - ./seatunnel/config:/opt/seatunnel/config
      - ./seatunnel/lib:/opt/seatunnel/lib
    depends_on:
      - seatunnel_master
    networks:
      - backend

networks:
  backend:
    driver: bridge
```

说明：

- `5801` 只用于 Hazelcast 成员通信（成员列表由 `ST_DOCKER_MEMBER_LIST` 注入）。
- 旧版 v1 REST（5801）默认关闭且无鉴权，本方案统一走 8080 的 v2 REST（带 basic-auth）。v1 的开关是 `hazelcast-*.yaml` 的 `network.rest-api.enabled`，环境变量 `HZ_NETWORK_RESTAPI_ENABLED` 在 2.3.13 中无效。
- 不需要多 Worker 高可用时，可以只部署 1 个 Worker，并同步从 `ST_DOCKER_MEMBER_LIST` 中移除多余节点。
- HA 场景（多 master 候选）下，checkpoint / imap 目录必须换成所有候选节点都能访问的共享存储（NFS、HDFS 等）；本地目录只适用于本文这种单 master 部署。

### 1.7 启动与部署验证

```bash
docker compose up -d
```

按顺序验证，任何一步不过先解决再继续：

```bash
# 1) 确认节点实际加载的 hazelcast 配置（应为 master/worker 各自的文件）
docker exec seatunnel_master ps -ef | grep -o -- '-Dhazelcast.config=[^ ]*'
docker exec seatunnel_worker_1 ps -ef | grep -o -- '-Dhazelcast.config=[^ ]*'

# 2) master 启动日志无异常，集群 3 个成员都在
docker logs --tail 50 seatunnel_master
docker compose ps

# 3) v2 REST 可用（启用 basic-auth 后需 -u）
curl -s -u admin:<password> http://localhost:8080/overview | head -c 200

# 4) 持久化目录已挂载（此时还没有任务，目录为空是正常的）
docker exec seatunnel_master ls -l /seatunnel/checkpoint/ /seatunnel/imap/
```

---

## 步骤 2：安装字段转换插件

SeaTunnel 默认不支持 MySQL 数字时间戳到 ClickHouse 日期类型的自动转换，需要安装第三方 Transform 插件 [seatunnel-transform-fieldconvert](https://github.com/quansitech/seatunnel-transform-fieldconvert)。

**为什么需要此插件？**

MySQL 中常用 `int` / `bigint` 存储 Unix 时间戳（如 `1700000000`），ClickHouse 中对应字段通常是 `DateTime` / `DateTime64`；MySQL 的 `tinyint(1)` 与 ClickHouse 的布尔/整型语义也不一致。该插件提供：

- `unix_timestamp_to_datetime`：将数字时间戳转换为日期时间（可指定时区）
- `cast`：类型转换（如 MySQL 的 `tinyint(1)` 转 ClickHouse 的 `Int8`）

```bash
# 下载与 SeaTunnel 版本匹配的 jar 包
wget https://github.com/quansitech/seatunnel-transform-fieldconvert/releases/download/v2.3.13/seatunnel-transform-fieldconvert-2.3.13.jar \
  -O ./seatunnel/lib/seatunnel-transform-fieldconvert-2.3.13.jar

# 重启集群，让所有节点加载插件（lib 目录已挂载到 master/worker/client）
docker compose restart seatunnel_master seatunnel_worker_1 seatunnel_worker_2
```

> **重要：** 插件版本必须与 SeaTunnel 版本一致，否则可能出现兼容性问题。Transform 在 worker 上执行，插件 jar 必须出现在**所有节点**的 `lib/` 下；本方案通过宿主机目录统一挂载，天然满足。

---

## 步骤 3：配置 MySQL 开启 Binlog 并创建 CDC 账号

SeaTunnel 的 MySQL-CDC 连接器依赖 Binlog 进行变更数据捕获，必须确保 MySQL 已正确配置。

### 3.1 开启 Binlog

编辑 MySQL 配置文件（通常为 `/etc/my.cnf` 或 `/etc/mysql/mysql.conf.d/mysqld.cnf`），在 `[mysqld]` 段添加：

```ini
[mysqld]
# 1. 必须配置唯一的 Server ID（1 到 2^32-1 之间的整数）
#    注意：如果有多个 MySQL 实例被同一 SeaTunnel 集群同步，每个实例的 server-id 必须不同
server-id = 1

# 2. 开启 Binlog，并指定日志文件名前缀
log-bin = mysql-bin

# 3. 必须设置为 ROW 格式（CDC 无法解析 STATEMENT 或 MIXED 格式的完整数据）
#    注意：MySQL 8.0.17+ 默认已是 ROW 格式，此参数已被标记为弃用，
#    但为了兼容 MySQL 5.7，建议显式设置
binlog_format = ROW

# 4. 必须设置为 FULL（记录行变更前后的完整数据，便于 CDC 识别旧值与新值）
binlog_row_image = FULL

# 5. 推荐：设置 Binlog 过期时间（单位：秒），避免磁盘被占满
binlog_expire_logs_seconds = 604800
```

**修改后需要重启 MySQL 服务：**

```bash
systemctl restart mysql
# 或
systemctl restart mysqld
```

**验证 Binlog 是否生效：**

```sql
-- 检查 binlog 是否开启及格式
SHOW VARIABLES LIKE 'binlog_format';
-- 预期结果: ROW

SHOW VARIABLES LIKE 'log_bin';
-- 预期结果: ON

SHOW VARIABLES LIKE 'binlog_row_image';
-- 预期结果: FULL
```

### 3.2 创建 CDC 同步专用账号

为 SeaTunnel 创建独立账号，仅授予 CDC 同步所需的最小权限：

```sql
-- 1. 创建专门用于 CDC 同步的账号（便于权限管理和审计）
CREATE USER 'seatunnel_cdc'@'%' IDENTIFIED BY 'your_password';

-- 2. 授予必要权限
-- REPLICATION SLAVE  : 读取 Binlog 流（CDC 核心）
-- REPLICATION CLIENT : 查询主从状态信息
-- SELECT             : 读取表结构 + 全量快照阶段拉取数据
-- RELOAD             : 锁表或获取一致性全局位置（FLUSH TABLES）
-- SHOW DATABASES     : 遍历数据库名
GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT
  ON *.* TO 'seatunnel_cdc'@'%';

-- 3. 刷新权限使之生效
FLUSH PRIVILEGES;
```

---

## 步骤 4：生成并完善同步配置

### 4.1 使用 AI 快速生成配置

打开 [Claude Code](https://code.claude.com/)，在项目目录下执行以下命令，根据数据库结构自动生成同步配置：

> ⚠️ **安全提示：** 请使用开发环境的数据库账号来生成配置，**不要**直接使用生产数据库账号密码。

```bash
/generating-seatunnel-mysql-to-clickhouse-config 帮我生成 donation 数据库的 ClickHouse 同步配置，MySQL 数据库地址 localhost 用户名 root 密码 root
```

该命令会：

1. 连接 MySQL 读取表结构（自动排除视图和框架系统表）
2. 识别需要类型转换的字段（时间戳字段、`is_*` 的 tinyint 字段）并生成 FieldConvert 转换规则
3. 检测无主键的表并给出警告（无主键无法用 ReplacingMergeTree 模板）
4. 生成完整的 HOCON 配置文件

### 4.2 更新数据库连接信息

生成配置后，将 MySQL 连接信息更新为步骤 3 创建的 CDC 专用账号，并补充 ClickHouse 连接信息：

```hocon
source {
  MySQL-CDC {
    username = "seatunnel_cdc"           # 改为 CDC 专用账号
    password = "your_password"            # 改为 CDC 账号密码
    base-url = "jdbc:mysql://<mysql_host>:<mysql_port>"
    server-id = 5656                      # 必须唯一，不能与 MySQL 的 server-id 冲突
    # ...其余配置由 AI 自动生成
  }
}

sink {
  Clickhouse {
    host = "<clickhouse_host>:8123"       # ClickHouse HTTP 接口地址
    database = "<database>"
    username = "<ck_user>"
    password = "<ck_password>"
    # ...其余配置由 AI 自动生成
  }
}
```

> **关于 `server-id`：** 这是 CDC 连接器在 MySQL 中注册的身份标识，必须全局唯一。凡是有多个同步任务或多个 SeaTunnel 实例同步同一 MySQL，每个任务的 `server-id` 都必须不同，否则会互相干扰（建议建立分配台账）。

### 4.3 补全 env：checkpoint 参数与启动模式

AI 生成的配置只有 source / transform / sink，需要补上 `env` 块，把 checkpoint 参数与启动模式显式写出来（不要让关键行为"默认"）：

```hocon
env {
  parallelism = 2
  job.mode = "STREAMING"

  # 任务级 checkpoint 参数，覆盖 seatunnel.yaml 的引擎默认值
  checkpoint.interval = 15000     # 15s：恢复重复窗口与它成正比（见步骤 7.1）
  checkpoint.timeout = 600000     # 10min：全量阶段最容易超时，给足
}

source {
  MySQL-CDC {
    ...
    startup.mode = "initial"      # 默认值；新 job 先全量快照，再持续读 binlog
  }
}
```

> interval 取 15s（与生产任务一致）：好处是恢复重复窗口小，代价是 checkpoint 开销略高；全量数据量特别大、checkpoint 频繁超时或堆积时，可先把任务级 interval 放宽到 60000 降低压力。

`startup.mode` 决定**新提交一个 job 时的数据起点**，是"全量重刷 / 恢复"语义的源头：

| 值 | 含义 |
|----|------|
| `initial`（默认） | 先全量快照现存数据，再接着读 binlog |
| `earliest` | 只从 binlog 最早位点开始，不补历史快照 |
| `latest` | 只从当前位点开始，历史数据全部跳过 |
| `specific` / `timestamp` | 从指定 binlog 位置 / 时间开始 |

> 想全量重刷就保持 `initial`；**不要**为了"避免重复"改成 `latest`——那会跳过停机期间的所有变更（丢数据，不是去重）。

### 4.4 ClickHouse Sink：标准配置（新提交即全量重建）

标准做法：**新 job 提交时重建目标表并全量重跑，随后持续消费 binlog**。AI 生成的配置默认是 `CREATE_SCHEMA_WHEN_NOT_EXIST`（只建缺失表、只追加），按本方案改成下面这样（关键部分）：

```hocon
sink {
  Clickhouse {
    ...
    # 标准：新 job 提交时 DROP 目标表 → 按模板重建 → 配合 startup.mode=initial 全量快照
    schema_save_mode = "RECREATE_SCHEMA"
    data_save_mode  = "APPEND_DATA"      # 表刚重建，无需再清数据

    # 动态占位符：每张表自动用上游主键建 RMT
    primary_key = "${primary_key}"

    save_mode_create_template = """
CREATE TABLE IF NOT EXISTS `${database}`.`${table}` (
${rowtype_primary_key},
${rowtype_fields}
) ENGINE = ReplacingMergeTree()
ORDER BY (${rowtype_primary_key})
PRIMARY KEY (${rowtype_primary_key})
SETTINGS index_granularity = 8192
"""

    # 启用轻量级删除，支持 CDC 的 DELETE 事件
    allow_experimental_lightweight_delete = true
  }
}
```

配合 4.3 的 `startup.mode = "initial"` 和足够的 `checkpoint.timeout`，一次"停旧 job → 新提交"就是一次干净的全量重建，不会在旧数据上追加。

运行中的任务出故障时用 `-r <jobId>` 续跑即可：`-r` 不执行 save mode，不会重建/清表（执行时机见下表）。

> ⚠️ `RECREATE_SCHEMA` 在**每次新提交**时都会执行：全量重刷 = 直接新提交；恢复运行中的任务必须用 `-r`，不要随便重新提交。

按需替换为其他组合：

| 场景 | 配置 |
|------|------|
| 保留目标表结构，只清数据后重跑 | `CREATE_SCHEMA_WHEN_NOT_EXIST` + `DROP_DATA`（`TRUNCATE`） |
| 新提交时不清数据、只追加 | `CREATE_SCHEMA_WHEN_NOT_EXIST` + `APPEND_DATA`（AI 生成的默认组合） |
| 防呆：目标表有数据时直接报错 | `data_save_mode = "ERROR_WHEN_DATA_EXISTS"` |

注意点：重建/清表需要 ClickHouse 账号有 `DROP` / `TRUNCATE` 权限；`RECREATE_SCHEMA` 会丢表上的自定义 DDL（额外列、物化视图、TTL 等），且 DROP 发生在 job 启动最开头，全量跑一半失败时表是空/半截的，需要重跑成功。数据量特别大时，`DROP + CREATE` 通常比 `TRUNCATE` 更彻底也更快。

建表模板必须是 ReplacingMergeTree（RMT）：

- Sink 是 at-least-once（见步骤 7.1），恢复/重跑会产生重复行，靠 RMT 按主键后台 merge 收敛；
- `allow_experimental_lightweight_delete = true` 用于承接 CDC 的 DELETE 事件；
- 裸 `ReplacingMergeTree()` 不保证"留最新"，时间敏感的表建议加版本列；已有表若是普通 MergeTree，重复行不会收敛（验证见步骤 6.3）。

save mode 执行时机：

| 启动方式 | 行为 |
|----------|------|
| 新提交 job | 完整执行 `schema_save_mode` + `data_save_mode`（标准配置 = DROP + 重建） |
| `-r <jobId>` 续跑 | 只做"不存在才建"（`RECREATE_SCHEMA` 被降级），`data_save_mode` 完全不执行——**续跑永远不会清表** |

> 多表场景：`table = "${table_name}"` 动态模板会在配置解析阶段把 `table-names` 展开成每张表一个 sink，**逐表**执行 save mode，无需一张张配置。

### 4.5 放置配置文件

```bash
cp mysql_to_clickhouse_donation.conf ./seatunnel/config/
```

后续步骤使用的都是这个文件名。

---

## 步骤 5：在 ClickHouse 中预先创建数据库

同步任务启动前，需要先在 ClickHouse 中创建与 MySQL 同名的数据库。SeaTunnel 的 `schema_save_mode` 会自动创建表结构，但**不会自动创建数据库**。

```sql
-- 连接到 ClickHouse，创建与 MySQL 同名的数据库
-- 例如 MySQL 中数据库名为 donation，则 ClickHouse 中也创建 donation
CREATE DATABASE IF NOT EXISTS donation;
```

同步多个数据库时，每个都需要创建：

```sql
CREATE DATABASE IF NOT EXISTS db_name_1;
CREATE DATABASE IF NOT EXISTS db_name_2;
```

> **权限提示：** 标准配置（`RECREATE_SCHEMA`）需要目标库的建表权限 + `DROP` 权限；改用 `DROP_DATA` 时需要 `TRUNCATE` 权限。
> 如果未提前创建数据库，任务启动时会报类似 `Database xxx doesn't exist` 的错误。

---

## 步骤 6：提交任务与运行验证

### 6.1 提交首次同步任务

```bash
# 在 client 容器中提交同步任务到集群
# --async：提交后客户端退出，任务留在集群
# -d：docker exec 后台运行
docker exec -d seatunnel-client \
  ./bin/seatunnel.sh \
    --async \
    -c ./config/mysql_to_clickhouse_donation.conf \
    -m cluster
```

新提交 = 全新 jobId：按 4.4 标准配置先 DROP/重建目标表，再做全量快照（`startup.mode=initial`），随后持续消费 binlog。第一次全量阶段数据量大，重点观察 checkpoint 是否按配置的 timeout 稳定完成。

三种提交方式的区别（别踩坑）：

| 方式 | 任务生命周期 |
|------|--------------|
| CLI 前台提交（默认 `-cj=true`） | **客户端退出会把任务一起取消** |
| CLI `--async`（或 `-cj false`） | 提交后客户端退出，任务留在集群 |
| REST `POST /submit-job` | 集群托管，HTTP 断开不影响任务，适合 CI/脚本 |

> 无论哪种方式，任务都跑在集群上；差异只在"提交后客户端退出会不会取消任务"。常驻的 STREAMING 任务推荐 `--async` 或 REST。

### 6.2 查看任务与 checkpoint

```bash
# 运行中的任务
curl -s -u admin:<password> http://localhost:8080/running-jobs

# 任务详情（jobStatus / errorMsg / metrics）
curl -s -u admin:<password> http://localhost:8080/job-info/<jobId>

# checkpoint 概览：triggered / completed / failed / inProgress / restored
curl -s -u admin:<password> http://localhost:8080/jobs/checkpoints/<jobId>

# checkpoint 历史（可按状态过滤）
curl -s -u admin:<password> 'http://localhost:8080/jobs/checkpoints/history/<jobId>?limit=10&status=COMPLETED'
```

`restored` = 该任务从 checkpoint 恢复启动过几次。后续验证续跑是否真的从 checkpoint 恢复，就看它 +1、checkpoint 编号延续。

> 插件仓库的 `scripts/` 目录提供了两个运维脚本，封装上述接口并格式化输出：`show_jobs.sh`（任务状态 + 每表读写积压，一眼定位卡住的表）、`show_checkpoints.sh`（checkpoint 计数、耗时与间隔统计），日常排查推荐直接使用。

**注意：checkpoint 全绿 ≠ 数据在流动。** 判断同步是否正常要同时看：

- `SourceReceivedCount` / `SinkWriteCount` 是否在涨（`/job-info/<jobId>` 的 metrics）；
- `IntermediateQueueSize` 是否持续满且不下降（低峰期源端静默后仍不排空 = 卡住）；
- 必要时查 Sink 线程栈和 ClickHouse 侧状态（负载、写入报错）。

### 6.3 验证 ClickHouse 表结构与去重

```bash
# 所有目标表都应为 ReplacingMergeTree（输出为空即全部达标）
clickhouse-client --query "
SELECT database, name, engine, sorting_key
FROM system.tables
WHERE database IN ('donation')
  AND engine != 'ReplacingMergeTree'"

# 重复 / 去重效果（RMT 去重是异步的，加 FINAL 才是稳定结果）
clickhouse-client --query "SELECT count() FROM donation.qs_donation"
clickhouse-client --query "SELECT count() FROM donation.qs_donation FINAL"
```

### 6.4 验证持久化已生效

```bash
# checkpoint 文件按 jobId 落盘
docker exec seatunnel_master ls -l /seatunnel/checkpoint/<jobId>/ | tail

# IMap 任务台账文件
docker exec seatunnel_master ls -l /seatunnel/imap/ | head
```

---

## 步骤 7：日常运维：重启、恢复与全量重刷

### 7.1 先理解：重复从哪来（at-least-once）

ClickHouse Sink 是 at-least-once：数据在 checkpoint 完成前就已落表，恢复时"最近一次成功 checkpoint 之后"的数据会被重放：

```
单次恢复的重复窗口 ≈ checkpoint.interval + 未刷批的内存数据
```

所以本方案不追求"零重复"，而是 **RMT + 主键收敛重复，查询侧 `FINAL` 拿到稳定结果**（原理细节见文末"深入阅读"）。

### 7.2 三种"重启"方式的重复范围

| 重启方式 | 是否重复 | 重复范围 | 数据来源 |
|----------|----------|----------|----------|
| 新提交一个 job（新 jobId） | 会，**全量** | 标准配置先 DROP/重建表，再做全量快照，之后接着读 binlog | `RECREATE_SCHEMA` + `startup.mode=initial` |
| `--async -r <jobId>` 续跑 | 会，**小范围** | 最近一次成功 checkpoint 之后已写入的数据被重放（不重建/清表） | checkpoint 里的 binlog 位点 |
| `-r` 但 checkpoint 文件已丢 | 会，**全量** | 找不到 checkpoint 时不报错，**静默降级**为恢复模式的全新任务：save mode 不执行，直接在现有数据上再做一次全量快照 | 无 |

第三行正是 1.3 中"目录必须挂宿主机卷"的根本原因。

### 7.3 恢复操作手册

**(1) 任务失败 / 集群重启后的恢复**

```bash
# 停止任务（v2 REST；也可用 CLI：./bin/seatunnel.sh -can <jobId>）
curl -s -u admin:<password> -X POST http://localhost:8080/stop-job \
  -H 'Content-Type: application/json' \
  -d '{"jobId": "<jobId>", "isStopWithSavePoint": false}'

# 从最近一次成功 checkpoint 续跑（--async 不能省，否则客户端退出会取消任务）
docker exec -d seatunnel-client \
  ./bin/seatunnel.sh --async -r <jobId> -c ./config/mysql_to_clickhouse_donation.conf -m cluster
```

- 续跑必须使用**同一份任务配置**；
- 没配 map-store：集群/服务器重启后按上面人工恢复；
- 配了 map-store（步骤 1.5）：master 启动会自动从 IMap 拉起任务并从最近 checkpoint 续跑，无需人工；
- SeaTunnel 2.3.13 **没有内置的任务失败自动重试**：checkpoint 出错会把 pipeline 置为 CANCELING，任务最终 FAILED，需要人工恢复；
- 只重启了某个 worker（master 存活）：该节点上的任务 FAILED，同样人工恢复。

**(2) 全量重刷（换配置、修数据、目标数据损坏）**

标准配置（4.4 的 `RECREATE_SCHEMA`）就是"新提交即全量重建"，重刷不需要改配置：

```bash
# 先停止旧 job，再用同一份 conf 重新提交（新 jobId，绝不能带 -r）
docker exec -d seatunnel-client \
  ./bin/seatunnel.sh --async -c ./config/mysql_to_clickhouse_donation.conf -m cluster
```

如果之前按需改成了 `CREATE_SCHEMA_WHEN_NOT_EXIST + APPEND_DATA`（不清数据），重刷前先临时改回 `RECREATE_SCHEMA`（或 `DROP_DATA`）。重建/清表的注意点见 4.4。

**(3) 全量快照跑失败后怎么办**

不要用 `-r` 去"续"一个还没产生 checkpoint 的全量任务：checkpoint 不存在时它会重新快照，但 `-r` 不清表，失败前已写入的部分数据会和新快照重复（RMT 最终能按主键收敛，但查询要 `FINAL`）。直接重新提交新 job：标准配置会先 DROP/重建，再从头全量重跑。

**(4) 查询侧一致性**

- 常规查询统一带 `FINAL`：`SELECT ... FROM db.t FINAL WHERE ...`，或对主键做 `argMax` 聚合；
- 非高频表可定期 `OPTIMIZE TABLE db.t FINAL` 立即收敛（大表慎用，开销大）；
- 对时间敏感的表，建表时带版本列（如 `ReplacingMergeTree(version)`），保证"留最新"。

### 7.4 运维命令速查

以下命令的 REST 地址默认 `http://localhost:8080`，均需 `-u admin:<password>`。

| 操作 | 命令 / 接口 |
|------|-------------|
| 提交新任务 | `seatunnel.sh --async -c config/xxx.conf -m cluster` |
| 续跑任务 | `seatunnel.sh --async -r <jobId> -c config/xxx.conf -m cluster` |
| 取消任务 | `POST /stop-job`，或 `seatunnel.sh -can <jobId>` |
| 运行中任务 | `GET /running-jobs` |
| 已结束任务 | `GET /finished-jobs/<STATE>`（FAILED / FINISHED / CANCELED …） |
| 任务详情 | `GET /job-info/<jobId>` |
| checkpoint 概览 / 历史 | `GET /jobs/checkpoints/<jobId>`、`GET /jobs/checkpoints/history/<jobId>?limit=&status=` |
| 集群概览 | `GET /overview` |

---

## 常见问题排查

### 部署 / 启动

| 现象 | 原因 / 处理 |
|------|-------------|
| 容器 Up 但 8080 连不上，master 日志有 `CheckpointMonitorService ... NullPointerException` | map-store 用了 `initial-mode: EAGER` → 改为 `LAZY` 后重启 master 与 worker（2.3.13 + Hazelcast 5.1 下 EAGER 会导致启动 NPE，官方示例即 EAGER） |
| `Access denied for user` | CDC 账号权限不足 → 检查步骤 3 的授权 |
| `binlog_format is not ROW` | MySQL Binlog 格式不对 → 步骤 3 |
| `server-id conflicts` | 多个 CDC 任务使用了相同 server-id → 保证全局唯一 |
| `Database xxx doesn't exist` | ClickHouse 未预建库 → 步骤 5 |
| `table doesn't exist` | 目标表未建 / 模板未生效 → 确认 `schema_save_mode` 与目标库是否已创建 |

### 运行 / checkpoint

| 现象 | 原因 / 处理 |
|------|-------------|
| 全量同步后无增量数据 | 检查 Binlog 是否正常写入（`SHOW BINARY LOGS;`）、Worker 日志、binlog 是否被清理（`binlog_expire_logs_seconds`） |
| `Checkpoint expired before completing` | `checkpoint.timeout` 太小 / Sink 写入慢 → 调大 timeout（任务 env 生效），检查 ClickHouse 负载 |
| checkpoint 全绿但数据不流动 | Sink 可能已卡住 → 看 Source/Sink 计数、`IntermediateQueueSize`、Sink 线程栈与 CH 状态 |
| 任务停止时出现一条 `latestFailed: Pipeline turn to end state.` | 正常伴生现象；随后的 `restored +1` 就是一次恢复 |
| `/jobs/checkpoints` 里 `state: 3` | 正常值（不是字节数），小而稳定即可 |
| 历史任务查不到 | 已结束任务只保留 `history-job-expire-minutes`（默认 1440 分钟 = 24h） |

### 恢复 / 数据重复

| 现象 | 原因 / 处理 |
|------|-------------|
| 集群重启后任务消失 | 没配 map-store → 人工 `-r` 续跑或重新提交 |
| 自动恢复 / `-r` 后从全量重新开始 | checkpoint 文件丢失/不可访问（容器重建、路径未挂载、换了存储）→ 静默降级，检查 1.3 / 1.4 |
| ClickHouse 中数据重复 | at-least-once 的正常现象 → 查询带 `FINAL`；确认表是 RMT；必要时 `OPTIMIZE TABLE ... FINAL` |
| 重复行一直不收敛 | 表不是 RMT（历史遗留 MergeTree），或查询没带 `FINAL` |
| 全量重刷后表结构变简单了 | `RECREATE_SCHEMA` 按模板重建，自定义 DDL（额外列、物化视图、TTL）丢失 → 重刷后按需补建 |

---

## 深入阅读（按需查阅）

本文只保留构建流程与操作手册；原理、源码核实与生产事故复盘见以下两篇：

- [SeaTunnel Checkpoint 持久化与恢复实践](../checkpoint_persistence/doc.md)：checkpoint / map-store 原理、EAGER 事故完整日志与根因链、恢复行为矩阵
- [SeaTunnel 任务重启的重复写入与全量重跑配置](../job_restart_full_reload/doc.md)：at-least-once 证据、三种重启方式、save mode 全量对比

## 参考资料

- [Apache SeaTunnel 官方文档](https://seatunnel.apache.org/docs/2.3.13/about)
- [SeaTunnel MySQL-CDC 连接器文档](https://seatunnel.apache.org/docs/2.3.13/connector-v2/source/MySQL-CDC)
- [SeaTunnel ClickHouse Sink 文档](https://seatunnel.apache.org/docs/2.3.13/connector-v2/sink/Clickhouse)
- [seatunnel-transform-fieldconvert 插件](https://github.com/quansitech/seatunnel-transform-fieldconvert)
