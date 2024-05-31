## docker-compose 模块化

```text
随着项目的增多，docker-compose.yml 文件配置的服务也越来越多，
这时可以考虑将 docker-compose.yml 文件拆分成多个文件，方便定位修改。
以下介绍通过拆分文件实现 docker-compose 模块化。
```

##### 文件夹结构
```text
.
├── docker-compose.sh
├── docker-compose.yml
├── .env
├── yml
│   ├── common
│   │   ├── db.yml
│   │   ├── redis.yml
│   │   └── nginx.yml
│   ├── project
│   │   ├── project_1.yml
│   │   ├── project_2.yml
│   │   └── project_3.yml
```

##### docker-compose.yml
```text
通用配置、基础服务存放位置
```

```yaml
version: '3.8'

networks:
  backend:
    driver: bridge

services:
  redis:
    image: redis:latest 
```

##### 基础服务配置 (yml/common 目录)
```text
当一个同类基础服务有多版本时，可以考虑从 docker-compose.yml 中拆分出来使用新文件存放
```

```yaml
# 例如要管理多个 mysql 版本的服务
# db.yaml

version: '3.8'

services:
  db5.7:
    image: mysql:5.7
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - db_data5.6:/var/lib/mysql
    networks:
    - backend
       
      
  db8.0:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - backend     
  db8.4:
    image: mysql:8.4
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - db_data8.4:/var/lib/mysql
    networks:
      - backend

volumes:
  db_data:
    driver: local
  db_data5.7:
    driver: local
  db_data8.4:
    driver: local
```

##### 项目服务配置 (yml/project 目录)
```text
存放与项目有关的非基础服务
```

```yaml
# project_1.yaml
version: '3.8'

services:
  worker:
    build: ./worker
    ports:
      - "8080:80"
    depends_on:
      - mysql5.7
      - nginx
```

##### 用法
```text
docker-compose 可以使用多个文件组合配置执行，但是需要写出每一个文件路径。
拆分之后文件会变多而且有新项目时还会添加新文件，为了方便执行，添加了 docker-compose.sh 脚本。
脚本主要赋值 COMPOSE_FILE 环境变量，自动读取 yml/common 和 yml/project 目录下的所有 yml 配置文件并组合成所有的服务。
```

+ 用法
  ```shell
  # 改前
  docker-compose up -d nginx
  
  # 改后
  ./docker-compose.sh up -d nginx
  ```

+ docker-compose.sh
  ```bash
    #!/bin/bash

    # 查找所有符合条件的文件，并用冒号分隔
    compose_files=$(find yml/common/  yml/project/ -name '*.yml' | tr '\n' ':')
    
    # 移除最后一个冒号
    compose_files=docker-compose.yml:${compose_files%:}
    # 设置 COMPOSE_FILE 环境变量
    export COMPOSE_FILE=$compose_files
    
    # 执行 docker-compose 命令
    docker-compose "$@"
  ```
  