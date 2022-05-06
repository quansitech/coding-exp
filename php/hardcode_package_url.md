## 指定composer包下载地址



在发布新版本的扩展包后，由于国内的镜像同步时间不确定，经常要等很久才能拉取到最新版本的代码。如果改用官方源，则下载速度会非常慢，导致部署新功能时出现超时的情况。



解决办法：利用国内github镜像（同步速度很快），指定composer安装特定版本的包使用该镜像地址作为下载源。



步骤：

1. 安装chrome插件，插件名：GitHub加速。建议使用edge。

2. 获取镜像地址，发布新版本后，可以在Tags页面找到该版本的zip下载地址，如果已经正确安装了github加速插件，在旁边还能看到"加速zip"的选项，该A标签对应的地址就github镜像地址了。

3. 设置composer.json文件
   
   ```php
   "repositories": [
           {
               "type": "package",
               "package": {
                   "name": "quansitech/qscmf-utils",
                   "version": "v1.5.2",
                   "dist": {
                       "type": "zip",
                       "url": "https://github.91chi.fun/https:/github.com/quansitech/qscmf-utils/archive/refs/tags/v1.5.2.zip"
                   },
                   "require": {
                       "php": ">=7.2.0",
                       "tiderjian/think-core": ">=8.0"
                   },
                   "type": "library",
                   "autoload": {
                       "psr-4": {
                           "Qscmf\\Utils\\": "src/"
                       }
                   }
               }
           }
       ]
   ```
   
   以qscmf-utils包为例，在composer.json文件添加repositories项，参考上面的代码。或者也可以去composer.lock将对应包的设置内容copy过来，删除多余的配置，保留上面参考代码的对应配置项即可。
   
   将version改成需要指定的版本号，dist的url改成步骤2获取到的igithub镜像地址。
   
   注意：如果新版本的require，autoload之类的配置有变化，也必须改成最新的，否则会出现无法加载获取安装冲突的问题。

4. 执行composer update完成新版本更新。


