## 用binlog恢复数据

原则：不支持线上直接恢复，风险极大。通常做法是在本地恢复出数据，在确认没有问题后再进行全量或者局部恢复数据至线上环境

#### 用binlog快速恢复至某个时间节点的数据

+ 先将binlog文件下载至本地，然后通过binlog解释出可阅读的日志文件，分析出事故发生前的时间点
  
  ```shell
  //用mysql镜像，在shell命令行执行
  
  mysqlbinlog --base64-output=decode-rows -v --database wd binlog.000002 > wd_05.sql
  ```

+ --base64-output=decode-rows 将binlog里的base64编码的记录进行解码，必须解码，否则无法分析
  
  --v 详细模式，开启后才能看到sql语句的注释，同样必须开启，否则看不到执行了什么
  
  --database 该参数后面跟具体要输出的数据库内容
  
  binlog.000002 是文件路径，这里是相对路径。
  
  `> wd_05.sql` 将内容输出到该文件。

+ 分析输出的sql文件
  
  ![https://github.com/quansitech/coding-exp/blob/main/mysql/binlog_recover/image1.png](https://github.com/quansitech/coding-exp/blob/main/mysql/binlog_recover/image1.png)
  
  假设B的位置是事故sql，那我们就可以选择执行完A后的时间作为恢复时间点：2022-05-05 09:47:48 

+ 执行恢复命令
  
  ```shell
  mysqlbinlog --stop-datetime '2022-05-05 10:00:00' --database wd binlog.000002 | mysql -u root -p
  ```
  
  恢复命令跟上面的分析命令有点不一样，这里做些解释
  
  首先 | 后面跟mysql -u root -p 命令，是指将mysqlbinlog输出的数据流导向mysql，这样写意思就是让mysql恢复binlog导入的数据
  
  --stop-datetime 获取该时间点前的binlog数据，可以搭配--start-datetime来用

       
