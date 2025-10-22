# centos实现双因子登录(密码+google验证码)

## 前言

服务器双因子登录是等保三最基本的要求，双因子有多种方式，密码+证书，密码+手机短信码，密码+google验证码。而密码+证书是最

简单的设置方式，但有些尝试是没法使用的，如堡垒机。而密码+google验证码则可以解决堡垒机的双因子登录问题。

## 安装google authenticator模块

首先，需要确保系统时钟准确, 因为google authenticator是基于时间序列和key的校验算法，保证服务器与验证码生成器的时间一致

至关重要。而时间同步问题可以使用chronyc或者ntpq来实现。

```shell
# ntpd服务安装
yum install ntp -y

# 启动并设置开机自启
systemctl start ntpd
systemctl enable ntpd

# 使用 `ntpq` 命令来查看同步状态。
ntpq -p
```

下面开始安装google authenticator

```shell
yum install epel-release -y

yum install google-authenticator -y
```

安装完成后生成google-authenticator密钥

```shell
google-authenticator

# 基于时间序列创建token，选择完该选项后会出现一个二维码以及相关的配置信息，可以先完成手机app的安装
Do you want authentication tokens to be time-based (y/n) y


Do you want me to update your "/root/.google_authenticator" file? (y/n) y

# 禁止重复使用认证令牌，提升安全性
Do you want to disallow multiple uses of the same authentication
token? This restricts you to one login about every 30s, but it increases
your chances to notice or even prevent man-in-the-middle attacks (y/n) y


# 时间同步不佳的服务器可以选择y，允许4分钟内的时间偏差，否则选择n，提高安全性
By default, a new token is generated every 30 seconds by the mobile app.
In order to compensate for possible time-skew between the client and the server,
we allow an extra token before and after the current time. This allows for a
time skew of up to 30 seconds between authentication server and client. If you
experience problems with poor time synchronization, you can increase the window
from its default size of 3 permitted codes (one previous code, the current
code, the next code) to 17 permitted codes (the 8 previous codes, the current
code, and the 8 next codes). This will permit for a time skew of up to 4 minutes
between client and server.
Do you want to do so? (y/n)

# 防止暴力破解，启用登录频率限制
If the computer that you are logging into isn't hardened against brute-force
login attempts, you can enable rate-limiting for the authentication module.
By default, this limits attackers to no more than 3 login attempts every 30s.
Do you want to enable rate-limiting? (y/n) y
```

## 配置SSH服务与PAM

1. 配置SSH服务

   编辑SSH服务的配置文件：

    ```bash
    sudo vi /etc/ssh/sshd_config
    ```
   确保以下参数设置为 yes:


    ```text
    ChallengeResponseAuthentication yes
    UsePAM yes
    ```
    关闭密码登录功能，采用keyboard-interactive的方式验证，通过pam.d配置密码+验证码的登录步骤

    ```text
    PasswordAuthentication no
    ```
    注释掉与AuthenticationMethods有关的设置

2. 配置PAM模块

    编辑PAM的SSH配置文件：

    ```bash
    sudo vi /etc/pam.d/sshd
    ```
    在文件内部添加以下一行, 需要注意顺序，要加到密码验证后，表示先进行密码验证，第二步才进行验证码

    ```text
    auth       substack     password-auth
    # nullok表示没有配置google验证码的账号不启用该验证
    auth       required     pam_google_authenticator.so nullok  
    ```

3. 重启SSH服务

    让所有配置生效：

    ```bash
    sudo systemctl restart sshd
    ```
    ⚠️ 重要提醒：在重启sshd服务之前，请确保你已在当前服务器连接中成功测试了双因子认证流程，或者另外开启一个终端会话保持登录状态。否则一旦配置有误，你可能被直接锁在服务器外面。


## 安装与配置手机APP

1. 安装微软Authenticator APP
  
    通过安装应用市场，搜索 Authenticator，注意是微软发布的

2. 绑定账号

    点击"+"图标，选择其他账号，通过扫描二维码或者添加密钥的方式来创建账号