## 使用certbot申请、续期泛域名SSL证书

```blade
使用certbot申请泛域名SSL证书，需要使用dns-01的域验证方式。
certbot暂无支持国内DNS服务商插件，此方案是使用manual模式指定动态修改DNS记录脚本完成SSL证书的申请、续期功能。

以域名为*.t4tstudio.com，DNS服务供应方为阿里云，使用php运行修改DNS记录脚本为例。

只申请泛域名*.t4tstudio.com的话，主域名t4tstudio.com会失效，所以申请时两个域名需要加上。
```


### 环境准备


- 根据服务器环境安装[certbot工具](https://certbot.eff.org/)

- 安装[修改DNS记录脚本](https://github.com/ywdblog/certbot-letencrypt-wildcardcertificates-alydns-au)

  - 下载

    ```bash
    git clone https://github.com/ywdblog/certbot-letencrypt-wildcardcertificates-alydns-au
    cd certbot-letencrypt-wildcardcertificates-alydns-au
    chmod 0777 au.sh
    ```

    若使用git安装失败，可以使用其它的方式将此工具安装到服务器，例如下载压缩包然后上传到服务器后解压

  - 检查domain.ini文件是否存在根域名，没有则追加

  - [获取阿里云操作API的AccessKey ID和AccessKey Secret](https://help.aliyun.com/knowledge_detail/38738.html)，编辑au.sh，修改ALY_KEY 和 ALY_TOKEN

  

### 申请证书

- 申请证书

  - **建议先使用 --dry-run测试**

    - ```bash
      certbot-auto certonly -d t4tstudio.com -d *.t4tstudio.com --dry-run --manual  --manual-public-ip-logging-ok --preferred-challenges dns --manual-auth-hook "修改DNS记录脚本的目录/au.sh php aly add" --manual-cleanup-hook "修改DNS记录脚本的目录/au.sh php aly clean" 
      ```

  - 运行命令

    - ```bash
      certbot-auto certonly -d t4tstudio.com -d *.t4tstudio.com --manual  --manual-public-ip-logging-ok --preferred-challenges dns --manual-auth-hook "修改DNS记录脚本的目录/au.sh php aly add" --manual-cleanup-hook "修改DNS记录脚本的目录/au.sh php aly clean" 
      ```

- 续期证书

  - **建议先使用 --dry-run测试**

    - ```bash
      certbot-auto renew --cert-name t4tstudio.com --dry-run --manual --manual-public-ip-logging-ok  --preferred-challenges dns  --manual-auth-hook "修改DNS记录脚本的目录/au.sh php aly add" --manual-cleanup-hook "修改DNS记录脚本的目录/au.sh php aly clean"
      ```

  - 运行命令

    - ```bash
      certbot-auto renew --cert-name t4tstudio.com --manual --manual-public-ip-logging-ok  --preferred-challenges dns  --manual-auth-hook "修改DNS记录脚本的目录/au.sh php aly add" --manual-cleanup-hook "修改DNS记录脚本的目录/au.sh php aly clean" 
      ```

  - 若使用nginx服务器，可以使用 --deploy-hook  "重启nginx服务器命令"

    - ```bash
      certbot-auto renew --cert-name t4tstudio.com --manual --manual-public-ip-logging-ok  --preferred-challenges dns  --manual-auth-hook "修改DNS记录脚本的目录/au.sh php aly add" --manual-cleanup-hook "修改DNS记录脚本的目录/au.sh php aly clean"  --deploy-hook "重启nginx服务器命令"
      ```
  
