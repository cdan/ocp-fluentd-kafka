
Fluentd配置文件解析&抽取OSE组件日志
========================

# 一、Fluentd配置文件解析

### ***配置文件主体解析 :***
Fleuntd配置文件主要分为四部分：  
1）系统配置域  
2）输入源配置域  
3）字段处理域  
4）输出配置域  

<br/>
#### ***重要配置说明***
系统配置、输入源、输出域的配置相对简单，此处忽略，以下重点对处理部分说明。

* 系统日志处理部分

```xml
<filter OSE-log.system.var.log.**>
  type record_transformer
  enable_ruby
  <record>
     hostname  ${(begin; File.open('/etc/docker-hostname') { |f| f.readline }.rstrip; rescue; end)}
     file_name  ${tag_suffix[4]}
     log_type  OSE-system
     log_level  info
     message  ${record['time']} ${record['log']}
     utctime  ${ Time.new(time.year, time.month, time.day, time.hour, time.min, time.sec, "+08:00").utc }
  </record>
  remove_keys  log
</filter>
<filter OSE-log.component.**>
  type record_transformer
  enable_ruby
  <record>
     hostname  ${(begin; File.open('/etc/docker-hostname') { |f| f.readline }.rstrip; rescue; end)}
     file_name ${tag_suffix[6]}
     log_type  ${tag_suffix[6]}
     log_level  info
     message  ${record['time']} ${record['log']}
     utctime  ${ Time.new(time.year, time.month, time.day, time.hour, time.min, time.sec, "+08:00").utc }
  </record>
  remove_keys  log
</filter>
<filter OSE-log.**>
  type record_transformer
  enable_ruby
  <record>
     time  ${ (Time.parse(utctime) > Time.now) ? (Time.new((Time.parse(utctime).year - 1), Time.parse(utctime).month, Time.parse(utctime).day, Time.parse(utctime).hour, Time.parse(utctime).min, Time.parse(utctime).sec, Time.parse(utctime).utc_offset).localtime("+08:00").to_datetime.rfc3339(6)) : Time.parse(utctime).localtime("+08:00").to_datetime.rfc3339(6) }
  </record>
  remove_keys  utctime
</filter>
```
说明：
第一部分是对系统日志messages做处理，主要是添加必要字段，移除非关键字段,并将时区转换为UTC。   
第二部分是对OSE组件日志做处理，主要是添加字段和移除非关键字段，并将时区转换为UTC。  
第三部分是对系统日志和OSE组件日志做时区的转换，将UTC时间转换为CST。  

* POD日志处理部分

```xml
<filter kubernetes.**>
  type kubernetes_metadata
  kubernetes_url "#{ENV['K8S_HOST_URL']}"
  bearer_token_file /var/run/secrets/kubernetes.io/serviceaccount/token
  ca_file /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  include_namespace_id false
</filter>

<filter kubernetes.**>
  type record_transformer
  enable_ruby
  <record>
     exist_business ${record['kubernetes']['labels']['business'] rescue nil}
  </record>
</filter>

<match kubernetes.**>
  @type rewrite_tag_filter
  rewriterule1 exist_business  ^(.+)$  business.${tag}
  rewriterule2 exist_business  !^(.+)$ non-business.${tag}
</match>
```
说明：
第一部分表示fluentd从OSE API获取POD的元数据信息，详细请参考[官网说明](https://github.com/fabric8io/fluent-plugin-kubernetes_metadata_filter)。
第二部分表示抽取POD上的business label，用于接下来判定是否为业务POD。
第三部分表示判定是否为业务容器。如果是，则retag为business，否则为non-business。

以下将分为两部分分别说明non-business POD日志和business POD日志的处理过程：

###### 第一部分：non-business POD日志处理
* 对非business POD日志处理

```xml
<filter non-business.**>
  type record_transformer
  enable_ruby
  <record>
     kubernetes_container_name  ${record['kubernetes']['container_name']}
  </record>
  remove_keys exist_business
</filter>
<match non-business.**>
  @type rewrite_tag_filter
  rewriterule1 kubernetes_container_name  ^(registry|registry-console)$  container.non-agent.OSE-registry.${tag}
  rewriterule2 kubernetes_container_name  ^(fluentd)$  container.non-agent.OSE-fluentd.${tag}
  rewriterule3 kubernetes_container_name  ^(router|svcrouter)$  container.non-agent.router.${tag}
  rewriterule4 kubernetes_container_name  ^(discovery-agent|stats-agent)$  container.non-agent.OSE-zabbixagent.${tag}
  rewriterule5 kubernetes_container_name  ^(.*)$  container.non-agent.system-other.${tag}
</match>
```
说明：
第一部分抽取非business POD中的container name字段，作为接下来判定系统容器组件的依据。
第二部分依据POD的container name对不同类型的日志retag。

* 对non-business日志分类处理

```xml
<filter container.non-agent.OSE-**>
  type record_transformer
  enable_ruby
  <record>
     time ${time.utc.localtime("+08:00").to_datetime.rfc3339(6)}
     hostname  ${(record['kubernetes']['host'] rescue nil) || File.open('/etc/docker-hostname') { |f| f.readline }.rstrip}
     file_name ${tag_suffix[8]}
     app_name  ${record['kubernetes']['labels']['deploymentconfig'] rescue nil}
     message  ${(message rescue nil) || log}
     container_id  ${record['docker']['container_id'] rescue nil}
     pod_name  ${record['kubernetes']['pod_name'] rescue nil}
     namespace  ${record['kubernetes']['namespace_name'] rescue nil}
     log_level  ${record['stream'] == 'stdout' ? 'info' : 'error'}
     log_type  ${tag_parts[2]}
  </record>
  remove_keys log,stream,kubernetes,docker,kubernetes_container_name
</filter>

<filter container.non-agent.router.**>
  type record_transformer
  enable_ruby
  <record>
     hostname  ${(record['kubernetes']['host'] rescue nil) || File.open('/etc/docker-hostname') { |f| f.readline }.rstrip}
     router_group  ${record['kubernetes']['labels']['routergroup'] rescue nil}
     app_name  ${record['kubernetes']['labels']['deploymentconfig'] rescue nil}
     file_name ${tag_suffix[8]}
     container_id  ${record['docker']['container_id'] rescue nil}
     pod_name  ${record['kubernetes']['pod_name'] rescue nil}
     namespace  ${record['kubernetes']['namespace_name'] rescue nil}
     message  ${(message rescue nil) || log}
     log_level ${record['stream'] == 'stdout' ? 'info' : 'error'}
     log_type  router-access
  </record>
  remove_keys time,log,stream,kubernetes,docker,kubernetes_container_name
</filter>
#deployer/builder pod
<filter container.non-agent.system-other.**>
  type record_transformer
  enable_ruby
  <record>
     time ${time.utc.localtime("+08:00").to_datetime.rfc3339(6)}
     hostname  ${(record['kubernetes']['host'] rescue nil) || File.open('/etc/docker-hostname') { |f| f.readline }.rstrip}
     file_name ${tag_suffix[8]}
     app_name  ${record['kubernetes']['container_name'] rescue nil}
     message  ${(message rescue nil) || log}
     container_id  ${record['docker']['container_id'] rescue nil}
     pod_name  ${record['kubernetes']['pod_name'] rescue nil}
     namespace  ${record['kubernetes']['namespace_name'] rescue nil}
     log_level  ${record['stream'] == 'stdout' ? 'info' : 'error'}
     log_type  OSE-other
  </record>
  remove_keys log,stream,kubernetes,docker,kubernetes_container_name
</filter>
```
说明：
第一部分处理OSE-fluentd,OSE-zabbixagent,OSE-registry
第二部分处理router的日志
第三部分处理OSE-other日志，主要是deployer，builder等临时容器的日志。

###### 第二部分：business POD日志处理

```xml
<match business.**>
  @type rewrite_tag_filter
  rewriterule1 log  ^(~\^&),.*$  application.${tag}
  rewriterule2 log  ^\[ZBX-[A-Z]{3,4}-DEBUG\].*$  container.agent.zabbixagent.${tag}
  rewriterule3 log  ^(.*)$  container.agent.default.${tag}
</match>
<filter container.agent.zabbixagent.**>
  type record_transformer
  enable_ruby
  <record>
     time ${time.utc.localtime("+08:00").to_datetime.rfc3339(6)}
     hostname  ${(record['kubernetes']['host'] rescue nil) || File.open('/etc/docker-hostname') { |f| f.readline }.rstrip}
     file_name ${tag_suffix[8]}
     app_name  ${record['kubernetes']['labels']['deploymentconfig'] rescue nil}
     message  ${(message rescue nil) || log}
     container_id  ${record['docker']['container_id'] rescue nil}
     pod_name  ${record['kubernetes']['pod_name'] rescue nil}
     namespace  ${record['kubernetes']['namespace_name'] rescue nil}
     log_level  ${record['stream'] == 'stdout' ? 'info' : 'error'}
     log_type  OSE-zabbixagent
  </record>
  remove_keys log,stream,kubernetes,docker,exist_business
</filter>
<filter container.agent.default.**>
  type record_transformer
  enable_ruby
  <record>
     time ${time.utc.localtime("+08:00").to_datetime.rfc3339(6)}
     hostname  ${(record['kubernetes']['host'] rescue nil) || File.open('/etc/docker-hostname') { |f| f.readline }.rstrip}
     business ${record['kubernetes']['labels']['business'] rescue nil}
     module ${record['kubernetes']['labels']['module'] rescue nil}
     app_name  ${record['kubernetes']['labels']['deploymentconfig'] rescue nil}
     version  ${record['kubernetes']['labels']['deploymentconfig'].split('-v-').fetch(1, nil) rescue nil}
     container_id  ${record['docker']['container_id'] rescue nil}
     pod_name  ${record['kubernetes']['pod_name'] rescue nil}
     namespace  ${record['kubernetes']['namespace_name'] rescue nil}
     file_name ${tag_suffix[8]}
     log_type  business-stdout
     log_level  ${record['stream'] == 'stdout' ? 'info' : 'error'}
     message  ${record['log']  rescue nil}
  </record>
  remove_keys time,log,stream,kubernetes,docker
</filter>
```
说明：
第一部分将business日志分为应用日志，zabiixagent日志，default日志，接下来的两部分对zabbixagent和defaut日志处理。
应用日志表示APP通过logagent输出的日志，zabbixagent日志表示在每个应用POD中输出到标准输出的日志，default日志表示应用未经过logagnet打印在标准输出的日志。

* 处理应用经logagent打印的日志

```xml
<filter application.**>
  type record_transformer
  enable_ruby
  <record>
     log_type  ${record['log'].split(',').fetch(2, nil) rescue nil}
  </record>
  remove_keys exist_business
</filter>

<match application.**>
  @type rewrite_tag_filter
  rewriterule1 log_type  ^(business-running)$  container.agent.business-running.${tag}
  rewriterule2 log_type  ^(OSE-logagent)$  container.agent.logagent.${tag}
  rewriterule3 log_type  ^(.*)$  container.agent.business-applog.${tag}
</match>
<filter container.agent.business-**>
  type record_transformer
  enable_ruby
  <record>
     hostname  ${(record['kubernetes']['host'] rescue nil) || File.open('/etc/docker-hostname') { |f| f.readline }.rstrip}
     business ${record['kubernetes']['labels']['business'] rescue nil}
     module ${record['kubernetes']['labels']['module'] rescue nil}
     app_name  ${record['kubernetes']['labels']['deploymentconfig'] rescue nil}
     version  ${record['kubernetes']['labels']['deploymentconfig'].split('-v-').fetch(1, nil) rescue nil}
     container_id  ${record['docker']['container_id'] rescue nil}
     pod_name  ${record['kubernetes']['pod_name'] rescue nil}
     namespace  ${record['kubernetes']['namespace_name'] rescue nil}
     file_name  ${record['log'].split(',').fetch(1, nil) rescue nil}
     message  ${record['log'].split(',').last(record['log'].split(',').size - 3).join(',') rescue nil}
  </record>
  remove_keys time,log,stream,kubernetes,docker
</filter>
<filter container.agent.logagent.**>
  type record_transformer
  enable_ruby
  <record>
     time ${time.utc.localtime("+08:00").to_datetime.rfc3339(6)}
     hostname  ${(record['kubernetes']['host'] rescue nil) || File.open('/etc/docker-hostname') { |f| f.readline }.rstrip}
     file_name ${record['log'].split(',').fetch(1, nil) rescue nil}
     app_name  ${record['kubernetes']['labels']['deploymentconfig'] rescue nil}
     message  ${record['log'].split(',').last(record['log'].split(',').size - 3).join(',') rescue nil}
     container_id  ${record['docker']['container_id'] rescue nil}
     pod_name  ${record['kubernetes']['pod_name'] rescue nil}
     namespace  ${record['kubernetes']['namespace_name'] rescue nil}
     log_level  ${record['stream'] == 'stdout' ? 'info' : 'error'}
  </record>
  remove_keys log,stream,kubernetes,docker
</filter>
```
说明：
第一部分对应用日志按logtype分为business-running，business-applog，logagent三类日志，然后分别对三类日志处理。

* 添加kafka partition散列字段

```xml
<filter OSE-log.**>
  type record_transformer
  enable_ruby
  <record>
     partition_key ${record["hostname"]}-${record["file_name"]}
  </record>
</filter>
<filter container.**>
  type record_transformer
  enable_ruby
  <record>
     partition_key ${record["pod_name"]}-${record["file_name"]}
  </record>
</filter>
```
说明：
分别对系统日志和容器日志设置不同的partition key，该key将用于散列数据到kafka不同partition，partition key相同则会被分配到相同的partition中。

# 二、OSE组件日志的抽取
#### ***操作步骤***
默认OSE所有组件日志会打印到操作系统日志/var/log/messages中，下面我们将调整到/var/lib/ose/log目录下。
所有OSE节点抽取日志操作如下：

* 创建日志目录

 ```shell
 $ mkdir /var/lib/origin/log
 ```

* 修改rsyslog配置文件
在46行后添加以下内容：

 ```shell
 $ vi /etc/rsyslog.conf
 #### RULES ####
 :programname, contains, "atomic-openshift-master" /var/lib/origin/log/OSE-master
 :programname, contains, "atomic-openshift-node" /var/lib/origin/log/OSE-node
 :programname, contains, "docker" /var/lib/origin/log/OSE-docker
 :programname, contains, "etcd" /var/lib/origin/log/OSE-etcd

 :programname, contains, "atomic-openshift-master" stop
 :programname, contains, "atomic-openshift-node" stop
 :programname, contains, "docker" stop
 :programname, contains, "etcd" stop
 ```

* 重启rsyslog服务

 ```shell
 $ systemctl restart rsyslog
 ```

* 配置日志轮转，创建轮转策略文件

```shell
$ vi /etc/logrotate.d/ocplog
/var/lib/origin/log/OSE-master
/var/lib/origin/log/OSE-node
/var/lib/origin/log/OSE-docker
/var/lib/origin/log/OSE-etcd
{
    daily
    rotate 5
    size  1000M
    missingok
    sharedscripts
    postrotate
        /bin/kill -HUP `cat /var/run/syslogd.pid 2> /dev/null` 2> /dev/null || true
    endscript
}
```
