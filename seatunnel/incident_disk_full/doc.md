# SeaTunnel 磁盘写满致任务中断：事故复盘与恢复 SOP

> 适用版本：SeaTunnel 2.3.13（Zeta Engine，Hazelcast 5.1）
> 部署形态：Docker Compose（1 master + 2 worker + client），map-store 与 checkpoint 均落宿主机本地盘
> 整理时间：2026-10-10，基于当日生产事故
> 相关文档：[Checkpoint 持久化与恢复实践](../checkpoint_persistence/doc.md)、[任务重启的重复写入与全量重跑](../job_restart_full_reload/doc.md)

---

## 1. 事故经过

两个 CDC 任务（marathon_2、donation）持续运行 11 天后，发现 ClickHouse 数据停在昨晚。

| 时间（北京） | 事件 |
|---|---|
| 10/9 21:41 | 最后一个成功的 checkpoint（16083 / 15937） |
| 10/9 21:43 起 | **磁盘写满**：checkpoint 只能建 0 字节 `.sertmp`，持续失败 |
| 10/10 02:38 | 引擎自动 cancel 两个任务（checkpoint 失败 → CANCELING → CANCELED），删除标记写入 running 台账 |
| 10/10 09:46 | 发现磁盘满：停集群、删 71G 的 metrics 文件、关 metrics 的 map-store、重启 |
| 10/10 10:12 | 重启后 running-jobs 为空 |
| 10/10 12:15 | `-r` 恢复 → 任务**假 RUNNING 卡死**（见 3.2） |
| 10/10 13:18 | 清空 running 台账后重新 `-r` → 从 checkpoint 16083/15937 恢复 → 追平 15.6 小时积压 |

## 2. 根因

**`engine_runningJobMetrics` 开了 map-store 持久化。** file map-store 是 **append-only WAL**（源码注释自述"不适合高频更新场景"），metrics 每几秒全量重写一次 → 磁盘线性膨胀 → 11 天写满 → checkpoint 写不动 → 超时失败 → 任务被引擎 cancel。

## 3. 两个反直觉的机制点

### 3.1 任务一结束，"自动恢复"就不存在了

- 任务进入结束态时 `JobMaster.cleanJob()` 会把**自己从 `engine_runningJobInfo` / `engine_runningJobState` 删掉**（WAL 追加删除标记）；重启恢复只捞台账里还活着的任务，读到删除标记 = 跳过
- 非 savepoint 的 FINISHED/CANCELED 还会删 checkpoint 目录（`CheckpointManager.clearCheckpointIfNeed`）；本次因磁盘满删除未成功，checkpoint 侥幸存活，成为唯一恢复锚点
- 磁盘满时各写操作成败不一：本次**删除标记落盘了、finishedJobState 没落盘** → 出现"finished-jobs 查不到、running-jobs 也没有"的假象
- 顺带更正旧文档：checkpoint 失败的路径最终状态是 **CANCELED**，不是 FAILED

### 3.2 死在半取消状态的任务，`-r` 恢复会假 RUNNING

崩溃时正处于 CANCELING 中间态的任务，脏 task 状态（如 SplitEnumerator=CANCELING）会被持久化；`-r` 恢复时连同脏状态读回 → 状态机卡死：

- 表象：RUNNING，但 worker 无部署日志、checkpoint 不推进、metrics 恒 0/0
- stop-job 也杀不掉（`current state equals target state: CANCELING, skip`）
- 判活方法：`GET /jobs/checkpoints/<jobId>` 的 `latestCompleted.triggerTimestamp` 停在恢复之前 = 卡死

## 4. 恢复 SOP

前提：checkpoint 目录里还有该 jobId 的 `.ser` 文件。

```bash
# 0. 备份 checkpoint（唯一不可替代的锚点，含 binlog 位点）
cp -r data/seatunnel-checkpoint data/seatunnel-checkpoint.bak

# 1. 先试正常取消；若卡在 CANCELING（假 RUNNING），走物理清理
curl -u 'admin:***' -X POST http://localhost:8080/stop-job \
  -H 'Content-Type: application/json' -d '{"jobId":"<jobId>","isStopWithSavePoint":false}'

# 2. 停集群，删运行台账（不动 finished 历史，不动 checkpoint）
docker compose stop seatunnel_master seatunnel_worker_1 seatunnel_worker_2
cd data/imap/seatunnel-cluster
rm -rf engine_runningJobInfo engine_runningJobState engine_stateTimestamps engine_ownedSlotProfilesIMap

# 3. 启集群，确认成员就绪
docker compose start seatunnel_master seatunnel_worker_1 seatunnel_worker_2

# 4. 原 jobId 从最近 checkpoint 续跑（配置必须与原来一致，--async 不能省）
docker exec -it seatunnel-client /opt/seatunnel/bin/seatunnel.sh \
  --async -r <jobId> -c /opt/seatunnel/config/<原配置>.conf
```

恢复成功的标志（缺一不可）：

1. 日志 `start with savePoint on checkPointId(N)`，N = 磁盘上最后一个 `.ser` 的编号
2. 转 RUNNING **之后**还有 slot 分配、task 级 DEPLOYING→RUNNING 日志
3. `READER_MESSAGE_DELAYED` 事件的 `delayTime` 持续下降（降到秒级 = 追平）
4. `GET /jobs/checkpoints/<jobId>` 的 completed 计数持续上涨

数据影响：最后 checkpoint 之后已写入的数据会重放一遍（at-least-once），RMT 表后台 merge 去重；查询侧短期重复可加 `FINAL`。

## 5. 磁盘取证手法（日志已轮转时）

WAL 是 protobuf 序列化，但字符串明文可见。文件布局：`<namespace>/<clusterName>/<map名>/<region>/wal.txt`。

```bash
find engine_runningJobInfo -name "*.wal.txt" -exec ls -la {} +   # 看大小与 mtime
strings <wal.txt> | grep -E "<jobId>|<表名>"                      # 确认数据在不在
strings -t d <wal.txt> | tail -30                                 # 尾部=最新记录
```

判读要点：

- region 目录的 mtime 只是"进程启动时建目录"，不代表数据写入时间
- 文件尾部孤立的 `java.lang.Long` 记录（只有 key 没有 value blob）= **删除标记**
- checkpoint 文件名 `<时间戳ms>-<随机>-<pipelineId>-<checkpointId>.ser`，`.sertmp` 是失败/进行中残留；编号 × interval 可反推任务连续运行时长

## 6. 预防清单

| 措施 | 做法 |
|---|---|
| metrics 不持久化（本次已修） | `hazelcast-master.yaml` / `hazelcast-worker.yaml` 中 `engine_runningJobMetrics`、`engine_finishedJobMetrics` 单独配 `map-store.enabled: false`（精确名优先于 `engine*` 通配；两个文件都要改） |
| monitor 不持久化 | 同上，加 `engine_checkpoint_monitor`（监控类数据，会持续膨胀） |
| 磁盘告警 | 监控宿主机数据盘使用率，70%/85% 两级 |
| 任务存活告警 | cron 调 `/overview`，`runningJobs` 掉 0 即告警（本次任务死了 8 小时才被发现） |
| checkpoint 停滞告警 | `/jobs/checkpoints/<jobId>` 的 `latestCompleted` 长时间不更新 = 假死信号 |

## 7. 一句话总结

checkpoint 存储保的是"位点"，map-store 保的是"台账"；两者健在时，任务死得再难看也能 `-r` 续跑。真正的杀手是磁盘——append-only WAL 面前，高频更新的 map 一律不配持久化。
