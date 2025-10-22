## MySQL主从复制经验总结

### 主从复制设置

主从库的my.cnf设置如下

主库
```shell
log_bin=mysql-bin  # 开启bin-log
server_id=1   # 主从库id必须唯一
```

从库
```shell
log_bin=mysql-bin  # 开启bin-log
server_id=2   # 主从库id必须唯一
relay_log=/var/lib/mysql/mysql-relay-bin  # relay_log存放路径
log_bin_trust_function_creators=1  # 如果主库有自定义function，需要开启从库执行时才不会出错

replicate_do_db=db1,db2,db3 # 该项用于设置需要复制的指定数据库，如果不设置，则是整个库复制
```

在主库创建复制的专属用户
```sql
CREATE USER 'repl'@'从库IP地址' IDENTIFIED BY 'password';
```

授权复制权限
```sql
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'从库IP地址';
```

刷新权限
```sql
FLUSH PRIVILEGES;
```

准备开始将现有数据通过mysqldump的方式导入从库数据库，为了避免在备份时继续产生数据，可以先锁定主库
```sql
FLUSH TABLES WITH READ LOCK;
```

记录当前主库的偏移量
```sql
SHOW MASTER STATUS; //8.0版本

SHOW BINARY LOG STATUS; //8.4版本

//记录 File 和 Position字段的值，表示当前bin-log的位置，从库需要从这个位置读取数据复制
```

备份数据库，可以选择备份全部数据库。如果只需要复制单个数据库，则备份需要复制的数据库即可
```sql
//全量备份整个数据库
mysqldump --all-databases --routines -u root -proot > backup.sql

//备份单个数据库 (-R 包括备份存储过程和函数)
mysqldump –u root –p -R test_db > test_db.sql  
```

备份结束后，解锁
```sql
UNLOCK TABLES;
```


从库导入刚才dump出来的主库备份
```sql
mysql –u root –p

//整库备份执行
source /绝对路径/backup.sql

//单库备份执行
create database test_db;
use test_db;
source /绝对路径/test_db.sql;
```

从库设置主库的同步配置
```sql
#8.0版本
stop slave #先停止从库复制

CHANGE MASTER TO
MASTER_HOST='主库ip',
MASTER_PORT=3306,
MASTER_USER='repl',
MASTER_PASSWORD='password',
MASTER_LOG_FILE='mysql-bin.000016', #上面步骤记录的主库bin-log文件
MASTER_LOG_POS=537; #上面步骤记录的主库bin-log文件位置

# 8.4版本
stop replica;

CHANGE REPLICATION SOURCE TO
SOURCE_HOST='master_ip_address',
SOURCE_USER='replica_user',
SOURCE_PASSWORD='password',
SOURCE_LOG_FILE='mysql-bin.000001', -- 这里替换为第3步记录的值
SOURCE_LOG_POS=1234; -- 这里替换为第3步记录的值

-- 如果主库要求链接必须采用ssl方式，则需要配置一下参数（等保3要求必须ssl）
CHANGE REPLICATION SOURCE TO
SOURCE_SSL=1,SOURCE_SSL_CA='ca.pem', --从主库复制ca.pem到从库
SOURCE_SSL_CAPATH='/var/lib/mysql/'
```

开启从库同步
```sql
start slave; //8.0

start replica; //8.4
```


查看同步情况
```sql
show slave status\G; //8.0

SHOW REPLICA STATUS\G //8.4

# 其中Slave_IO_Runing 和 Slave_SQL_Runing 都为Yes，表示同步进行中
```

这样部署即完成，如果从库仅作为查询用途，可以在my.cnf设置上read_only=1

### 同步出错处理

通过show slave status可以查看到出错提示，其中 Last_Error字段会提示在performance_schema.replication_applier_status_by_worker表可以查看到具体报错原因，报错原因可以找到错误原因即执行出错的bin-log位置。

如果是主键冲突之类的，可能是从库不稳定，执行了两遍bin-log导致的。所以只需要通过查看从库最后一个binlog(binlog的查看可以看[使用binlog恢复数据](https://github.com/quansitech/coding-exp/blob/main/mysql/binlog_recover/binlog_recover.md))，看最后执行到什么位置，再去主库，找到对应位置的position和bin-log文件，将从库的同步位置改成该位置即可。

改同步配置的时候需要先stop slave, 同时 reset slave， 再通过change master to来修改才会成功，否则会提示有错误信息，无法执行修改。
