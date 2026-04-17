#!/bin/bash
set -euo pipefail

# 定义颜色输出函数，方便查看执行状态
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
nc='\033[0m' # No Color

# base func
info() {
	echo -e "${green}[INFO] ${1}${nc}"
}

warn() {
	echo -e "${yellow}[WARN] ${1}${nc}"
}

error() {
	echo -e "${red}[ERROR] ${1}${nc}"
	exit 1
}

# 检查是否为root用户
check_root_permission() {

	if [ "$(id -u)" -ne 0 ]; then
		error "该脚本需要以root权限运行，请使用 sudo bash $0 执行"
	fi
	info "root权限验证通过"
}

# 获取执行脚本的原始用户（非root）
get_original_user() {
	# 双重默认值：SUDO_USER为空→USER为空→默认root
	ORIGINAL_USER="${SUDO_USER:-${USER:-root}}"
	# 安全获取用户家目录
	ORIGINAL_USER_HOME=$(eval echo ~"${ORIGINAL_USER}")

	export ORIGINAL_USER
	export ORIGINAL_USER_HOME
	info "当前操作用户：${ORIGINAL_USER}，home目录：${ORIGINAL_USER_HOME}"
}

# 获取Ubuntu版本代号和对应的数字版本
get_ubuntu_version() {
	UBUNTU_CODENAME=$(lsb_release -cs)
	UBUNTU_VERSION=$(lsb_release -rs | cut -d '.' -f 1-2) # 如 22.04
	if [ -z "$UBUNTU_CODENAME" ] || [ -z "$UBUNTU_VERSION" ]; then
		error "无法获取Ubuntu版本信息，请确认系统为Ubuntu发行版"
	fi

	export UBUNTU_CODENAME
	export UBUNTU_VERSION
	info "检测到Ubuntu系统：${UBUNTU_VERSION} (${UBUNTU_CODENAME})"

}

# 替换为清华Ubuntu源
setup_tsinghua_source() {
	info "开始替换为清华源..."
	if [ ! -f /etc/apt/sources.list.bak ]; then
		cp /etc/apt/sources.list /etc/apt/sources.list.bak
		info "已备份原有源文件到 /etc/apt/sources.list.bak"
	else
		warn "源文件备份已存在，跳过备份步骤"
	fi

	cat >/etc/apt/sources.list <<EOF
# 清华源
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

	apt update -y || error "更新源失败，请检查网络或源配置"
	info "成功替换为清华源并完成更新"

}

# 安装基础开发工具和常用软件
install_base_tools() {
	info "开始安装git、vim、cmake、terminator、zsh、gcc、g++..."
	apt install -y git vim cmake terminator zsh gcc g++ curl shfmt || error "基础工具安装失败"
	info "基础开发工具安装完成"
}

# 安装oh-my-zsh
install_oh_my_zsh() {
	info "开始安装oh-my-zsh..."
	# 已提前安装zsh，此处仅检查并安装oh-my-zsh
	if [ ! -d "${ORIGINAL_USER_HOME}/.oh-my-zsh" ]; then
		# 切换到原始用户执行安装（避免安装到root目录）
		sudo -u "${ORIGINAL_USER}" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
		info "成功安装oh-my-zsh"

	else
		warn "oh-my-zsh已安装，跳过安装步骤"
	fi

	# 安装常用的插件
	info "开始安装常用的插件..."
	git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
	git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
	git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k

	# 将默认shell修改为zsh
	info "开始将默认shell修改为zsh..."
	# 检查zsh是否在合法shell列表中
	if ! grep -q "$(which zsh)" /etc/shells; then
		info "zsh未加入合法shell列表，正在添加..."
		echo "$(which zsh)" >>/etc/shells || error "添加zsh到合法shell列表失败"
	fi

	# 修改原始用户的默认shell
	chsh -s "$(which zsh)" "${ORIGINAL_USER}" || error "修改默认shell失败"
	# 验证修改结果
	if [ "$(su - "${ORIGINAL_USER}" -c 'echo $SHELL')" = "$(which zsh)" ]; then
		info "默认shell已成功修改为zsh，路径：$(which zsh)"
	else
		warn "默认shell修改指令已执行，但验证未通过，可能需要重新登录后生效"
	fi

	info "已经完成安装oh-my-zsh"
}

# 安装Docker
install_docker() {
	info "开始安装Docker..."
	# 卸载旧版本
	apt remove -y docker docker-engine docker.io containerd runc || warn "未检测到旧版本Docker，跳过卸载"

	# 设置Docker仓库
	apt install -y ca-certificates curl gnupg lsb-release

	# 添加Docker官方GPG密钥
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

	# 设置Docker软件源
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

	# 安装Docker引擎
	apt update -y
	apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || error "安装Docker失败"

	# 启动并设置开机自启
	systemctl enable --now docker

	usermod -aG docker "${ORIGINAL_USER}" || warn "添加用户到docker组失败，后续使用docker可能需要sudo"

	info "成功安装Docker，版本信息：$(docker --version)"
}

# 安装 NVIDIA Container Toolkit
install_docker_nvidia() {
	# 添加NVIDIA官方GPG密钥
	curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

	# 添加NVIDIA Container Toolkit软件源
	curl -s -L https://nvidia.github.io/libnvidia-container/ubuntu22.04/libnvidia-container.list |
		sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
		sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

	# 更新源并安装toolkit
	sudo apt-get update
	sudo apt-get install -y nvidia-container-toolkit

	# 配置Docker以识别NVIDIA驱动（关键步骤）
	sudo nvidia-ctk runtime configure --runtime=docker

	# 重启Docker服务使配置生效
	sudo systemctl restart docker

	# 添加当前用户到docker组（避免每次使用docker都要sudo）
	usermod -aG docker "${ORIGINAL_USER}" || warn "添加用户到docker组失败，后续使用docker可能需要sudo"

	info "成功安装Docker-Nvidia"

}

#  zsh通配符配置内容
set_zshrc() {
	info "配置通配符"

	ZSH_GLOB_CONFIG="
# ========== 通配符核心配置 ==========
setopt EXTENDED_GLOB       # 开启扩展通配符（必开！支持 **、^、~ 等高级语法）
setopt GLOB_STAR_SHORT     # 允许 **/ 简化为 **（如 **.txt 等价于 **/*.txt）
setopt NULL_GLOB           # 通配符匹配不到文件时，直接返回空（而非保留原字符串）
setopt NO_NOMATCH          # 匹配不到文件时不报错（兼容脚本场景）
setopt GLOB_DOTS           # 通配符默认匹配隐藏文件（无需手动加 .*）
setopt NUMERIC_GLOB_SORT   # 数字按数值排序（而非字符排序，如 file10 排在 file2 后）
"

	# 定义目标配置文件路径
	ZSHRC_FILE="$HOME/.zshrc"

	# 第一步：检查.zshrc是否存在，不存在则创建
	if [ ! -f "$ZSHRC_FILE" ]; then
		echo "创建~/.zshrc文件..."
		touch "$ZSHRC_FILE"
	fi

	# 第二步：检查配置是否已存在，避免重复写入
	if grep -q "# ========== 通配符核心配置 ==========" "$ZSHRC_FILE"; then
		echo "通配符配置已存在于~/.zshrc，无需重复写入！"
	else
		# 将配置追加到.zshrc末尾
		echo "将通配符配置写入~/.zshrc..."
		echo "$ZSH_GLOB_CONFIG" >>"$ZSHRC_FILE"
		echo "配置写入成功！"
	fi

	# 第三步：使配置立即生效（当前终端）
	echo "正在加载新的Zsh配置..."
	source "$ZSHRC_FILE"

	# 第四步：验证关键配置是否生效
	echo -e "\n验证配置生效状态："
	if [[ -o EXTENDED_GLOB ]]; then
		echo "✅ EXTENDED_GLOB 已开启"
	else
		echo "❌ EXTENDED_GLOB 未开启"
	fi

	if [[ -o NULL_GLOB ]]; then
		echo "✅ NULL_GLOB 已开启"
	else
		echo "❌ NULL_GLOB 未开启"
	fi

	info "\n所有操作完成！新开终端即可生效，或执行 source ~/.zshrc 手动生效。"
}

main() {
	info "===== 开始系统初始化配置 ====="
	check_root_permission
	get_original_user
	get_ubuntu_version

	setup_tsinghua_source
	install_base_tools

	install_docker
	install_docker_nvidia

	install_oh_my_zsh
	set_zshrc

	info "===== 所有配置完成！ ====="
	info "请重新登录以使所有配置生效"
}

main
