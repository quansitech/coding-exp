## MySQL从库部分同步但没有写入binlog导致出错

### 问题描述

mysql主从库正常运行，有一次项目迭代上线，执行了比较多的数据迁移，后面发现从库同步报错。 

从库出现了部分同步但没有写入 binlog 的情况。 

具体表现为在从库可以找到一部分迭代后更新的数据，但是从库的 binlog 还是在迭代前。

所以每次重启从库的同步功能，都会从迭代前的 POS 开始执行，这样会导致数据主键/字段重复等冲突。


### 解决方案

#### 修复同步出错

- 根据不同的原因调整从库同步设置，自动修复
    - 查看当前同步状态
      ```bash  
      SHOW SLAVE STATUS\G;
      ``` 
    - 查找出错具体原因
      ```bash
      select * from performance_schema.replication_applier_status_by_worker;
      ``` 
        - 设置 slave_skip_errors 
          ```text
          跳过常见错误，需要重启 mysql 服务
          根据 Last_Errno 判断此错误是否为常见的错误，如 主键冲突、数据表重复创建、字段存在冲突等
          ```
          ```bash
          # 修改my.cnf
          slave_skip_errors=1050,1060
          ```
          
        - 设置 sql_slave_skip_counter 跳过 N 个 event
          ```text
          跳过当前时间来自于主库的之后N个事件
          常处理偶尔出现的错误，或者没有具体的错误号，如 存储过程已存在
          如果跳过的 event 在事务组内，则会跳过整个事务。
          ```
          ```bash
          stop slave;
          set global sql_slave_skip_counter = 1;
          start slave;
          ```
          
        - 修改从库同步模式为 IDEMPOTENT （幂等模式）
          ```text
          设置成IDEMPOTENT模式可以让从库避免1032（从库上不存在的键）和1062（重复键，需要存在主键或则唯一键）的错误。
          该模式只有在ROW EVENT的binlog模式下生效
          此参数可以动态修改，若修改 my.cnf 需要重启 mysql 服务
          ```
          ```bash
          # 动态修改
          stop slave;
          set global slave_exec_mode = 1;
          start slave;
          ```
          
          ```bash
          # 修改my.cnf
          slave_exec_mode=IDEMPOTENT
          ```
        
        [以上配置说明参考文章](https://www.cnblogs.com/zhoujinyi/p/8035413.html)

- 找到同步的 binlog 和 POS 点，修改设置主库的同步配置
  ```tetx
  这个方案会导致从库缺失了 binlog；
  数据量较大时，查找主库的 POS 会耗费很多时间
  ```
    - 查看当前同步状态
      ```bash  
      SHOW SLAVE STATUS\G;
      ``` 
    - 查找出错具体原因并定位主库 binlog 与 POS 位置
      ```bash
      select * from performance_schema.replication_applier_status_by_worker;
      ```
    - 设置主库同步配置
      ```bash
      stop slave;
      reset slave;
        
      CHANGE MASTER TO
      MASTER_HOST='主库ip',
      MASTER_PORT=3306,
      MASTER_USER='repl',
      MASTER_PASSWORD='password',
      MASTER_LOG_FILE='mysql-bin.000016', #上面步骤记录的主库 binlog 文件
      MASTER_LOG_POS=537; #上面步骤记录的主库 binlog 文件位置
      
      start slave;
      ```        

- 从库重做一遍
  ```tetx
  数据量较大时，这个方案恢复时间比较慢
  ```

#### 验证主从数据一致性
通过以上修复查看当前同步状态正常后，使用 [pt-table-checksum](https://github.com/quansitech/coding-exp/blob/main/mysql/mysql_master_slave_replication/pt_table_checksum_intro.md) 查看是否有差异