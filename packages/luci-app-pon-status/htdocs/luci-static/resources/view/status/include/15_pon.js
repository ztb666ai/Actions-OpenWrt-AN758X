// SPDX-License-Identifier: Apache-2.0
//
// PON 光模块状态卡片 —— 位于概览页「系统」的下一格
//
// 位置原理：luci-mod-status 的 index.js 会
//   fs.list('/www/luci-static/resources/view/status/include')
// 取所有 .js 后按文件名 .sort() 排序，顺序即概览页卡片顺序。
// 官方顺序：10_system → 20_memory → 25_storage → 29_ports
//          → 30_network → 40_dhcp → 50_dsl → 60_wifi
// 本文件命名为 15_pon.js，正好落在 10_system 之后、20_memory 之前，
// 即「系统」卡片的下一格。
//
// 数据来源：ponctl --device <dev> status --json
//   airoha-ponctl 的 convert_optics() 已完成 SFF-8472 → 显示单位换算，
//   这里只做取值与格式化，不自行换算：
//     temperature_celsius (°C) / rx_power_dbm (dBm) / tx_power_dbm (dBm)
//     tx_bias_ma (mA)          / voltage_volts (V)

'use strict';
'require baseclass';
'require fs';
'require uci';

function readFrontend(device) {
	var args = (device != null && device !== '')
		? [ '--device', device, 'status', '--json' ]
		: [ 'status', '--json' ];

	return L.resolveDefault(fs.exec_direct('/usr/sbin/ponctl', args), null).then(function(output) {
		if (!output)
			return { error: _('读取失败（设备不可用）') };

		try {
			var snapshot = JSON.parse(output);
			if (snapshot.schema_version !== 1)
				throw new Error('unsupported schema');
			return L.isObject(snapshot.frontend) ? snapshot.frontend : {};
		} catch (e) {
			return { error: _('解析失败') };
		}
	});
}

function metric(frontend, field, unit, digits) {
	if (frontend.error)
		return frontend.error;
	if (!Object.prototype.hasOwnProperty.call(frontend, field))
		return _('不支持');
	return Number(frontend[field]).toFixed(digits) + ' ' + unit;
}

function renderBox(item) {
	var frontend = item.frontend || {};

	return E('div', { 'class': 'ifacebox' }, [
		E('div', { 'class': 'ifacebox-head center active' },
			E('strong', item.device)),
		E('div', { 'class': 'ifacebox-body left' },
			L.itemlist(E('span'), [
				_('收光功率'), metric(frontend, 'rx_power_dbm', 'dBm', 2),
				_('发光功率'), metric(frontend, 'tx_power_dbm', 'dBm', 2),
				_('光模块温度'), metric(frontend, 'temperature_celsius', '°C', 2),
				_('偏置电流'), metric(frontend, 'tx_bias_ma', 'mA', 2),
				_('供电电压'), metric(frontend, 'voltage_volts', 'V', 4)
			]))
	]);
}

return baseclass.extend({
	title: _('PON 光模块'),

	load: function() {
		return uci.load('pon').then(function() {
			var sections = uci.sections('pon', 'xpon').filter(function(section) {
				return section.device;
			});

			if (!sections.length)
				return Promise.reject();

			return Promise.all(sections.map(function(section) {
				return readFrontend(section.device).then(function(frontend) {
					return {
						device: section.device,
						frontend: frontend
					};
				});
			}));
		});
	},

	render: function(data) {
		if (!data || !data.length)
			return null;

		return E('div', { 'id': 'pon_optics_table', 'class': 'network-status-table' },
			data.map(renderBox));
	}
});
