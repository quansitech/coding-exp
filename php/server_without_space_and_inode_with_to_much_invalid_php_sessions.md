### 已过期session文件堆积至服务器容量和inode满
<br>

#### Linux分区容量满
<br>
线上一个项目前台能正常访问，但是后台登录后会跳转至登录页面而无法登录。  
登上服务器查看项目log文件没异常，倒是使用tab时，服务器出现空间不足的提示：

```bash
No space left on device
```

使用df -h命令查看，原来分区容量满了。  
删除了一些临时文件后，项目后台可以登录了。  
过了一段时间该项目问题又出现了。  
<br>
#### 硬盘空间未满仍提示空间不足
<br>
登录服务器查看系统分区容量，不至于不够空间，但还是有空间不足的提示。  

那就清空了一些占用比较大的log。  
推荐使用>指令覆盖文件原内容来清空文件。  

```bash
cat /dev/null > filename
```

*不建议直接使用rm命令清空大文件*

```bash
rm file && touch file
```

通过rm删除文件，将从文件系统的目录结构上解除链接。

如果有其他进程正使用此文件，进程仍可读取文件，磁盘空间也会被占用。

所以文件空间可能不会马上被释放，需要找到所有使用此文件的进程并结束它们，空间才会被释放。   
<br>
<br>
释放了约4G硬盘容量，并没有解决问题，而且重启lnmp服务失败。  
<br>
#### Linux inode容量满
<br>
[由于每个文件都必须有一个inode，因此有可能发生inode已经用光，但是硬盘还未存满的情况。这时，就无法在硬盘上创建新文件。](https://www.ruanyifeng.com/blog/2011/12/inode.html)  

使用df -i命令发现根目录的inode满了，所以Linux不能创建临时文件，也解释了为什么释放了硬盘空间仍然报空间不足的问题。  
<br>
#### 查找占用文件夹
<br>
[Linux实例磁盘空间满和inode满的问题排查方法](https://help.aliyun.com/document_detail/42531.html)  

分析根目录下的每个二级目录文件数，逐级找出占用最大的目录。  

```bash
for i in /*; do echo $i; find $i | wc -l; done
```
<br> 

#### PHP sessions过期文件没有自动清理

<br> 
最后发现是/var/php/sessions目录。  
这是存放php的session文件，里面有两百多万个文件，也就是占用了两百多万个inode。  

正常会通过启动gc进程来自动清理过期的session，那为什么没有清理呢？  
php.ini与session生命周期有关部分配置

```bash
;session.save_path
# 设置保存的session文件路径，默认是/tmp。

session.gc_maxlifetime = 1440
# 设置session存活时间，默认值 单位为秒

session.gc_probability = 1
session.gc_divisor = 1000

# 以上两个配置值决定了gc触发的概率，默认为1/1000。
# 每1000次请求会启动一次gc回收session，过期的session文件会被系统当做垃圾来处理。
```

通过查看php.ini配置，发现与session生命周期有关的配置被修改了   

```bash
session.save_path=/var/php/sessions/
# 设置保存的session文件路径。

session.gc_probability = 0
# 此值为0，所以不会触发gc回收，也就无法自动清除过期的session文件
```

将session.gc_probability改为1后，/var/php/sessions/最后变回了两百多个文件。  
<br>
至此项目终于可以正常访问了。  
当过期session文件无法自动清理，堆积至服务器分区容量满或者inode满。  
服务器无法创建新的文件，所以无法生成新的session信息，也就无法登录项目后台。
