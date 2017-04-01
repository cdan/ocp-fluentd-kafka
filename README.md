Paas 日志系统组件--Fluentd
=========================
该组件定义为日志收集端，负责收集系统日志、OSE组件日志、POD标准输出日志。将日志进行分类，并对不同类别日志的字段个性化处理。
更多Fluentd的使用请参考[官方文档](http://docs.fluentd.org/v0.12/articles/quickstart)。

<br/>
**目录结构：**

```
fluentd
├src
|  ├conf                              fluentd的配置文件存放目录
|  ├kafka-fluentd-images              kafka-fluentd镜像的dockerfile存放目录
├template                             在OSE部署fluentd POD的模版
|  ├logging-fluentd-template.yaml        
└── README.md                描述文件
```

# ***运行机制 :***
主要描述fluentd的运行机制，接口，配置参数等。

### 配置接口
* 除fluentd镜像为UTC时区外，其余所有应用基础镜像和系统组件镜像都使用CST（亚洲上海）时区，设置方法为在镜像的dockerfile或者在POD启动时添加环境变量：TZ=Asia/Shanghai
* 在集群部署完成之后，需要将OSE组件的日志从系统日志messages中抽离出来，存放在目录/var/lib/origin/log/下，配置方法[请参考](src/conf/README.md)。
* fluentd负责采集系统日志和容器日志，需要将对应的目录挂载到fluentd POD中，目前挂载的目录有/var/log/,/var/lib/origin/log/
* fluentd POD挂载每个主机的/etc/hostname来获取POD所在的主机名称。
* Fluentd配置文件采用configmap挂载到fluentd POD中，挂载目录为POD中路径/etc/fluent/configs.d/user/fluent.conf。镜像中将/etc/fluent/configs.d/user/fluent.conf软链接到/etc/fluent/fluent.conf，fluentd进程启动时会读取该文件。

### 运行机制
* 操作系统日志和POD标准输出日志通过hostpath的方式将/var/log/目录挂载到fluentd POD容器中。如果有其他需要收集的文件，同样需要通过hostpath挂载到POD中，如OSE log。
* fluentd将挂载到POD中的日志文件作为输入的源，经分类处理后发送到kafka队列，详细的配置文件解析[请参考](src/conf/README.md)。

<br/>
# ***使用说明***
主要描述如何在OSE集群中使用和部署fluentd POD。

* 下载代码

```shell
$ git clone http://172.27.18.49/redhat/logging
$ cd logging/fluentd/
```
* build镜像并推送到仓库

 ```shell
 $ sh  build.sh
 $ docker push registry.cloud.com:5000/openshift3/kafka-logging-fluentd:3.4.0
 ```
注：
  1）镜像基于官方fluentd镜像构建，build前请先下载官方fluentd镜像。   
  2）构建过程需要有可用的yum源，用于安装kafka插件的依赖，请根据实际环境替换base.repo文件。  


* OSE的初始化操作

 ```shell
 #以管理员身份登录，以下赋权操作需要管理员权限
 $ oc login -u system:admin
 #创建并切换到Logging部署的Project
 $ oc new-project maintenance
 $ oc project maintenance
 # 创建fluentd POD运行的Serviceaccount
 $ oc create serviceaccount aggregated-logging-fluentd
 # Fluentd POD需要读取hosts的日志目录，需要特权模式运行
 $ oadm policy add-scc-to-user privileged      system:serviceaccount:maintenance:aggregated-logging-fluentd
 # fluentd POD会通过OSE API查询POD元数据信息，需要cluster-reader权限
 $ oadm policy add-cluster-role-to-user  cluster-reader     system:serviceaccount:maintenance:aggregated-logging-fluentd
 # 在maintenance项目中创建template
 $ oc create -f logging-fluentd-daemonset-template.yaml
 # 创建用于挂载fluentd配置文件的configmap
 $ oc create configmap logging-fluentd --from-file=fluent.conf
 # 所有OSE节点添加daemonset用于选择的label
 $ oc label node --all logging-infra-fluentd=true
```

* 使用集群管理员admin登录OSE webconsole，并选择logging-fluentd-daemonset-template部署fluentd。
注：目前版本中，只有管理员可以创建daemonset，普通开发人员是无法直接创建daemonset的，需要管理员开启权限。

* 其他操作方法:   

  1）查看fluentd daemonset

  ```shell
  $ oc get daemonset
  ```
  2）查看configmap

  ```shell
  $ oc get configmap
  $ oc edit configmap logging-fluentd
  ```
  3）更新configmap
  直接在configmap中修改文件很不方便，尤其在内容较多的情况下，使用如下命令实现configmap更新。

  ```shell
  $ oc create configmap logging-fluentd --from-file=fluent.conf -dry-run -o yaml | oc replace -f -
  ```
  4）优雅更新Daemonset
  在更新配置文件之后需要重启daemonset的POD，配置才会生效。虽然可以直接删除daemosnet的POD，但是生产上不建议这样操作。可以至此以下操作实现更新daemosnet。

  ```shell
  # 保留POD删除daemonset
  $ oc delete daemonset logging-fluentd --cascade=true
  # 创建新的daemonset，注意加版本号创建，同一namespace对象不可重名
  #可以直接在webconsole部署或者使用如下命令创建：
  $ oc process -f logging-fluentd-daemonset-template-v2.yaml | oc create -f -
  #删除旧版本daemonset的pod
  $ oc delete pod <daemonset_pod_v1_name>
  ```
<br/>

# ***改动说明 :***
* 镜像的改动：原有官方镜像不支持发送日志到kafka，重新build的fluentd镜像添加了fluentd-kafka插件。
* 模版的改动：
  1）为了统一时区，将官方fluentd镜像的时区设置为UTC，并取消/etc/localtime的挂载，在fluentd配置文件对不同类型的日志进行时区转换。
  2）添加/var/lib/origin/log/目录的挂载，因为集群部署的时候已将OSE组件日志从messages中抽取到/var/lib/origin/log/目录下。   
