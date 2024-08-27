# shell-tools

一些shell工具脚本

## application.sh

![image-20240827162918135](assets/README/image-20240827162918135.png)

springboot通用启动脚本，脚本通过获取应用启动成功后发送的信号1或者日志中输出固定文本来精确判断是否真正启动成功还是失败

### 项目结构

```
└─┬ project #项目名
  ├── bin  #启动入口；application.sh脚本所在目录
  ├── app #springboot主jar包
  ├── conf #配置相关
  ├── lib #第三方依赖jar
  ├── resource #一些其他资源，如前端资源等
  ├── depend #运行所需依赖软件
  ├── logs #运行日志
  ├── backup #发布命令自动备份jar目录
  └── release #待发布的jar存放目录
```

