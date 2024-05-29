## 前端开发规范

#### 配置文件
+ 限定*Node*版本
   + 在项目根目录下创建一个*.nvmrc*文件，指定项目所需的*Node*版本;
     ```text
     v18.20.3
     ```
   + 设置*package.json*文件中的*engines*字段。
     ```json
     {
      "engines": {
        "node": ">=18 <19"
      }
     }
     ```

#### JavaScript规范
+ 变量声明：使用*const*和*let*代替*var*