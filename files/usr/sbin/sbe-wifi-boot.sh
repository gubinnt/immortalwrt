#!/bin/sh
# SBE1V1K 无线开机就绪（保留用户配置版）
#
# 这台机器的硬伤：
#   三颗 QCN9274 是三个独立 PCIe 设备，ath12k 异步 probe，每次开机
#   radio0/1/2 各自对应哪个频段都可能不同。而 /etc/config/wireless 里的
#   option radio 'N' 是硬编码序号。沿用旧配置时会把 2.4G 的信道设到 6G 的
#   radio 上，hostapd 报 Failed to set beacon parameters，AP 起不来；而且
#   失败后 phy 会卡在半初始化状态，wifi up / down+up 都救不回来，
#   必须重新探测。
#
# 因此本脚本每次开机做两件事：
#   1) 用 wifi config 探测出【本次开机真实的 band ↔ radio 映射】
#   2) 把用户配置原样恢复，只把 option radio 改成探测到的正确序号
#
# 用户改过的任何东西（SSID/密码/信道/带宽/隐藏/访客网络/mesh/限速…）
# 全部原样保留，不重建配置。
#
# MLO（802.11be 多链路）：一个 wifi-iface 可以绑定多个 device（list），
#   运行时只产生一个 ap-mldN 接口，不是每个频段一个。所以：
#     - iface 的 device 必须用 uci show 取全部（uci get 只给第一个）
#     - 健康检查要认得 ap-mldN 这个名字
#   否则「6G 独立 AP 挂了但 MLO 正常」时会误判成少接口，触发 wifi 重启
#   把正在用的 MLO 打断。
#
# 例外：首次开机（无标记文件）时，会把无线设成一组验证过的默认值
# （5G 固定 80MHz，因为 160MHz 会触发 DFS-CAC，ath12k 上 CAC 不会结束）。
# 设置好后写一个标记文件，此后永不再覆盖用户设置。

TAG="sbe-wifi"
LOG() { logger -t "$TAG" "$*"; }

# 首次开机标记必须放在 /etc/config 下，否则 sysupgrade 保留配置升级时它不会被
# 备份，刷完就被当成"首次开机"重新套默认值（表现为 5G 被打回 ch36/EHT80）。
MARK=/etc/config/sbe-wifi-initialized
MARK_OLD=/etc/sbe-wifi-initialized
COUNTRY="US"
USERCFG=/tmp/sbe-wifi-user.conf
MAPFILE=/tmp/sbe-wifi-map.$$

radios() {
	uci show wireless 2>/dev/null | sed -n 's/^wireless\.\(radio[0-9]*\)=wifi-device/\1/p'
}
# 所有 AP 模式的 wifi-iface（含 MLO 的 mlo 接口，也含非 default_radioN 的自定义名）
ifaces() {
	uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface/\1/p'
}
# 取一个 iface 绑定的全部 device，空格分隔。
# 注意：uci show 对 list 只输出一行 wireless.mlo.device='radio0' 'radio2'，
# 用 sed 解析会得到 "radio0' 'radio2" 这样的垃圾；而 uci get 反而会给
# 完整的空格分隔列表，所以这里用 uci get 而不是 uci show。
iface_devices() {
	uci -q get wireless.$1.device 2>/dev/null
}
is_mlo() { [ "$(uci -q get wireless.$1.mlo)" = '1' ]; }

# ---------- 0. 等 phy ----------
n=0
while [ $n -lt 120 ]; do
	[ -n "$(ls /sys/class/ieee80211/ 2>/dev/null)" ] && break
	sleep 1; n=$((n+1))
done
if [ -z "$(ls /sys/class/ieee80211/ 2>/dev/null)" ]; then
	LOG "no phy after 120s, give up"
	exit 0
fi
sleep 6
LOG "phy ready: $(ls /sys/class/ieee80211/ | tr '\n' ' ')"

# ---------- 1. 用户关掉无线就不要动它 ----------
# 只要用户关掉了全部 radio 或全部 AP 接口，本脚本立刻退出，
# 绝不"帮"用户把无线打开（重启后应保持关闭状态）。
ENABLED_RADIO=0
for r in $(radios); do
	[ "$(uci -q get wireless.$r.disabled)" = "1" ] || ENABLED_RADIO=1
done
ENABLED_IFACE=0
for i in $(ifaces); do
	[ "$(uci -q get wireless.$i.mode)" = "ap" ] || continue
	[ "$(uci -q get wireless.$i.disabled)" = "1" ] && continue
	# MLO 绑定多个 radio：只要有一个 radio 没被禁用，这个 iface 就算启用
	for d in $(iface_devices "$i"); do
		[ "$(uci -q get wireless.$d.disabled)" = "1" ] || ENABLED_IFACE=1
	done
done
if [ $ENABLED_RADIO -eq 0 ] || [ $ENABLED_IFACE -eq 0 ]; then
	LOG "wireless disabled by user (radio=$ENABLED_RADIO iface=$ENABLED_IFACE), leave as-is"
	exit 0
fi

# ---------- 2. 备份用户配置，再重新探测拿映射 ----------
[ -f /etc/config/wireless ] && cp -f /etc/config/wireless "$USERCFG"

iw reg set "$COUNTRY" 2>/dev/null
sleep 1
rm -f /etc/config/wireless /tmp/.uci/wireless
wifi config >/dev/null 2>&1
sleep 2

: > "$MAPFILE"
for r in $(radios); do
	b=$(uci -q get wireless.$r.band)
	idx=$(uci -q get wireless.$r.radio)
	phy=$(uci -q get wireless.$r.phy)
	[ -n "$b" ] && echo "$b|$idx|$phy" >> "$MAPFILE"
done
LOG "detected: $(tr '\n' ' ' < "$MAPFILE")"

if [ ! -s "$MAPFILE" ]; then
	LOG "detection failed, restoring user config untouched"
	[ -f "$USERCFG" ] && cp -f "$USERCFG" /etc/config/wireless && rm -f /tmp/.uci/wireless
	rm -f "$MAPFILE"
	exit 0
fi

# ---------- 3. 恢复用户配置 ----------
if [ -f "$USERCFG" ]; then
	cp -f "$USERCFG" /etc/config/wireless
	rm -f /tmp/.uci/wireless
else
	# 没有旧配置（首次开机）：保留刚探测出的这份
	LOG "no previous config, using detected one"
fi

FIRSTBOOT=0
[ -f "$MARK" ] || [ -f "$MARK_OLD" ] || FIRSTBOOT=1
# 旧位置的标记搬到 /etc/config 下，否则下次刷机又会丢
if [ -f "$MARK_OLD" ] && [ ! -f "$MARK" ]; then
	touch "$MARK"
	LOG "migrated first-boot marker to $MARK"
fi

# ---------- 4. 只修 option radio（首次开机额外套默认值） ----------
for r in $(radios); do
	b=$(uci -q get wireless.$r.band)
	[ -z "$b" ] && continue

	line=$(grep "^$b|" "$MAPFILE" 2>/dev/null | head -1)
	idx=$(echo "$line" | cut -d'|' -f2)
	phy=$(echo "$line" | cut -d'|' -f3)

	if [ -z "$idx" ]; then
		# 本次开机探测不到这个频段（例如 country=CN 时没有 6G）
		uci set wireless.$r.disabled='1'
		LOG "  $r band=$b not detected -> disabled"
		continue
	fi

	cur=$(uci -q get wireless.$r.radio)
	[ "$cur" != "$idx" ] && uci set wireless.$r.radio="$idx"
	[ -n "$phy" ] && uci set wireless.$r.phy="$phy"
	uci set wireless.$r.noscan='1'
	[ -z "$(uci -q get wireless.$r.country)" ] && uci set wireless.$r.country="$COUNTRY"

	if [ $FIRSTBOOT = 1 ]; then
		case "$b" in
			6g) uci set wireless.$r.channel='37'; uci set wireless.$r.htmode='EHT160' ;;
			5g) uci set wireless.$r.channel='36'; uci set wireless.$r.htmode='EHT80' ;;
			*)  uci set wireless.$r.channel='1';  uci set wireless.$r.htmode='EHT20' ;;
		esac
	fi

	LOG "  $r band=$b radio=$idx phy=${phy:-?} ch=$(uci -q get wireless.$r.channel) ht=$(uci -q get wireless.$r.htmode) keep=$((1-FIRSTBOOT))"
done

# 首次开机顺手确保每个 AP 都有一个启用的接口
# （MLO 的 iface 绑多个 radio，对应每个 radio 都算"已覆盖"）
if [ $FIRSTBOOT = 1 ]; then
	for r in $(radios); do
		[ "$(uci -q get wireless.$r.disabled)" = "1" ] && continue
		found=0
		for i in $(ifaces); do
			[ "$(uci -q get wireless.$i.mode)" = "ap" ] || continue
			for d in $(iface_devices "$i"); do
				[ "$d" = "$r" ] && found=1
			done
		done
		if [ $found = 0 ]; then
			uci set wireless.default_$r=wifi-iface
			uci set wireless.default_$r.device="$r"
			uci set wireless.default_$r.network='lan'
			uci set wireless.default_$r.mode='ap'
			uci set wireless.default_$r.ssid="OWRT-$r"
		fi
	done
	touch "$MARK"
	LOG "first boot defaults applied, marker written"
fi

uci commit wireless
rm -f "$MAPFILE"

# ---------- 5. 启动 + 校验 ----------
wifi down >/dev/null 2>&1
sleep 3
wifi up >/dev/null 2>&1
sleep 25

# 运行时 AP 接口名：单链路是 <phy>-ap0，MLO 是 ap-mldN
up_ifaces() {
	ls /sys/class/net/ 2>/dev/null | grep -E 'ap0$|^ap-mld'
}

check() {
	# 只统计"用户启用的 AP 接口"，被禁用的不算失败
	want=0
	for i in $(ifaces); do
		[ "$(uci -q get wireless.$i.mode)" = "ap" ] || continue
		[ "$(uci -q get wireless.$i.disabled)" = "1" ] && continue
		if is_mlo "$i"; then
			# MLO 运行时只产生一个 ap-mldN，不按频段数计数
			any=0
			for d in $(iface_devices "$i"); do
				[ "$(uci -q get wireless.$d.disabled)" = "1" ] || any=1
			done
			[ $any = 1 ] && want=$((want + 1))
			continue
		fi
		d=$(uci -q get wireless.$i.device)
		[ "$(uci -q get wireless.$d.disabled)" = "1" ] && continue
		[ -z "$(uci -q get wireless.$d.band)" ] && continue
		want=$((want + 1))
	done
	up=0
	for n in $(up_ifaces); do
		[ "$(cat /sys/class/net/$n/operstate 2>/dev/null)" = "up" ] && up=$((up + 1))
	done
	echo $((want - up))
}

k=0
while [ $k -lt 6 ]; do
	bad=$(check)
	if [ "$bad" -le 0 ]; then
		LOG "all AP up: $(up_ifaces | tr '\n' ' ')"
		exit 0
	fi
	sleep 10
	k=$((k + 1))
done

retry=1
while [ $retry -le 2 ]; do
	LOG "retry $retry: $bad interface(s) short, restarting wifi"
	wifi down >/dev/null 2>&1
	sleep 4
	wifi up >/dev/null 2>&1
	sleep 25
	bad=$(check)
	if [ "$bad" -le 0 ]; then
		LOG "recovered on retry $retry"
		exit 0
	fi
	retry=$((retry + 1))
done

LOG "finished with $bad interface(s) still down"
