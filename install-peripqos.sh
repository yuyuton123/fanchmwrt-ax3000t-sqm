#!/bin/sh
# ============================================================
# 一键安装「网络 → 设备限速」LuCI 页面
# 适用：FanchmWrt / OpenWrt 25.x（Lua 版 LuCI）
# 用法：sh install-peripqos.sh
# 卸载：sh install-peripqos.sh uninstall
# ============================================================

BASE=/usr/lib/lua/luci

if [ "$1" = "uninstall" ]; then
    /etc/init.d/peripqos stop 2>/dev/null
    /etc/init.d/peripqos disable 2>/dev/null
    rm -f /etc/init.d/peripqos
    rm -f $BASE/controller/peripqos.lua
    rm -f $BASE/model/cbi/peripqos.lua
    sh /etc/qos-per-ip.sh clean 2>/dev/null
    rm -f /etc/qos-per-ip.sh
    echo "已卸载。配置保留在 /etc/config/peripqos（不需要可手动删除）"
    exit 0
fi

if [ ! -d "$BASE/controller" ]; then
    echo "错误：本机 LuCI 不是 Lua 版，无法安装此页面。"
    echo "路径检查：$BASE/controller 不存在"
    exit 1
fi

# ---------- 1. uci 配置文件 ----------
cat > /etc/config/peripqos <<'CFGEOF'
config global 'global'
	option enabled '1'
	option total_down '100'
	option total_up '30'

config rule 'dev1'
	option ip '192.168.1.20'
	option down '20'
	option up '8'
CFGEOF

# ---------- 2. 限速执行脚本 ----------
cat > /etc/qos-per-ip.sh <<'RUNEOF'
#!/bin/sh
# 读取 /etc/config/peripqos 并下发 tc 规则
wan_dev() {
	d=$(jsonfilter -s "$(ubus call network.interface.wan status 2>/dev/null)" -e '@["l3_device"]' 2>/dev/null)
	[ -z "$d" ] && d=$(uci get network.wan.device 2>/dev/null)
	[ -z "$d" ] && d="wan"
	echo "$d"
}

WAN=$(wan_dev)

clean() {
	tc qdisc del dev "$WAN" root 2>/dev/null
	tc qdisc del dev "$WAN" ingress 2>/dev/null
	tc qdisc del dev ifb0 root 2>/dev/null
	ip link set ifb0 down 2>/dev/null
	ip link del ifb0 2>/dev/null
	return 0
}

if [ "$1" = "clean" ]; then
	clean
	exit 0
fi

[ "$(uci -q get peripqos.global.enabled)" = "1" ] || { clean; exit 0; }

TD=$(uci -q get peripqos.global.total_down)
TU=$(uci -q get peripqos.global.total_up)
[ -z "$TD" ] && TD=100
[ -z "$TU" ] && TU=30
TD=$((TD * 1000))
TU=$((TU * 1000))

clean

ip link add ifb0 type ifb 2>/dev/null
ip link set ifb0 up

tc qdisc add dev "$WAN" root handle 1: htb default 99 r2q 10 || exit 1
tc class add dev "$WAN" parent 1: classid 1:1 htb rate ${TU}kbit ceil ${TU}kbit
tc class add dev "$WAN" parent 1:1 classid 1:99 htb rate 1000kbit ceil ${TU}kbit
tc qdisc add dev "$WAN" parent 1:99 fq_codel

tc qdisc add dev "$WAN" handle ffff: ingress
tc filter add dev "$WAN" parent ffff: protocol all prio 1 u32 match u32 0 0 \
	action mirred egress redirect dev ifb0

tc qdisc add dev ifb0 root handle 2: htb default 99 r2q 10
tc class add dev ifb0 parent 2: classid 2:1 htb rate ${TD}kbit ceil ${TD}kbit
tc class add dev ifb0 parent 2:1 classid 2:99 htb rate 1000kbit ceil ${TD}kbit
tc qdisc add dev ifb0 parent 2:99 fq_codel

CID=10
N=0

for SECT in $(uci -q foreach peripqos rule); do
	IP=$(uci -q get peripqos.$SECT.ip)
	D=$(uci -q get peripqos.$SECT.down)
	U=$(uci -q get peripqos.$SECT.up)
	[ -z "$IP" ] && continue
	[ -z "$D" ] && D=$TD
	[ -z "$U" ] && U=$TU
	D=$((D * 1000))
	U=$((U * 1000))

	tc class add dev "$WAN" parent 1:1 classid 1:$CID htb rate ${U}kbit ceil ${U}kbit
	tc qdisc add dev "$WAN" parent 1:$CID fq_codel
	tc filter add dev "$WAN" parent 1: protocol ip prio 2 u32 match ip src "$IP" flowid 1:$CID

	tc class add dev ifb0 parent 2:1 classid 2:$CID htb rate ${D}kbit ceil ${D}kbit
	tc qdisc add dev ifb0 parent 2:$CID fq_codel
	tc filter add dev ifb0 parent 2: protocol ip prio 2 u32 match ip dst "$IP" flowid 2:$CID

	echo "$IP down=${D}kbit up=${U}kbit"
	CID=$((CID + 1))
	N=$((N + 1))
done

echo "applied $N rules on $WAN"
RUNEOF

# ---------- 3. LuCI 控制器 ----------
mkdir -p $BASE/controller $BASE/model/cbi

cat > $BASE/controller/peripqos.lua <<'CTLEOF'
module("luci.controller.peripqos", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/peripqos") then
		return
	end
	entry({"admin", "network", "peripqos"}, cbi("peripqos"), "设备限速", 60).dependent = false
end
CTLEOF

# ---------- 4. CBI 表单 ----------
cat > $BASE/model/cbi/peripqos.lua <<'CBIEOF'
local i18n = require "luci.i18n"
local t = i18n.translate
local m, s, o

m = Map("peripqos", t("设备限速"),
	t("按 IP 分别限制上下行带宽。填写 Mbps，保存后立即下发到 tc。需先把设备 IP 通过 DHCP 静态租约固定。"))

function m.on_after_commit(self)
	luci.sys.call("/etc/qos-per-ip.sh > /tmp/peripqos.log 2>&1")
end

s = m:section(NamedSection, "global", "global", t("全局设置"))
s.addremove = false

o = s:option(Flag, "enabled", t("启用限速"))
o.rmempty = false

o = s:option(Value, "total_down", t("总下行带宽 (Mbps)"))
o.datatype = "uinteger"

o = s:option(Value, "total_up", t("总上行带宽 (Mbps)"))
o.datatype = "uinteger"

s = m:section(TypedSection, "rule", t("设备规则"))
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"

o = s:option(Value, "ip", t("IP 地址"))
o.datatype = "ip4addr"
o.placeholder = "192.168.1.20"

o = s:option(Value, "down", t("下行上限 (Mbps)"))
o.datatype = "uinteger"
o.placeholder = "20"

o = s:option(Value, "up", t("上行上限 (Mbps)"))
o.datatype = "uinteger"
o.placeholder = "8"

return m
CBIEOF

# ---------- 5. 开机自启 ----------
cat > /etc/init.d/peripqos <<'INITEOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
start() {
	/etc/qos-per-ip.sh > /dev/null 2>&1
}
stop() {
	/etc/qos-per-ip.sh clean > /dev/null 2>&1
}
INITEOF

chmod +x /etc/qos-per-ip.sh /etc/init.d/peripqos
/etc/init.d/peripqos enable
rm -f /tmp/luci-indexcache* 2>/dev/null
/etc/init.d/rpcd restart 2>/dev/null
/etc/init.d/uhttpd restart 2>/dev/null
/etc/qos-per-ip.sh

echo ""
echo "安装完成。"
echo "打开 LuCI：网络 → 设备限速"
echo "  1) 填总上行/总下行（Mbps，实测的 90%）"
echo "  2) 逐台添加 IP + 下行/上行上限（Mbps）"
echo "  3) 点保存并应用，规则立即生效"
echo ""
echo "建议同时在 SQM 里关闭 WAN 整形，避免抢占同一个队列。"
echo ""
echo "检查下发结果：cat /tmp/peripqos.log"
