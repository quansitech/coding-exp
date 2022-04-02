## 离线安装软件包



### centos

1. 查看linux的发行版本
   
   ```shell
   cat /etc/redhat-release 
   ```

2. 根据发行版本，在hub.docker.com上找到对应的镜像，在本地用docker部署

3. 下载需要的离线包
   
   ```shell
   yum -y install xxxx --downloadonly --downloaddir=.
   ```

4. 将下载好的离线包拷贝至目标服务器，安装
   
   ```shell
   rpm -Uvh --force --nodeps *.rpm
   ```




