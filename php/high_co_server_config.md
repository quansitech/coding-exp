## php-fpm高并发服务器配置

lnmp默认设置只能支持100左右的tps，此时一般瓶颈是在服务器性能。如果希望提高单机系统处理高并发业务，就需要对相关服务进行一系列的设置。

### 1. 通用设置

已docker容器运行服务为例，默认的系统同时可打开文件数为2048，表示最多只能分配2048个端口。php-fpm采用的是短链接方式，需要不停的创建和关闭连接，这时关闭的连接不会马上释放，会有端口用尽的风险。可以通过修改net.ipv4.tcp_max_tw_buckets的值来解决这个问题。

```docker-compose
php-fpm-prod:
    image: php-fpm-new:8.2
    container_name: php-fpm-prod
    sysctls:
      - net.ipv4.tcp_max_tw_buckets=5000
    ulimits:
        nofile:
          soft: 102400
          hard: 102400
    volumes:
      - /var/www:/var/www
      - ./php/www.conf:/usr/local/etc/php-fpm.d/www.conf
    networks:
      - backend
```

以上docker配置几乎是所有容器服务都需要设置的，表示打开容器时更改系统内核设置。


### 2. 修改nginx配置

单机架构nginx不会成为性能瓶颈，采用默认设置已经够用。不过也可以提高 worker_processes 的数量，一般设置为cpu核心数。同时提高workder_connections的数量，具体多少需要在压测过程中去摸索。

压测的过程中寻找能处理的请求数瓶颈，通过limit_req_zone来限制请求速率，避免服务器被攻击或者因为流量过猛导致服务器崩溃。

```nginx

http {

  log_format main '$http_x_forwarded_for - $remote_user [$time_local] "$request" '
                  '$status $body_bytes_sent "$http_referer" '
                  '"$http_user_agent"';

  server_tokens off;
  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 15;
  types_hash_max_size 2048;
  client_max_body_size 100M;
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log /dev/stdout;
  error_log /dev/stderr;
  gzip on;
  gzip_disable "msie6";
  limit_req_zone $remote_addr zone=mylimit:10m rate=10r/s; # 限制请求速率 每个ip每秒10个请求， 10m为共享内存大家，可以通过预估服务器需要服务的ip数量(1个大概1k的空间)来计算共享内存大小
  
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers 'ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA:ECDHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-RSA-AES256-SHA:ECDHE-ECDSA-DES-CBC3-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:DES-CBC3-SHA:!DSS:!kDHE';
  ssl_ecdh_curve X25519:prime256v1:secp384r1;
  
  include /etc/nginx/conf.d/*.conf;
  include /etc/nginx/sites-available/*.conf;
  open_file_cache off; # Disabled for issue 619
  charset UTF-8;

  server {
    location ~ [^/]\.php(/|$){
        limit_req zone=mylimit burst=20; # 启用前面设置的速率限制，burst 20表示可以临时突发20个请求/s，前面设置了10r/s，多出且少于20的请求数会排队等待，超出20的会直接返回503
        fastcgi_pass php8.2-upstream;
        fastcgi_index index.php;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;
        fastcgi_param PATH_INFO       $path_info;
        try_files $fastcgi_script_name =404;

        #fixes timeouts
        fastcgi_read_timeout 600;
        include fastcgi_params;
    }
  }
}

```

### 3. 修改php-fpm配置

php-fpm需要修改 pm.max_children 配置，修改服务器能正常处理的最大请求数，不要设置太高，跟nginx的设置一样，需要在压测过程中去摸索。

```php-fpm
pm.max_children = 1000 

; The number of child processes created on startup.
; Note: Used only when pm is set to 'dynamic'
; Default Value: min_spare_servers + (max_spare_servers - min_spare_servers) / 2
pm.start_servers = 25 # 这里的设置可以按注释的来，感觉影响不大

; The desired minimum number of idle server processes.
; Note: Used only when pm is set to 'dynamic'
; Note: Mandatory when pm is set to 'dynamic'
pm.min_spare_servers = 20 # 这里的设置可以按注释的来，感觉影响不大

; The desired maximum number of idle server processes.
; Note: Used only when pm is set to 'dynamic'
; Note: Mandatory when pm is set to 'dynamic'
pm.max_spare_servers = 50 # 这里的设置可以按注释的来，感觉影响不大
```

### 4. mysql

在my.cnf中增加 max_connections 配置，lnmp是短链接模式，需要设置一个比较大的值。

```mysql
[mysqld]
max_connections = 1000
```

### 5. redis

redis默认支持10000个连接，只需要设置好nofile和tcp_max_tw_buckets即可。