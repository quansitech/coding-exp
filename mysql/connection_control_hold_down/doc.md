## connection_control插件导致的数据库挂起

### 问题描述

网站时不时发生访问超时，查看web服务器与数据库使用情况，资源使用正常，数据库通过本地可以root用户能正常登录，查询show process_list，也没发现慢查询，但会有大量的Waiting in connection_control plugin状态的连接。这种情况大概1个月发生一次左右。检查数据库general_log，会有大量的root@ip地址 on  using TCP/IP,却看不到任何的sql语句。

开始以为是服务器的配置问题，尝试了许多修改服务器配置的方案，问题依旧会出现。

最后看到my.cnf有一个设置，看起来跟"Waiting in connection_control plugin"状态提示有些关联。
```
plugin-load-add=connection_control.so
connection_control_failed_connections_threshold=5
connection_control_min_connection_delay=1800000
```

通过官网，查询该设置的用途，发现该插件是用来限制连接频率的，如果连接失败次数超过connection_control_failed_connections_threshold，会延迟connection_control_min_connection_delay毫秒后再尝试连接。

于是尝试在本地进行重现，故意设置错误的密码去进行数据库连接，发现超过5次后就出现访问挂起超时的情况了。由此判断就是这个原因导致的。

### 解决方案

1. 通过修改my.cnf，将插件注释掉，重启数据库，问题解决。
2. 通过修改my.cnf，将connection_control_failed_connections_threshold设置为0，重启数据库，问题解决。
3. 有等保要求的网站，创建一个新用户，该用户的命名不能容易被猜到，web应用通过该用户来访问，这样即使root用户因为网络脚本而触访问失败，触发连接延迟，也不会影响到网站的正常访问。