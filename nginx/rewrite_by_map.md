# 使用 Nginx 的 map 功能来进行 rewrite


```text
通过在 map 指令中使用条件语句和正则表达式，可以实现根据不同的条件进行不同的 rewrite 操作。
这种方法不仅简化了多条件判断的实现，还提高了服务器配置的易读性和维护性。

例如，匹配静态资源进行域名重写，达到只将静态资源部署在 CDN 上的目的。
```

+ 定义 map,添加 rewrite_map.conf
  ```nginx
  map $host $enable_domain {
    	default 0;
    	~*YOUR_SOUR_DOMAIN 1; // 修改为需要匹配的域名
	}

	// 按需添加需要跳转的模块或者静态资源后缀
	map $uri $is_static {
	    default 0;
	    ~*/(Public)/ 1;
	    ~.*\.(gif|jpg|jpeg|bmp|swf|png)$ 1;
	    ~.*\.(js|css)?$ 1;
	}

	map "$enable_domain$is_static" $enable_redirect {
        default 0;
        11 1;
    }
  ```

+ 修改应用的nginx配置，应用rewrite
  ```nginx
  // map 在 http 模块有效
    include /etc/nginx/sites-available/rewrite_map.conf;
    
    server{
       set $cdn_domain YOUR_CDN_DOMAIN; // 设置CDN域名变量
    
        // 省略域名解析部分
            
        if ($enable_redirect){
          rewrite ^/(.*)$ https://$cdn_domain/$1 break;
        }
        
        // 在第一个location前
    
    }
  ```