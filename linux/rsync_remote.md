## rsync实现跨服务器文件同步



rsync是一个速度很快的文件同步工具，支持通过socket或者ssh进行跨服务器文件同步，结合cron可以很方便的实现定时备份文件



#### 使用ssh进行跨服务器文件同步

1. 安装sshpass ，便于rsync在脚本环境下接受ssh密码设置
   
   ```shell
   # centos 
   yum -y install sshpass
   ```

2. 安装rsync
   
   ```shell
   # centos
   yum -y install rsync
   ```

3. 安装cron
   
   ```shell
   # centos
   yum -y install cron
   ```

4. 设置cron定时任务
   
   ```shell
   PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
   
   * 4 * * * root sshpass -pSSH_PASSWORD rsync -av --delete SSH_ACCOUNT@IP_ADDRESS:/source/data_backup /target/data_backup
   ```

        脚本里的大写变量根据具体的值进行替换

        SSH_PASSWORD   linux账号密码

        SSH_ACCOUNT      linux账号名

        IP_ADDRESS           linux服务器IP地址










