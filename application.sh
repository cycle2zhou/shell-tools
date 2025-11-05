#!/bin/bash
#SpringBoot外置配置和第三方依赖包启动脚本
#by Cycle

#使用说明，用来提示输入参数
function usage() {
  echo "本脚本可检测系统JAVA环境变量、设置应用运行JVM参数、远程调试、查看实时日志、应用发布、应用回滚等功能;"
  echo "使用前需要先配置application.sh中main函数中的初始化变量"
  echo "使用方法: sh application.sh [start|stop|restart|log|status|push|rollback]"
  echo "参数说明:start 启动、stop 停止、restart 重启、log 实时日志、status 当前应用状态、push 发布新包,自动备份、rollback 回滚备份最后版本"
  exit 1
}

#脚本入口
function main() {
  #============================初始化变量开始============================
  #必需:应用名,pid目录和性能监控中心都需要用到此名，对应：spring.application.name
  readonly app_name=demo
  #性能监控中心开关
  readonly apm_server_enabled=false
  #性能监控中心应用分组
  readonly apm_server_group_name=dev
  #性能监控中心地址
  readonly apm_server=192.168.100.103:11800
  #性能监控中心忽略的请求路径
  readonly apm_server_ignore_path="/eureka/**,/actuator/**"
  #是否启用调试模式
  readonly debug=false
  #调试端口
  readonly debug_port=5555
  #是否记录gc日志
  readonly gc_log_enabled=true
  #应用gc日志保存周期,为空则不清理过期日志;单位:天
  local app_gc_log_period=60
  #启动模式，可选值：service[服务模式,默认],auto[自动模式，即前台模式，关闭ssh连接就会停止服务]
  readonly mode=service
  #应用关闭等待时间,单位秒
  readonly stop_wait_time=120
  #日志中启动成功标记字符串,根据该字符串判断应用是否完全启动成功
  readonly started_success_message="Application started successfully By Jar"
  #应用jasypt主密码;可以设置服务器环境变量[JASYPT_ENCRYPTOR_PASSWORD]覆盖,同时设置优先使用服务器环境变量值
  local jasypt_master_password=123456
  #java安装目录，不设置自动通过"$(readlink -f "$(which java)")"获取环境变量；指定到**/bin/java
  # shellcheck disable=SC2155
  readonly java_path="$(readlink -f "$(which java)")"
  #防止jenkins杀进程
  export JENKINS_NODE_COOKIE=dontKillMe

  local prg last_dir service_path config_path service_path_array config
  #定位当前工作路径
  prg="$0"
  #运行脚本的上级目录
  last_dir=$(dirname "$prg")/..
  #应用运行空间
  app_workspace=$(cd "$last_dir" && pwd)
  #日志保存目录
  app_log_dir="${app_workspace}/logs"
  #pid目录
  app_pid_dir="${app_log_dir}/pid"
  #控制台输出文件
  app_nohup_file="${app_name}.out"
  #应用pid记录文件
  app_pid_file="${app_name}.pid"
  #创建pid存放目录
  mkdir -p "${app_pid_dir}"
  #创建GC日志目录
  mkdir -p "${app_log_dir}/gc"
  #隐藏光标
  c_hide_cursor='\033[?25l'
  #显示光标
  c_show_cursor='\033[?25h'
  #信号状态;0-初始状态，1-启动完成，2-退出
  signal_status=0
  #启动状态码；0-启动中，1-启动成功，2-启动失败
  start_status=0
  #脚本自身的pid
  self_pid=$$

  #JVM虚拟机参数
  #-XX:MetaspaceSize=128m （元空间默认大小）
  #-XX:MaxMetaspaceSize=128m （元空间最大大小）
  #-Xms1024m （堆最大大小）
  #-Xmx1024m （堆默认大小）
  #-Xmn256m （新生代大小）
  #-Xss256k （棧最大深度大小）
  #-XX:SurvivorRatio=8 （新生代分区比例 8:2）
  #-XX:+UseG1GC （指定使用的垃圾收集器，这里使用G1收集器）
  #-XX:+UseStringDeduplication (开启字符串去重)
  #-XX:GCLogFileSize=100M (每个文件上限大小，超过就触发分割)
  java_jvm_opts="
  -server
  -Xms1024m
  -Xmx2048m
  -Xmn256m
  -Xss384k
  -XX:MetaspaceSize=128m
  -XX:MaxMetaspaceSize=512m
  -XX:SurvivorRatio=8
  -XX:+UnlockExperimentalVMOptions
  -XX:+UseG1GC
  -XX:+UseStringDeduplication
  -Djava.net.preferIPv4Stack=true
  -Duser.timezone=Asia/Shanghai
  -Dclient.encoding.override=UTF-8
  -Dfile.encoding=UTF-8
  -Djava.security.egd=file:/dev/./urandom
  -XX:+HeapDumpOnOutOfMemoryError
  -Dapp.runtime.type=jar
  -Dapp.gc.log.period=${app_gc_log_period}
  -Dapp.nohup.out.path=${app_log_dir:?}/${app_nohup_file:?}
  -Dapp.gc.log.path=${app_log_dir}/gc
  -Dapp.workspace.path=${app_workspace}
  -Djasypt.encryptor.password=$([ -z "${JASYPT_ENCRYPTOR_PASSWORD}" ] && echo "${jasypt_master_password}" || echo "${JASYPT_ENCRYPTOR_PASSWORD}")
  -Dlogging.config=${app_workspace}/conf/logback-spring.xml
  -Dlogging.file.path=${app_log_dir}
  -Dloader.path=${app_workspace}/lib
  -Dspring.config.location=${app_workspace}/conf/
  -Dspring.pid.file=${app_pid_dir}/${app_pid_file}"

  #============================初始化变量结束============================
  #JDK没安装直接退出
  if ! [[ -x "$(command -v "$java_path")" ]]; then
    warn "缺少Java运行环境,请检查Jdk或Jre"
    exit 1
  fi

  #检查应用名
  if [[ -z $app_name ]]; then
    warn "未配置应用名,请检查应用名"
    exit 1
  fi

  #检查fuser命令,代码中清理nohup.out需要该命令
  ensure_command "fuser" "${app_workspace}/depend/rpm/psmisc-22.20-17.el7.x86_64.rpm" "psmisc"
  fixed_out "应用环境检测，开始"
  echo
  #输出java详细版本信息
  $java_path -version
  echo
  info "应用名称: ${app_name}"
  if [[ $debug == true ]]; then
    info "调试端口: ${debug_port}"
  fi
  info "应用工作目录: ${app_workspace}"
  service_path=$(find "${app_workspace}/app" -name "*.jar")
  # shellcheck disable=SC2206
  service_path_array=("${service_path//.jar/}")
  if [[ ${#service_path_array[*]} -gt 1 ]]; then
    warn "目录[${app_workspace}/app]下找到多个应用jar包,无法确定运行目标"
    fixed_out "应用环境检测，结束"
    exit
  fi
  info "应用Jar包路径: ${service_path}"
  service_name=${service_path##*/}
  info "应用Jar包名称: ${service_name}"
  config_path=("$(find "${app_workspace}/conf" -name "*.yml" -or -name "*.properties" -or -name "*.xml")")
  info "应用配置文件列表:"
  for config in "${config_path[@]}"; do #以这种for打印数组
    printf "\033[0;34m%s\n\033[0m" "${config}"
  done
  push_jars=$(find "${app_workspace}/release" -name "*.jar")
  if [[ -n ${push_jars} ]]; then
    info "应用待发布Jar包列表:"
    for push_jar in ${push_jars}; do
      printf "\033[0;34m%s\n\033[0m" "${push_jar}"
    done
  fi
  echo
  fixed_out "应用环境检测，结束"

  #启动成功信号
  trap 'signal_started' HUP
  #处理用户ctrl+c或者终端掉线等等情况时的.out日志过大问题
  trap 'signal_quit' INT QUIT TSTP ALRM

  #根据输入参数，选择执行对应方法，不输入则执行使用说明
  case "$1" in
    "start")
      start "$@"
      ;;
    "stop")
      stop "$@"
      ;;
    "log")
      show_log
      ;;
    "status")
      status
      ;;
    "restart")
      restart
      ;;
    "push")
      push
      ;;
    "rollback")
      rollback
      ;;
    *)
      usage
      ;;
  esac

  exit 0

}

#追加gc日志配置
function append_gc_log() {
  local java_version
  # 获取 Java 版本
  java_version=$($java_path -version 2>&1 | head -n 1)
  # 提取版本号
  if [[ $java_version =~ version\ \"1\.(5|6|7|8) ]]; then
    # 如果版本在 5-8 之间
    java_jvm_opts="$java_jvm_opts  -Xloggc:${app_log_dir}/gc/gc_%t_%p.log  -XX:+PrintGCDetails -XX:+PrintGCDateStamps -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=10 -XX:GCLogFileSize=100M"
  elif [[ $java_version =~ version\ \"([9-9]|[1-9][0-9]+) ]]; then
    # 如果版本是 9 或以上
    java_jvm_opts="$java_jvm_opts  -Xlog:async -Xlog:gc*:file=${app_log_dir}/gc/gc_%t_%p.log:uptimemillis,hostname,pid:filecount=10,filesize=100m"
  else
    # 其他情况
    echo "Java version is not within the expected range."
  fi
}

#追加debug参数
function append_debug() {
  local java_version
  # 获取 Java 版本
  java_version=$($java_path -version 2>&1 | head -n 1)
  # 提取版本号
  if [[ $java_version =~ version\ \"1\.(5|6|7|8) ]]; then
    # 如果版本在 5-8 之间
    java_jvm_opts="${java_jvm_opts} -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=${debug_port}"
  elif [[ $java_version =~ version\ \"([9-9]|[1-9][0-9]+) ]]; then
    # 如果版本是 9 或以上
    java_jvm_opts="${java_jvm_opts} -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:${debug_port}"
  else
    # 其他情况
    echo "Java version is not within the expected range."
  fi
}

#固定长度输出，不能包含空格
function fixed_out() {
  local total_length input_str str_width padding left_padding right_padding
  # 固定的总长度
  total_length=$(fixed_width)
  # 传入的字符串
  input_str="$1"
  # 获取字符串的实际宽度（考虑多字节字符）
  str_width=$(echo -n "$input_str" | iconv -f utf-8 -t gbk | wc -c)
  # 如果字符串宽度超过总长度，直接截取
  if ((str_width >= total_length)); then
    echo -n "$input_str" | cut -b1-$total_length
  else
    # 计算填充长度
    padding=$((total_length - str_width))
    left_padding=$((padding / 2))
    right_padding=$((padding - left_padding))
    # 使用 printf 进行居中填充并替换空格为 *
    printf "\033[0;36m%*s%s%*s\n\033[0m" "$left_padding" "" "$input_str" "$right_padding" "" | sed 's/ /*/g'
  fi
}

#info日志
function info() {
  echo -e "\033[0;32m>>> $1\033[0m"
}

#warn日志
function warn() {
  echo -e "\033[0;35m>>> $1 <<<\033[0m"
}

#检查程序是否在运行
function check_running() {
  local pid_file
  # 获取项目的pid文件
  pid_file=$(find "${app_pid_dir}" -name "${app_pid_file}")

  # 初始化java_pid为空
  java_pid=""

  # 优先从PID文件获取PID
  if [[ -n ${pid_file} ]]; then
    java_pid=$(head -1 "${pid_file}" 2>/dev/null) # 增加错误处理，避免文件为空导致的问题
  elif [[ -n ${service_path} ]]; then
    # 使用正则确保路径完整匹配（避免子目录或相似路径误判）
    java_pid=$(pgrep -f "java.*(^|/)${service_path//\//\\/}($|/| )" 2>/dev/null)
  fi

  # 检查PID是否有效
  if [[ -z ${java_pid} ]]; then
    return 1 # PID不存在
  fi

  # 检测PID对应的进程是否正在运行
  if ps -p "${java_pid}" >/dev/null 2>&1; then
    # 若PID文件不存在，创建PID文件
    if [[ -z ${pid_file} ]]; then
      echo "${java_pid}" >>"${app_pid_dir}/${app_pid_file}"
    fi
    return 0 # 进程存在
  else
    # 清理无效的PID文件
    if [[ -n ${pid_file} ]]; then
      rm -f "${pid_file:?}" # :?确保变量非空才执行，避免误删
    fi
    return 1 # 进程不存在
  fi
}

#启动方法
function start() {
  if check_running; then
    info "应用 ${app_name} 已经在运行中, PID=${java_pid}"
    return
  fi
  if [ -z "${service_path}" ]; then
    warn "未找到应用启动jar包,请检查[app]目录"
    return
  fi
  fixed_out "JVM参数配置，开始"
  if [[ ${gc_log_enabled} == true ]]; then
    info "追加gc日志配置"
    append_gc_log
  fi
  if [[ ${debug} == true ]]; then
    info "启动调试模式,端口:${debug_port}"
    append_debug
  fi
  #监控
  configure_apm
  #换行和去除空行输出所有jvm参数
  echo -e "\033[0;34m${java_jvm_opts}\033[0m" | tr ' ' '\n' | tr -s '\n'
  echo
  fixed_out "JVM参数配置，结束"
  echo
  fixed_out "启动应用，开始"
  #保证应用实时日志文件不存在
  rm -f "${app_log_dir:?}/${app_nohup_file:?}"
  if [[ ${mode} == "auto" ]]; then
    #前台模式启动
    # shellcheck disable=SC2086
    $java_path ${java_jvm_opts} -jar ${service_path}
    echo
    fixed_out "启动应用，结束"
    return
  fi
  #重置信号状态
  signal_status=0
  #后台模式启动
  # shellcheck disable=SC2086
  nohup $java_path ${java_jvm_opts} -jar ${service_path} --app_start_sh_pid=${self_pid} >>${app_log_dir:?}/${app_nohup_file:?} 2>&1 &
  #获取java程序的pid
  java_pid=$!
  local app_pid show start_log
  #判断当前应用是否有pid生成
  app_pid=$(find "${app_pid_dir}" -name "${app_pid_file}")
  if [[ -z ${app_pid} ]]; then
    #应用本身没有生成pid，那么获取当前pid写入文件
    echo ${java_pid} >>"${app_pid_dir}/${app_pid_file}"
  fi
  #不论是否查看日志都先占用日志输出文件
  tail -f "${app_log_dir}/${app_nohup_file}" >/dev/null 2>&1 &
  #获取日志输出的pid
  tail_log_pid=$!
  #是否查看实时日志
  read -r -t 10 -p "是否查看实时日志(y/n):" show
  echo
  if [[ ${show} == "y" ]] || [[ ${show} == "Y" ]]; then
    tail -f "${app_log_dir}/${app_nohup_file}"
    if check_started; then
      nohup_start_done
      return
    fi
    if check_running; then
      info "应用 ${app_name} 未获取到启动完成信号,请根据日志判断是否启动成功"
      echo
      nohup_start_done
      return
    fi
    warn "应用 ${app_name} 启动失败,请检查日志"
    echo
    nohup_start_done
    return
  fi

  #后台启动,判断是否已经启动完成了
  if check_started; then
    nohup_start_done
    return
  fi
  #开始加载动画
  start_loading
  if [[ $start_status -eq 1 ]]; then
    nohup_start_done
    return
  fi
  if [[ $start_status -eq 0 ]]; then
    echo
    info "应用 ${app_name} 还未完全启动,请稍后查看日志是否启动成功"
    echo
    nohup_start_done
    return
  fi
  echo
  warn "应用 ${app_name} 启动失败"
  read -r -t 10 -p "是否查看启动失败日志(y/n):" start_log
  if [[ ${start_log} == "y" ]] || [[ ${start_log} == "Y" ]]; then
    tail -n 50 "${app_log_dir}/${app_nohup_file}"
  fi
  echo
  nohup_start_done
}

#检测是否启动完成
function check_started() {
  if [[ $start_status -eq 1 ]] || grep -q "${started_success_message}" "${app_log_dir}/${app_nohup_file}"; then
    echo
    info "应用 ${app_name} 启动成功 PID=${java_pid}"
    echo
    return 0
  fi
  return 1
}

#后台启动完成
function nohup_start_done() {
  fixed_out "启动应用，完成"
  if ! ps -p "$tail_log_pid" >/dev/null 2>&1; then
    return
  fi
  disown "$tail_log_pid"
  kill "$tail_log_pid"
}

#无限加载动画
function start_loading() {
  #隐藏光标
  echo -en "${c_hide_cursor}"
  local message i dots
  # 要显示的静态文本
  message=">>> 应用 ${app_name} 启动中: "
  i=0
  dots=("   " "•  " "•• " "•••")
  while true; do
    if [[ $signal_status -eq 2 ]]; then
      #手动退出
      break
    fi
    if ! ps -p "$java_pid" >/dev/null 2>&1; then
      #应用进程退出
      start_status=2
      break
    fi
    if check_started; then
      #应用启动成功
      start_status=1
      break
    fi
    printf "\r%s%s" "${message}" "${dots[i]}"
    sleep 0.5
    i=$(((i + 1) % ${#dots[@]}))
  done
  #显示光标
  echo -en "${c_show_cursor}"
}

#监控中心
function configure_apm() {
  if [[ ${apm_server_enabled} == false ]]; then
    return
  fi
  #分割ip和端口
  # shellcheck disable=SC2206
  local array=(${apm_server//:/ })
  # 安装nc命令（用于端口检测）
  ensure_command "nc" "${app_workspace}/depend/rpm/nc-1.84-24.el6.x86_64.rpm" "nc"
  #检测AMP是否连接通畅
  info "开始检测APM性能监控中心连接性,请等待..."
  echo
  if ping -c 1 -W 5 "${array[0]}" >/dev/null && nc -w 5 "${array[0]}" -z "${array[1]}" >/dev/null; then
    info "配置AMP性能监控中心,连接到:${apm_server}"
    java_jvm_opts="${java_jvm_opts} -javaagent:${app_workspace}/depend/agent/skywalking-agent.jar -DSW_AGENT_NAME=$([ -z "${apm_server_group_name}" ] && echo ${app_name} || echo ${apm_server_group_name}::${app_name}) -DSW_AGENT_COLLECTOR_BACKEND_SERVICES=${apm_server} -Dskywalking.trace.ignore_path=${apm_server_ignore_path}"
  else
    warn "APM中心连接失败,性能采集不可用;如不需要采集忽略此信息或者关闭APM上报即可"
  fi
}

#启动成功信息
#shellcheck disable=SC2317
function signal_started() {
  echo
  #设置脚本状态
  signal_status=1
  #设置启动状态
  start_status=1
}

#退出信号
#shellcheck disable=SC2317
function signal_quit() {
  echo
  #设置脚本状态
  signal_status=2
  local fuser_output pid_array pid multiple_use
  fuser_output=$(fuser "${app_log_dir}/${app_nohup_file}" 2>/dev/null)
  # 将 fuser 输出转换为数组
  IFS=' ' read -r -a pid_array <<<"$fuser_output"
  #多占用
  multiple_use=false
  # 遍历所有 PID，检查是否存在除指定 PID 外的其他 PID
  for pid in "${pid_array[@]}"; do
    if [ "$pid" != "$java_pid" ]; then
      multiple_use=true
      break
    fi
  done
  # 多占用的情况，不清理实时日志
  if $multiple_use; then
    return
  fi
  #只有应用在使用日志输出文件，则清空实时日志文件
  : >"${app_log_dir}/${app_nohup_file}"
}

# 安装命令（优先包管理器，失败则用rpm）
function ensure_command() {
  local cmd_name=$1
  local rpm_path=$2
  local pkg_name=${3:-$1}

  if command -v "$cmd_name" &>/dev/null; then
    return 0
  fi

  warn "未检测到${cmd_name}，尝试安装..."

  if command -v yum &>/dev/null; then
    if yum install -y "$pkg_name"; then
      info "${cmd_name}安装成功"
      return 0
    fi
  elif command -v apt-get &>/dev/null; then
    if apt-get install -y "$pkg_name"; then
      info "${cmd_name}安装成功"
      return 0
    fi
  fi

  if [[ -f $rpm_path && -x "$(command -v rpm)" ]]; then
    if rpm -ivh "$rpm_path"; then
      info "${cmd_name}安装成功"
      return 0
    fi
  fi

  error_exit "${cmd_name}安装失败，请手动安装"
}

#清理应用临时文件
function clean_app() {
  #删除应用的pid文件
  rm -f "${app_pid_dir:?}/${app_pid_file:?}"
  #删除应用的.out文件
  rm -f "${app_log_dir:?}/${app_nohup_file:?}"
  # 确保光标显示
  echo -en "${c_show_cursor}"
}

#计算固定宽度
function fixed_width() {
  local width result
  # 获取终端宽度
  width=$(tput cols)
  #计算宽度
  result=$(echo "scale=0; $width * 0.9 / 1" | bc)
  # 返回结果
  echo "$result"
}

#打印实时日志
function show_log() {
  fixed_out "打印实时日志，开始"
  if ! check_running; then
    info "应用 ${app_name} 未运行"
  else
    #控制台输出实时日志
    tail -f "${app_log_dir}/${app_nohup_file}"
  fi
  fixed_out "打印实时日志，结束"
}

#停止方法
function stop() {
  fixed_out "关闭应用，开始"
  if ! check_running; then
    info "应用 ${app_name} 未运行"
    fixed_out "关闭应用，完成"
    return
  fi
  #检测bc命令是否安装
  ensure_command "bc" "${app_workspace}/depend/rpm/bc-1.06.95-13.el7.x86_64.rpm" "bc"
  #暂存应用pid值
  local java_temp_pid=${java_pid}
  #停止应用
  kill -15 "${java_pid}"
  #计算每次睡眠间隔
  local interval die total_dx head total head_width i
  interval=$(echo "scale=2;${stop_wait_time}/50" | bc)
  #隐藏光标
  echo -en "${c_hide_cursor}"
  #进度条显示内容
  #local total_dy="$(($(stty size | cut -d' ' -f1)))" #进度条显示的y轴位置在最底部
  total_dx=$(fixed_width)
  head=">>> 应用 ${app_name} 正在停机: "
  head_width=$(printf "%s" "$head" | wc -c)
  total=$((total_dx - head_width + 6))
  for ((i = 0; i <= 100; i += 2)); do
    if [[ $signal_status -eq 2 ]]; then
      break
    fi
    if ! check_running; then
      i=100
    fi
    local per=$((i * total / 100))
    local remain=$((total - per))
    printf "\r${head}\e[42m%${per}s\e[47m%${remain}s\e[00m" "" ""
    #以下语句会让进度条显示在终端的最底部
    #printf "\r\e[${total_dy};0H${head}\e[42m%${per}s\e[47m%${remain}s\e[00m" "" ""
    if [[ $i -ne 100 ]]; then
      sleep "${interval}"
    fi
  done
  #显示光标
  echo -en "${c_show_cursor}"
  echo
  #再次检查pid是否存在,如果pid经过关闭时间等待后依然存在，标示应用无法正常关闭
  if check_running; then
    read -r -t 10 -p "进程无法正常停止,是否强制停止(y[默认]/n):" die
    if [[ ${die} == "y" ]] || [[ ${die} == "Y" ]] || [[ -z ${die} ]]; then
      kill -9 "${java_temp_pid}"
      info "应用 ${app_name} 已停止,PID=${java_temp_pid}"
      clean_app
    else
      warn "应用无法正常停止,请检查!"
    fi
  else
    info "应用 ${app_name} 已停止,PID=${java_temp_pid}"
    clean_app
  fi
  fixed_out "关闭应用，完成"
}

#输出运行状态
function status() {
  fixed_out "查询应用状态，开始"
  if check_running; then
    info "应用 ${app_name} 正在运行 PID = ${java_pid}"
  else
    info "应用 ${app_name} 未运行"
  fi
  fixed_out "查询应用状态，完成"
}

#重启
function restart() {
  fixed_out "重启应用，开始"
  stop
  sleep 1
  echo
  start
  fixed_out "重启应用，完成"
}

#上线
function push() {
  fixed_out "上线应用，开始"
  local count_jar push_jar_name
  count_jar=$(find "${app_workspace}/release/" -name "*.jar" | wc -l)
  if [[ ${count_jar} -gt 1 ]]; then
    warn "找到了多个待发布的JAR"
    for push_jar in ${push_jars}; do
      printf "%s\n" "${push_jar##*/}"
    done
    #多个jar时让用户选择发布
    info "请选择需要发布的JAR包:"
    read -r push_jar_name
    be_push_jar="${app_workspace}/release/${push_jar_name}"
  else
    be_push_jar=${push_jars}
  fi
  #判断上线包是否存在
  if [[ ! -f $be_push_jar ]]; then
    warn "未找到准备上线发布JAR包"
  else
    stop
    echo
    rm_jar
    echo
    start
  fi
  fixed_out "上线应用，完成"
}

#回滚
function rollback() {
  fixed_out "回滚应用，开始"
  last_backup_suffix=$(find "${app_workspace}/backup/" -type f -name "*.jar_*" -exec basename {} \; 2>/dev/null | cut -d'_' -f2 | sort -n | tail -n 1)
  if [[ -z ${last_backup_suffix} ]]; then
    warn "未找到历史备份JAR包"
  else
    stop
    echo
    rollback_jar
    echo
    start
  fi
  fixed_out "回滚应用，完成"
}
#删除jar
function rm_jar() {
  #创建备份目录
  if [[ ! -d "${app_workspace}/backup" ]]; then
    mkdir "${app_workspace}/backup"
  fi
  #清理多余备份
  local backup_timestamp_list current backup_jar backup_timestamp
  #倒序获取时间戳，最前面的才是最新备份
  backup_timestamp_list=$(find "${app_workspace}/backup/" -type f -name "*.jar_*" -exec basename {} \; 2>/dev/null | cut -d'_' -f2 | sort -r)
  local _backup_cnt=0
  for backup_timestamp in ${backup_timestamp_list}; do
    if [[ ${_backup_cnt} -gt 3 ]]; then
      #备份jar完整路径
      backup_jar=$(find "${app_workspace}/backup" -type f -name "*.jar_${backup_timestamp}" 2>/dev/null)
      #只保留5个备份
      rm -f "${backup_jar:?}"
      info "删除过期备份Jar文件:[${backup_jar}]"
    fi
    _backup_cnt=$((_backup_cnt + 1))
  done

  if [[ -n ${service_path} ]]; then
    current=$(date "+%Y%m%d%H%M%S")
    local jar_new_name=${service_name}_${current}
    info "备份Jar文件[${service_path}]至[${app_workspace}/backup/${jar_new_name}]"
    cp "${service_path}" "${app_workspace}/backup/${jar_new_name}"
    info "移除运行中Jar文件:[${service_path}]"
    rm -f "${service_path:?}"
  else
    info "应用[app]目录中不存在Jar文件,跳过备份"
  fi

  #新包赋权
  chmod +x "${be_push_jar}"
  #将发布包复制到运行目录中
  info "拷贝待发布jar文件[${be_push_jar}]至运行目录[$app_workspace/app/]"
  cp "${be_push_jar}" "${app_workspace}/app/"
  info "移除待发布jar文件:[${be_push_jar}]"
  rm -f "${be_push_jar:?}"
  #重新设置启动jar包名称
  service_path="${app_workspace}/app/${be_push_jar##*/}"
  service_name=${be_push_jar##*/}
}
#回滚jar
function rollback_jar() {
  local history_jar_path history_jar
  if [ -n "${service_path}" ]; then
    info "删除当前使用Jar包:[${service_path}]"
    #删除原jar包
    rm -f "${service_path:?}"
  fi
  #最新历史jar包路径
  history_jar_path=$(find "${app_workspace}/backup" -type f -name "*.jar_${last_backup_suffix}" 2>/dev/null)
  info "获取历史应用备份最新文件:[${history_jar_path}]"
  #最新历史jar包
  history_jar=${history_jar_path##*/}
  info "加载历史应用备份最新文件 [${history_jar_path}] 回滚为 [${app_workspace}/app/${history_jar%_*}]"
  cp "${history_jar_path}" "${app_workspace}/app/${history_jar%_*}"
  info "删除已回滚备份Jar文件:[${history_jar_path}]"
  rm -f "${history_jar_path}"
  #重新设置启动jar包名称
  service_path="${app_workspace}/app/${history_jar%_*}"
  service_name=${history_jar%_*}
}
main "$@"
