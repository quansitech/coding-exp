## mysql升级失败

报错如下

Can't create thread to handle bootstrap (errno: 1)

Data Dictionary initialization failed.

这是因为进行版本升级时需要调用系统函数，可能linux系统设置了禁止docker调用系统函数导致。需要在docker-compose加上禁用seccomp配置

```yaml

mysql-test-8.4:
      image: 
      container_name: mysql-test-8.4
      security_opt:
        - seccomp:unconfined

```

### GPT解释

`--security-opt seccomp=unconfined` 参数用于在 Docker 容器中禁用 Seccomp（安全计算模式），这是一个 Linux 内核特性，用于限制应用程序可以使用的系统调用。

具体作用包括以下几点：

1. **禁用系统调用限制**：
   默认情况下，Docker 使用一种安全配置文件（Seccomp profile）来限制容器内进程可以调用的系统函数，以减小容器内被攻陷后对宿主机的安全影响。使用 `--security-opt seccomp=unconfined` 参数禁用该功能，使容器没有 Seccomp 保护，也就是说，容器内的进程可以使用所有的系统调用。

2. **灵活性与兼容性**：
   有些应用程序需要使用特定的系统调用，如果这些调用在默认的 Seccomp 规则中被禁用了，应用程序可能无法正常运行。在这种情况下，禁用 Seccomp 可以提供更大的灵活性，使应用程序能够正常运行。

3. **安全性风险**：
   禁用 Seccomp 可能会增加安全风险，因为这会让容器的进程可以访问更多的系统调用，从而增加了攻击面。如果容器中运行的进程被攻陷，攻击者可以利用更多的系统调用尝试逃逸容器或进行其他恶意操作。

使用示例：

```sh
docker run --rm --security-opt seccomp=unconfined my-container-image
```

需要谨慎使用该参数，确保只有在确实需要的情况下才禁用 Seccomp，并且对运行的容器进行其他必要的安全保护措施。