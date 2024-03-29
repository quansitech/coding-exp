## 数据一致性验证工具：pt-table-checksum的使用

### 介绍

[pt-table-checksum](https://docs.percona.com/percona-toolkit/pt-table-checksum.html)是Percona Toolkit工具集中的一个强大工具，用于验证数据库中的数据是否一致。

它通过比较主库和从库的数据，检测出不一致的数据行。

### 安装

+ 使用Docker，运行 percona-toolkit 服务：
   ```bash   
   docker run -it perconalab/percona-toolkit
   ```

### 需要注意的事项

- 在使用pt-table-checksum之前，确保数据库的复制已经正常运行；
- 主库的binlog_format非statement模式时，执行的用户要拥有修改的权限；
- 主从库的binlog模式应该一致，当从库的binlog_format非statement模式时，需要参数 --no-check-binlog-format 忽略此验证；
- 数据校验可能会对数据库性能产生一定的影响，请在合适的时间段进行校验；
- 校验结果只能看出哪些表出现不一致性，并无法得出具体出现多少行数据不一致，哪些数据行不一致等；
- 需要验证的表要有主键索引或唯一键索引。

### 使用

+ 主库创建新用户，拥有所有权限

  ```bash
  CREATE USER 'pt'@"%" IDENTIFIED BY "pt";
  
  GRANT ALL ON *.* TO 'pt'@"%" WITH GRANT OPTION;
  
  FLUSH PRIVILEGES;
  ```
  ```text
  该工具需要在主库的binlog_format为statement模式下执行。
  当主库为非此模式，会尝试修改当前会话级的binlog_format，故执行的用户要拥有修改的权限。
  ```

+ 执行数据校验命令
  ```bash
  pt-table-checksum --no-check-binlog-format --host=host --port=port --user=pt --ask-pass 

  # 缩写，与以上命令效果一致
  pt-table-checksum --no-check-binlog-format -hhost -Pport -upt --ask-pass 
  
  # 连接主库使用DSN写法，与以上命令效果一致
  pt-table-checksum --no-check-binlog-format h=host,P=port,u=pt --ask-pass 
  ```
  ```text
  这将在主库中创建一个用于存储校验信息的表 percona.checksums ，并开始进行数据校验，
  校验结果将直接打印在终端上，你可以看到每个表的校验状态。
  ```

+ 常用参数说明
  
  | 名称（，缩写）                  | 类型     | 是否必填 | 备注                                |
  |--------|------|-----------------------------------| ---- |
  | --no-check-binlog-format | bool   | 否    | 当从库的 binlog_format 非 statement 模式时，必填 |
  | --host,-h                  | string | 是    | 主库host                            |
  | --port,-P                   | string | 是    | 主库port                            |
  | --user,-u                   | string | 是    | 主库用户                              |
  | --password,-p               | string | 否    | 主库密码，无 --ask-pass 时必填                              |
  | --ask-pass               | bool   | 否    | 连接主库提示密码                          |
  | --databases               | string   | 否    | 指定只需要校验的数据库，如有多个则用','(逗号)隔开。                          |
  | --ignore-databases       | string   | 否    | 指定需要忽略校验的数据库，如有多个则用','(逗号)隔开                          |
  | --ignore-databases-regex | string   | 否    | 指定采用正则表达式匹配忽略校验的数据库                          |
  | --explain                | string   | 否    | 显示校验查询语句，但不执行真正的校验操作                          |

+ 结果说明
  ```shell
                TS ERRORS  DIFFS  ROWS  DIFF_ROWS CHUNKS SKIPPED    TIME TABLE
  10-20T08:36:50      0      0   200      0       1       0   0.005 db1.tbl1
  10-20T08:36:50      0      1   603      3       7       0   0.035 db1.tbl2
  10-20T08:36:50      0      0    16      0       1       0   0.003 db2.tbl3
  10-20T08:36:50      0      0   600      0       6       0   0.024 db2.tbl4
  ```
  ```text
  以上结果说明 db1.tbl2 的分块（CHUNKS） 7 的主从库总数与内容数据不一致。
  ```  
  
  | 名称         | 说明                                                                                         |
  |--------------------------------------------------------------------------------------------| ---- |
  | TS        | 校验完成的时间戳(没有年份显示)；                                                                          |
  | ERRORS    | 校验报错的数量                                                                                    |
  | DIFFS     | 0表示主从库一致，1表示不一致。如果指定--no-replicate-check，则该值总是为0，如果指定--replicate-check-only，则只有校验结果不同的表会显示 |
  | ROWS      | 选择表校验的行数                                                                                   |
  | DIFF_ROWS | 每个区块的最大差异数。如果一个区块有 2 个不同的行，另一个区块有 3 个不同的行，则此值将为 3。                                         |
  | CHUNKS    | 表被分成的chunk数                                                                                |
  | SKIPPED   | 跳过的chunk数                                                                                  |
  | TIME      | 校验执行消耗时间(单位：秒)                                                                             |
  | TABLE     | 校验的表名                                                                                      |

  ```text
  SKIPPED 跳过的原因有：
  
  MySQL not using the --chunk-index
  MySQL not using the full chunk index (--[no]check-plan)
  Chunk size is greater than --chunk-size * --chunk-size-limit
  Lock wait timeout exceeded (--retries)
  Checksum query killed (--retries)
  ```

  **查看数据表percona.checksums**
  ```bash
  SELECT * FROM percona.checksums WHERE tbl ='tbl2';
  
  +------+---------+-------+------------+-------------+----------------+----------------+----------+----------+------------+------------+---------------------+
  | db   | tbl     | chunk | chunk_time | chunk_index | lower_boundary | upper_boundary | this_crc | this_cnt | master_crc | master_cnt | ts                  |
  +------+---------+-------+------------+-------------+----------------+----------------+----------+----------+------------+------------+---------------------+
  | db1 | tbl2 |     1 |   0.007131 | NULL        | NULL           | NULL           | d69f6249 |        4 | 8362121b   |          3 | 2023-10-20 10:23:37 |
  +------+---------+-------+------------+-------------+----------------+----------------+----------+----------+------------+------------+---------------------+
  1 row in set (0.00 sec)  
  ```
  ```text
  以上查询结果说明 db1.tbl2 的分块（chunk） 1 的主从库数据不一致。
  该分块在主库的行数（master_cnt）为 3 ，在从库的行数（this_cnt）为4；
  该分块在主库的校验值（master_crc）为 8362121b ，在从库的校验值（this_crc）为 d69f6249 。
  ```

+ 参考文档
  [Percona-Toolkit 之 pt-table-checksum 总结](https://www.cnblogs.com/dbabd/p/10653408.html)
  

  






