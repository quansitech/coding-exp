## mysql update语句执行后仅在发生行数据更改时自动执行设定语句

### 问题描述
<br>
为了实现A表数据更改后，在B表添加一条数据的需求，我们会在A表创建update after触发器，该触发器定义往B表插入一条数据语句的方案。
<br>
<br>
以下例子数据表kb_book_data为A表，数据表kb_es_sync为B表。

[init_table.sql](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_exec_sql_on_update_after/init_table.sql)
<br>
<br>
A表、B表初始化情况：
<br>

![image-20210327160029377](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_exec_sql_on_update_after/init_info.png)  
<br>
A表执行update语句后，查看B表情况：
```sql
update kb_book_data set book_name=book_name;
select count(*) from kb_es_sync;
```

![image-20210327160338274](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_exec_sql_on_update_after/show_problem.png)  
<br>
实际使用发现，不管A表数据是否有变化，只要执行了update语句，B表就会插入一条记录，出现了B表的数据并不能准确表示A表发生数据变化的问题。
<br>
<br>
那么，如何实现update语句执行后仅在发生行数据更改时自动执行设定语句呢？  
<br>
### 方案分析
共列出了3种方案，最终选择第3种。 
1. 修改A表的update语句，添加过滤条件：修改列的最终值非该列的当前值，但是这样程序就会变得复杂。  

	修改update语句前：
  
    ```sql
    update kb_book_data set isbn=9787544809757 where id='000365f9-a2e3-b5ab-bc1e-3561e3ed52d9';
    select count(*) from kb_es_sync;
    ```
   
   ![image-20210327160948399](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_exec_sql_on_update_after/solution-1.png)

	修改update语句后：   
    ```sql
    update kb_book_data set isbn=9787544809757 where id='000365f9-a2e3-b5ab-bc1e-3561e3ed52d9' and isbn!=9787544809757; 
    select count(*) from kb_es_sync; 
    ```
   
   ![image-20210327161105793](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_exec_sql_on_update_after/solution-1-2.png) 
   <br>
2. update after触发器添加语句执行条件：判断只要该行任何列的值从当前值改变成另外的值，则执行语句。  但是这个方法可行性也比较低，原因如下： 
   + 数据表列变化时需要同步维护update after触发器； 
   + 数据表列数较多情况下，判断条件较长。 
     <br>
3. 利用Mysql [TIMESTAMP 和 DATETIME 列可以自动初始化和更新到当前的日期和时间](https://dev.mysql.com/doc/refman/8.0/en/timestamp-initialization.html) 功能。只有该行任何其它列的值从当前值改变成另外的值，自动更新的列才会自动更新到当前的时间戳。 
我们可以在A表添加该列，update after触发器判断该列的值，有变化则执行语句。 
   <br>
### 解决方案
+ A表添加自动初始化和自动更新列update_date； 

  ```sql
  ALTER TABLE `kb_book_data` ADD `update_date` TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '禁止手动修改' AFTER `create_date`;
  ```
+ 修改update after触发器，添加判断条件：只有update_date列的值从当前值改变成另外的值，则执行定义语句；

  ```sql
  DROP TRIGGER IF EXISTS `tri_book_data_update_after`;
  DELIMITER $$
  CREATE TRIGGER `tri_book_data_update_after` AFTER UPDATE ON `kb_book_data` 
  FOR EACH ROW 
  BEGIN 
    if old.update_date != new.update_date then 
        insert into kb_es_sync(`data_type`, `op`, `data_key`) values('book_data', 'update', new.id); 
    end if; 
  END
  $$
  DELIMITER ;
  ```
+ 程序禁止修改update_date的值。  


通过以上步骤的修改后的结果：  

```sql
select count(*) from kb_es_sync;
update kb_book_data set book_name=book_name;
select count(*) from kb_es_sync;
```

![image-20210327162057541](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_exec_sql_on_update_after/normal.png)  