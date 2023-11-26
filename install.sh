#!/usr/bin/env bash

# 在脚本执行过程中如果有任何错误则退出
set -euxo pipefail

# 设置默认变量值，如果未定义则使用默认值
: ${CONFIG_PATH:="$HOME/klipper_config"}
: ${GCODE_PATH:="$HOME/gcode"}

: ${KLIPPER_REPO:="https://github.com/KevinOConnor/klipper.git"}
: ${KLIPPER_PATH:="$HOME/klipper"}
: ${KLIPPY_VENV_PATH:="$HOME/klippy-env"}

: ${MOONRAKER_REPO:="https://github.com/Arksine/moonraker"}
: ${MOONRAKER_PATH:="$HOME/moonraker"}
: ${MOONRAKER_VENV_PATH:="$HOME/moonraker-env"}

: ${CLIENT:="fluidd"}
: ${CLIENT_PATH:="$HOME/www"}

# 如果脚本以root身份运行，输出错误信息并退出
if [ $(id -u) = 0 ]; then
    echo "This script must not run as root"
    exit 1
fi

################################################################################
# 安装必要的软件包
################################################################################

# 安装必要的软件包
sudo apk add git unzip libffi-dev make gcc g++ \
ncurses-dev avrdude gcc-avr binutils-avr avr-libc \
python3 py3-virtualenv \
python3-dev freetype-dev fribidi-dev harfbuzz-dev jpeg-dev lcms2-dev openjpeg-dev tcl-dev tiff-dev tk-dev zlib-dev \
jq udev libsodium curl-dev lmdb-dev patch py3-pip

# 根据选择的客户端安装相应的软件包
case $CLIENT in
  fluidd)
    CLIENT_RELEASE_URL=$(curl -s https://api.github.com/repos/fluidd-core/fluidd/releases | jq -r '.[0].assets[0].browser_download_url')
    ;;
  mainsail)
    CLIENT_RELEASE_URL=$(curl -s https://api.github.com/repos/mainsail-crew/mainsail/releases | jq -r '.[0].assets[0].browser_download_url')
    ;;
  *)
    echo "Unknown client $CLIENT (choose fluidd or mainsail)"
    exit 2
    ;;
esac


################################################################################
# 安装和配置 Klipper
################################################################################

# 创建存储配置和G-code的目录
mkdir -p $CONFIG_PATH $GCODE_PATH

# 如果Klipper目录不存在，则克隆Klipper仓库
test -d $KLIPPER_PATH || git clone $KLIPPER_REPO $KLIPPER_PATH
# 如果虚拟环境目录不存在，则创建虚拟环境
test -d $KLIPPY_VENV_PATH || virtualenv -p python3 $KLIPPY_VENV_PATH
# 升级pip并安装Klipper的依赖
$KLIPPY_VENV_PATH/bin/python -m pip install --upgrade pip
$KLIPPY_VENV_PATH/bin/pip install -r $KLIPPER_PATH/scripts/klippy-requirements.txt

# 创建Klipper的启动脚本
sudo tee /etc/init.d/klipper <<EOF
#!/sbin/openrc-run
command="$KLIPPY_VENV_PATH/bin/python"
command_args="$KLIPPER_PATH/klippy/klippy.py $CONFIG_PATH/printer.cfg -l /tmp/klippy.log -a /tmp/klippy_uds"
command_background=true
command_user="$USER"
pidfile="/run/klipper.pid"
EOF

# 赋予执行权限
sudo chmod +x /etc/init.d/klipper
# 将Klipper添加到系统启动项，并启动服务
sudo rc-update add klipper
sudo service klipper start

################################################################################
# 安装和配置 Moonraker
################################################################################

# 如果Moonraker目录不存在，则克隆Moonraker仓库
test -d $MOONRAKER_PATH || git clone $MOONRAKER_REPO $MOONRAKER_PATH
# 如果虚拟环境目录不存在，则创建虚拟环境
test -d $MOONRAKER_VENV_PATH || virtualenv -p python3 $MOONRAKER_VENV_PATH

# 修复Moonraker的依赖问题
sed -i '/lmdb/d' $MOONRAKER_PATH/scripts/moonraker-requirements.txt
test -d /tmp/lmdb || git clone https://github.com/jnwatson/py-lmdb /tmp/lmdb

# 使用虚拟环境
source $MOONRAKER_VENV_PATH/bin/activate
# 添加以下两行来确保 setuptools 和 pip 安装正确
python -m pip install lmdb
python3 -m ensurepip --default-pip
python3 -m pip install --upgrade pip setuptools
# 切换到 /tmp/lmdb 目录
cd /tmp/lmdb
# 在 /tmp/lmdb 目录中构建
LMDB_FORCE_SYSTEM=1 python3 setup.py build
$MOONRAKER_VENV_PATH/bin/pip install pytest
pytest -v -k 'not testIterWithDeletes' /tmp/lmdb/tests
LMDB_FORCE_SYSTEM=1 python3 setup.py install
# 切换回脚本的原始目录
cd -
deactivate

# 安装Moonraker的依赖
$MOONRAKER_VENV_PATH/bin/python -m pip install --upgrade pip
$MOONRAKER_VENV_PATH/bin/pip install -r $MOONRAKER_PATH/scripts/moonraker-requirements.txt

# 创建Moonraker的启动脚本
sudo tee /etc/init.d/moonraker <<EOF
#!/sbin/openrc-run
command="$MOONRAKER_VENV_PATH/bin/python"
command_args="$MOONRAKER_PATH/moonraker/moonraker.py -c $CONFIG_PATH/moonraker.conf -l /tmp/moonraker.log"
command_background=true
command_user="$USER"
pidfile="/run/moonraker.pid"
depend() {
  before klipper
}
EOF

# 赋予执行权限
sudo chmod a+x /etc/init.d/moonraker

# 创建Moonraker的配置文件
cat > $HOME/moonraker.conf <<EOF
[server]
host: 0.0.0.0
port: 7125
# 用于调试的详细日志记录，默认为False。
enable_debug_logging: True
# 文件上传的最大大小（以MiB为单位），默认为1024 MiB
max_upload_size: 1024

[machine]
provider: none

[file_manager]
config_path: $CONFIG_PATH
log_path: /tmp/klipper_logs
# 对象取消的后处理，不建议在资源较低的SBC上使用，如Pi Zero。默认为False
enable_object_processing: False

[database]
database_path: $HOME/.moonraker_database

[authorization]
cors_domains:
    https://my.mainsail.xyz
    http://my.mainsail.xyz
    http://*.local
    http://*.lan
trusted_clients:
    10.0.0.0/8
    127.0.0.0/8
    169.254.0.0/16
    172.16.42.0/16
    192.168.0.0/16
    192.168.0.254
    FE80::/10
    ::1/128
EOF

# 将Moonraker添加到系统启动项，并启动服务
sudo rc-update add moonraker
sudo service moonraker start

################################################################################
# 安装和配置 Mainsail/Fluidd
################################################################################

# 安装Caddy和额外的软件包
sudo apk add caddy curl

# 创建Caddy的配置文件
sudo tee /etc/caddy/Caddyfile <<EOF
:80

encode gzip

root * $CLIENT_PATH

@moonraker {
  path /server/* /websocket /printer/* /access/* /api/* /machine/*
}

route @moonraker {
  reverse_proxy localhost:7125
}

route /webcam {
  reverse_proxy localhost:8081
}

route {
  try_files {path} {path}/ /index.html
  file_server
}
EOF

# 如果客户端目录存在，则删除并重新创建
test -d $CLIENT_PATH && rm -rf $CLIENT_PATH
mkdir -p $CLIENT_PATH
# 下载并解压缩选择的客户端
(cd $CLIENT_PATH && wget -q -O $CLIENT.zip $CLIENT_RELEASE_URL && unzip $CLIENT.zip && rm $CLIENT.zip)

# 将Caddy添加到系统启动项，并启动服务
sudo rc-update add caddy
sudo service caddy start

# 更新脚本

cat > $HOME/update <<EOF
#!/usr/bin/env bash

set -exo pipefail

: \${CLIENT:="$CLIENT"}
: \${CLIENT_PATH:="$CLIENT_PATH"}

case \$CLIENT in
  fluidd)
    CLIENT_RELEASE_URL=$(curl -s https://api.github.com/repos/fluidd-core/fluidd/releases/latest | jq -r ".assets[0].browser_download_url")
    ;;
  mainsail)
    CLIENT_RELEASE_URL=$(curl -s https://api.github.com/repos/mainsail-crew/mainsail/releases/latest | jq -r ".assets[0].browser_download_url")
    ;;
  *)
    echo "Unknown client \$CLIENT (choose fluidd or mainsail)"
    exit 2
    ;;
esac

# 更新Klipper
sudo service klipper stop
(cd $KLIPPER_PATH && git fetch && git rebase origin/master)
$KLIPPY_VENV_PATH/bin/pip install -r $KLIPPER_PATH/scripts/klippy-requirements.txt
test -z "\$FLASH_DEVICE" || (cd $KLIPPER_PATH && make && make flash)
sudo service klipper start

# 更新Moonraker
sudo service moonraker stop
(cd $MOONRAKER_PATH && git fetch && git rebase origin/master)
$MOONRAKER_VENV_PATH/bin/pip install -r ~/moonraker/scripts/moonraker-requirements.txt
sudo service moonraker start

# 更新客户端
rm -Rf \$CLIENT_PATH
mkdir -p \$CLIENT_PATH
(cd \$CLIENT_PATH && wget -q -O \$CLIENT.zip \$CLIENT_RELEASE_URL && unzip \$CLIENT.zip && rm \$CLIENT.zip)
sudo service caddy start
EOF

# 赋予执行权限
chmod a+x $HOME/update
