## mysql8.0 使用not exists 与 left join 查询数据不全



### 问题描述

```sql
SELECT
    d.id,
    d.stock_status
FROM
    book d
WHERE
    stock_status = 0 AND NOT EXISTS(
    SELECT
        book.book_data_id
    FROM
        service_book book
    left JOIN service_batch b ON
        book.batch_id = b.id
    WHERE
        ( re_audit_reason_id > 0 OR re_audit_reason != '' OR b.status = 0
        ) AND book.book_data_id = d.id
)
```

![image-20210218192254202](https://github.com/quansitech/coding-exp/blob/main/mysql/mysql_8_not_exists_issue/image-1.png)



执行上面的sql时，在mysql8版本，只能查询出10条数据。但实际符合条件的数据有61条，而且在sql条件中加上具体的id值时能查询这10条外的数据

```sql
SELECT
    d.id,
    d.stock_status
FROM
    book d
WHERE
    stock_status = 0 AND NOT EXISTS(
    SELECT
        book.book_data_id
    FROM
        service_book book
    left JOIN service_batch b ON
        book.batch_id = b.id
    WHERE
        ( re_audit_reason_id > 0 OR re_audit_reason != '' OR b.status = 0
        ) AND book.book_data_id = d.id
) and d.id='445e77c0-0257-1d82-cfed-5cea8e07fcb5'  //该id是符合条件的61条中的其中一条的id
```

![image-20210218192534760](https://github.com/quansitech/coding-exp/blob/main/mysql/mysql_8_not_exists_issue/image-2.png)

情况看起来非常诡异，居然有51条数据处于幽灵状态，看不到，却能指定的查询出来。

[demo.sql](https://github.com/quansitech/coding-exp/blob/main/mysql/mysql_8_not_exists_issue/demo.sql)



### 尝试分析

sql语句并没有使用mysql特有的语法和特性，都是sql标准语法。表现出的结果并不符合预期，初步判断是mysql8的bug。为了确定这个猜想，换成mysql5.7测试，结果能正常查询到61条数据。

尝试改动sql，看能否运作正常。

+ 将left join 改成inner join，sql运作正常。
+ 将 b.status = 0删除，sql运作正常。
+ 将 re_audit_reason_id > 0 和 re_audit_reason != '' 任意一条删除，sql运作不正常。
+ 将 re_audit_reason_id > 0 和 re_audit_reason != '' 同时删除，sql运作正常。

尝试改动数据量，看能否运作正常。

+ 删除service_batch id=16的批次，同时删除service_book batch_id=16的数据，再用上面的查询，sql运作正常。
+ 删除service_batch id=16，14的批次，同时删除service_book batch_id=16，14的数据，再用上面的查询，sql运作正常。



### 结论

这是mysql8.0版本的bug，而且有一定的隐秘性。

推测出现的条件，在not exists里面使用left join查询，并且使用了较为复杂的or条件组合，而且not exists里面的查询表数据量达到75条（该数字只在本测试数据下有效，不确定更数据表更复杂或者简单的场景下是否依然有效）以上则会出现该灵异场景。

因此，在mysql修复该bug之前，还是要尽量避免在not exists 中 联合 left join使用，而且应该也不存在非要联合not exists 与 left join使用的场景。not exists很多时候可以使用not in 和 left join来代替。

