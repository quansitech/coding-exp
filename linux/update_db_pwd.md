## 批量更新项目的数据库密码


#### 添加脚本

```shell
#!/bin/bash

ROOT_DIR=${1:-root_dir}
OLD_PWD=${2:-old_pwd}
NEW_PWD=${3:-new_pwd}
DB_HOST=${4:-db_host}


# 查找所有包含 .env 的文件
#env_files=$(find "$ROOT_DIR" -type f -name '.env')
env_files=$(grep -rl "^DB_HOST=$DB_HOST$" "$ROOT_DIR" --include=".env")

#echo "$ROOT_DIR"
#echo "旧值为: $OLD_PWD"
#echo "新值为: $NEW_PWD"

# 循环处理每个找到的文件
for file in $env_files; do
    # 检查文件中是否存在 DB_HOST=DB_HOST
    #if grep -q "^DB_HOST=$DB_HOST$" "$file" && grep -q "^DB_PASSWORD=$OLD_PWD$" "$file"; then
    if grep -q "^DB_HOST=$DB_HOST$" "$file"; then
        # 使用 sed 替换 DB_PASSWORD 的旧值为新值
        sed -i "s/DB_PASSWORD=$OLD_PWD/DB_PASSWORD=$NEW_PWD/g" "$file"

        echo "在文件 $file 中将 DB_PASSWORD=$OLD_PWD 替换为 DB_PASSWORD=$NEW_PWD"
    else
        echo " $file 无需修改，跳过替换操作"
    fi
done
```

#### 运行脚本
```bash
# 使用默认值
./update.sh

# 自定义参数 
./update.sh root_dir old_pwd new_pwd db_host
```

参数说明

| 参数位置(变量名称)  | 说明                    |
|-------------|-----------------------|
| 1(ROOT_DIR) | 项目根目录，如 /var/www |
| 2(OLD_PWD)  | 数据库旧密码         |
| 3(NEW_PWD)  | 数据库新密码         |
| 4(DB_HOST)  | 数据库主机地址        |
