## MySQL隐式类型转换

### 问题描述

举一个查询数据时可能会遇到的情景

数据表结构：

```sql
CREATE TABLE `test` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `name` varchar(45) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci DEFAULT NULL,
  `number` int DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_name` (`name`),
  KEY `idx_number` (`number`)
) ENGINE=InnoDB AUTO_INCREMENT=10 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
```

表初始数据：

```sql
INSERT INTO `test` VALUES 
(1,'12222222222222222222222221',12222221),
(2,'12222222222222222222222222',12222222),
(3,'12222222222222222222222223',12222223),
(4,'12222222222222222222222224',12222224),
(5,'name5',12222225),
(6,'name6',12222226),
(7,'name7',12222227),
(8,'name8',12222228),
(9,'name9',12222229);
```

![init_data](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_implicit_type_conversion/init_data.png)

执行查询sql

```sql
select * from test where id = '01aa';
```
**问题一：查询的结果数据不准**

![str_to_int](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_implicit_type_conversion/str_to_int.png)

执行查询sql

```sql
SELECT * FROM xh_test.test where name = 12222222222222222222222221;
desc SELECT * FROM xh_test.test where name = 12222222222222222222222221;
```
**问题二：不能利用索引 idx_name 且查询的结果数据不准**

![int_to_str](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_implicit_type_conversion/int_to_str.png)

![desc_sql](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_implicit_type_conversion/desc_sql.png)


### 什么是隐式转换

```blade
当操作符与不同类型的操作数一起使用时，会发生类型转换以使操作数兼容。

例如，操作数是字符串和数字时,MySQL会根据操作符类型，将字符串转换成数字或者将数字转换成字符串，再做操作符运算。
```

具体的隐式转换规则可参考[MySQL文档](https://dev.mysql.com/doc/refman/8.0/en/type-conversion.html)详细了解。

### 总结

- [产生隐式转换的类型主要有：字段类型不一致、in参数包含多个类型、字符集类型或校对规则不一致等；](https://mp.weixin.qq.com/s?__biz=MzI4NjExMDA4NQ==&mid=2648450774&idx=1&sn=efb63a4c5a0396872acb3892a9cd85d8&scene=21#wechat_redirect)
- 隐式类型转换有可能导致无法使用字段索引、查询结果不准确等问题；
- 避免产生隐式转换，如当两个操作数类型不一致时，可以使用类型转换函数cast、convert来明确的进行转换：
```sql
SELECT * FROM xh_test.test where name = cast(12222222222222222222222221 as char);
desc SELECT * FROM xh_test.test where name = cast(12222222222222222222222221 as char);
```

![type_convert](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_implicit_type_conversion/type_convert.png)

![desc_type_convert](https://github.com/xhiny/coding-exp/blob/main/mysql/mysql_implicit_type_conversion/desc_type_convert.png)
