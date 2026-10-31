'use strict';
'require view';
'require fs';
'require ui';
'require poll';

return view.extend({
	handleSwitch: function(mode) {
		var label = (mode === 'ap') ? 'AP' : '路由';

		if (!confirm('确定切换到「' + label + '模式」？\n\n网络会重启，当前网页/SSH 连接可能中断，属正常现象。'))
			return;

		ui.showModal('切换中…', [
			E('p', { 'class': 'spinning' }, '正在切换网络模式，请稍候…')
		]);

		return fs.exec('/usr/sbin/netmode', [ mode ]).then(function(res) {
			ui.hideModal();

			if (res.code !== 0) {
				ui.addNotification(null,
					E('p', {}, '切换失败：' + (res.stderr || res.stdout || ('exit ' + res.code))),
					'danger');
			} else {
				ui.addNotification(null,
					E('p', {}, '已切换到「' + label + '模式」，网络正在重启。'),
					'info');
				window.setTimeout(function() { location.reload(); }, 4000);
			}
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, '执行失败：' + e.message), 'danger');
		});
	},

	render: function() {
		var statusBox = E('pre', {
			'id': 'netmode-status',
			'style': 'background:var(--background-color-medium,#f5f5f5);' +
				'padding:14px;border-radius:6px;font-size:13px;' +
				'line-height:1.7;white-space:pre-wrap;margin:0;'
		}, '读取中…');

		var refresh = function() {
			return fs.exec('/usr/sbin/netmode', [ 'status' ]).then(function(res) {
				statusBox.textContent = (res.stdout || res.stderr || '—').trim();
			}).catch(function(e) {
				statusBox.textContent = '读取失败：' + e.message;
			});
		};

		poll.add(refresh, 5);
		refresh();

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, '运行模式'),
			E('div', { 'class': 'cbi-map-descr' },
				'切换设备的工作模式。路由模式：WAN 独立（DHCP/PPPoE），LAN 固定 192.168.2.1 并开启 DHCP；' +
				'AP 模式：WAN 口并入 LAN 桥（10G 口当普通网口用），设备从上级路由获取地址并关闭 DHCP。'),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '当前状态'),
				statusBox
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '切换模式'),
				E('div', { 'class': 'cbi-section-descr' },
					'切换会自动备份 /etc/config/network 与 dhcp 到 /etc/config/ 下。'),
				E('div', { 'style': 'margin-top:12px;' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, 'handleSwitch', 'router')
					}, '切换为路由模式'),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-reset',
						'click': ui.createHandlerFn(this, 'handleSwitch', 'ap')
					}, '切换为 AP 模式')
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
