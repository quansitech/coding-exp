# SeaTunnel Master 重启后任务变 UNKNOWABLE：LAZY 加载竞争与处置 SOP

> 适用版本：SeaTunnel 2.3.13（Zeta Engine，Hazelcast 5.1）
> 部署形态：Docker Compose（1 master + 2 worker + client），map-store 开启（`initial-mode: LAZY`）
> 整理时间：2026-10-10，基于当日生产事故（同日第二起）
> 相关文档：[磁盘写满事故复盘](../incident_disk_full/doc.md)、[Checkpoint 持久化与恢复实践](../checkpoint_persistence/doc.md)

---

## 1. 现象

手动重启 master（为应用 hazelcast 配置）后，`/running-jobs` 里两个任务一个 `RUNNING`、一个 `UNKNOWABLE`：

```
1156922855217168385  RUNNING
1156885613757071361  UNKNOWABLE
```

UNKNOWABLE 的任务实际没有在跑（worker 日志静默），但台账里还有它——**僵尸状态**。

## 2. 排查过程

```bash
# master 是否重启过
docker inspect seatunnel_master --format '{{.State.StartedAt}}'

# 找恢复失败日志（关键：堆栈在 ERROR 行下面，要 -A 展开）
docker logs seatunnel_master 2>&1 | grep -A 40 "init failed"

# 确认 worker 上没有遗留的孤儿任务还在跑（避免重提交后双写）
docker logs seatunnel_worker_1 --since 60m 2>&1 | grep "<jobId>" | tail -3
docker logs seatunnel_worker_2 --since 60m 2>&1 | grep "<jobId>" | tail -3
```

拿到的完整堆栈：

```
ERROR CoordinatorService - Job id 1156885613757071361 init failed
Caused by: com.hazelcast.spi.exception.RetryableHazelcastException:
  Map engine_ownedSlotProfilesIMap is still loading data from external store
    at PhysicalVertex.getOwnedSlotProfilesByTaskGroup
    at PhysicalVertex.checkTaskGroupIsExecuting
    at PhysicalVertex.initStateFuture
    at JobMaster.initStateFuture
    at CoordinatorService.restoreJobFromMasterActiveSwitch
```

## 3. 机制解析

### 3.1 为什么失败

`initial-mode: LAZY` 下，IMap 数据在**首次访问时**才从 map-store 磁盘加载。master 启动后恢复线程立刻开始恢复任务，它是 `engine_ownedSlotProfilesIMap` 的第一个访问者——map 正在加载中被访问，Hazelcast 抛 `RetryableHazelcastException`。

名字虽叫"可重试"，但 2.3.13 的 `restoreJobFromMasterActiveSwitch` **不重试**，直接当 init 失败处理：JobMaster 不创建、不入内存，该任务被静默丢弃。

### 3.2 为什么是 UNKNOWABLE

REST 查任务状态的路径：master 内存的 `runningJobMasterMap` → 没有则查 `finishedJobStateMap` → 两边都没有就返回 `UNKNOWABLE`。恢复失败后任务两边都不在，只剩 `runningJobInfo` 台账里一条没人管的记录。

### 3.3 为什么同伴任务没事

纯概率：两个任务先后恢复，轮到第二个时 map 已加载完。同一个 race，谁赶上加载窗口谁死。

### 3.4 配置层面为什么无解

- `LAZY`：有本文的加载竞争
- `EAGER`：master 启动抛 NPE、REST 起不来（见 mysql_cdc_to_clickhouse 最佳实践 1.5 节）

两个模式都有坑，只能靠第 5 节的工程手段兜底。

## 4. 处置 SOP

前提：任务是**干净中断**（master 重启前是 RUNNING），不是半取消的脏状态——脏状态（假 RUNNING、stop-job 杀不掉）走 [磁盘写满事故复盘](../incident_disk_full/doc.md) 第 4 节的清台账流程。

```bash
# 1. 确认无孤儿任务（见 2 的命令），有则等其消失或先处理

# 2. 直接 -r 重提交，无需重启集群、无需清台账
docker exec -it seatunnel-client /opt/seatunnel/bin/seatunnel.sh \
  --async -r <jobId> -c /opt/seatunnel/config/<原配置>.conf

# 3. 验证：从最新 checkpoint 续跑、状态回到 RUNNING
docker logs -f seatunnel_master 2>&1 | grep "<jobId>"   # 看 start with savePoint on checkPointId(N)
curl -s -u 'admin:***' http://localhost:8080/running-jobs | jq -r '.[] | "\(.jobId)  \(.jobStatus)"'
```

实测效果：从重启前 1 分钟的 checkpoint 续跑，几分钟追平，几乎零重放。

## 5. 预防

| 措施 | 做法 |
|---|---|
| 状态告警（最关键） | cron 每分钟查 `/running-jobs`：数量不符预期、或任何任务状态非 RUNNING（UNKNOWABLE/CANCELING 都算）→ 告警。把"几小时后发现数据停了"变成"几分钟内收到告警" |
| 重启后固定核对 | 任何原因重启 master 后，立刻核对 `/running-jobs`，缺哪个 `-r` 哪个 |
| master HA | 多起一个 `-r master` 节点（standby）。master 重启/挂掉时 standby 接管；standby 长期在线、map 早已加载完，不踩加载窗口。唯一从根上避开 race 的办法，代价是多一个容器 |
| 减少重启次数 | hazelcast 配置改动需重启生效，攒一批一起改 |

## 6. 一句话总结

master 重启 + LAZY 加载 = 恢复线程和 map 加载赛跑，输了的任务变 UNKNOWABLE 僵尸；处置就是 `-r` 重提交，根治靠 HA 和告警。
