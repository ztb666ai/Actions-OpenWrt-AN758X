// SPDX-License-Identifier: Apache-2.0
//
// NAT 类型选择页 —— 网络 → NAT 类型
//
// 菜单声明：root/usr/share/luci/menu.d/luci-app-natmode.json
//   "admin/network/natmode" → action.path "natmode/mode"
//   → 对应 resources/view/natmode/mode.js（本文件）
//
// 三档说明见 /usr/sbin/natmode-apply 顶部注释。
// 保存后通过 fs.exec 调用 natmode-apply apply 真正生效（ACL 已授权）。

'use strict';
'require view';
'require form';
'require fs';
'require ui';

function parseStatus(text) {
	var st = { mode: '?', effective: '?', fullcone: '0',
	           random_rules: '0', offload: 'off', module: '?' };
	(text || '').split('\n').forEach(function(line) {
		var kv = line.split('=');
		if (kv.length >= 2)
			st[kv[0].trim()] = kv.slice(1).join('=').trim();
	});
	return st;
}

function modeLabel(m) {
	switch (m) {
		case 'fullcone':   return _('全锥形NAT') + '（NAT1）';
		case 'restricted': return _('受限型NAT') + '（NAT3）';
		case 'symmetric':  return _('全对称型NAT') + '（NAT4）';
		default:           return m;
	}
}

function offloadLabel(v) {
	switch (v) {
		case 'hw':  return _('硬件卸载');
		case 'sw':  return _('软件卸载');
		default:    return _('关闭');
	}
}

function renderStatus(st) {
	var rows = [
		_('本页设置'),        modeLabel(st.mode),
		_('实际生效'),        modeLabel(st.effective),
		_('FullCone 开关'),   (st.fullcone === '1' ? _('已启用') : _('已关闭')),
		_('随机端口规则'),    (st.random_rules !== '0'
			? _('已注入 ') + st.random_rules + _(' 条') : _('无')),
		_('路由/NAT 卸载'),   offloadLabel(st.offload),
		_('fullcone 内核模块'), (st.module === 'loaded' ? _('已加载') : _('未加载'))
	];

	var warn = [];

	// 与防火墙页面的 FullCone 开关不一致：
	// 网络 → 防火墙 → 常规设置 里的「启用 FullCone NAT」写的就是
	// firewall.@defaults[0].fullcone，与本插件同一个 UCI 键。
	// 在那边直接改不会同步本页的 natmode.main.mode。
	if (st.mode !== st.effective)
		warn.push(E('p', {}, _('本页设置与实际生效不一致：可能已在「网络 → 防火墙 → 常规设置」'
			+ '直接改动过 FullCone 开关。请在本页重新选择并保存以同步。')));

	if (st.module !== 'loaded' && st.effective === 'fullcone')
		warn.push(E('p', {}, _('未检测到 nft_fullcone 模块，全锥形可能不生效。')));

	if (st.offload !== 'off' && st.effective !== 'restricted')
		warn.push(E('p', {}, _('已开启路由/NAT 卸载，卸载流量会绕过 conntrack，'
			+ '可能使全锥形或随机端口行为不稳定。建议测 NAT 类型时临时关闭卸载。')));

	var table = E('table', { 'class': 'table' });
	for (var i = 0; i < rows.length; i += 2) {
		table.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '33%' }, [ rows[i] ]),
			E('td', { 'class': 'td left' }, [ rows[i + 1] || '?' ])
		]));
	}

	var children = [ E('h3', _('当前状态')), table ];
	warn.forEach(function(w) {
		children.push(E('div', { 'class': 'alert-message warning' }, [ w ]));
	});

	return E('div', { 'class': 'cbi-section' }, children);
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.exec_direct('/usr/sbin/natmode-apply', ['status']), '');
	},

	render: function(statusText) {
		var st = parseStatus(statusText);

		// =========================================================
		// 必须用 form.Map，不能用 form.JSONMap！
		//
		// form.js 中 CBIJSONMap 的实现：
		//   __init__(data, ...) { this.config='json';
		//                        this.data = new CBIJSONConfig(data); }
		// 它把第一个参数当作「JSON 数据对象」而非文件名，
		// 且 parsechain=['json'] —— 用于 JSON 配置文件（如 luci 的
		// 某些 js 配置），不是 UCI。
		// /etc/config/natmode 是标准 UCI 文件，必须用 form.Map，
		// 否则解析失败、保存也写不回去。
		// =========================================================
		var m = new form.Map('natmode', _('NAT 类型'),
			_('选择路由器对内网出向连接的 NAT 行为。数字越小越宽松，P2P / 游戏 / PT 体验越好。'));

		var s = m.section(form.NamedSection, 'main', 'natmode');
		s.anonymous = false;

		var o = s.option(form.RadioValue, 'mode', _('NAT 类型'));
		o.orientation = 'vertical';
		o.value('fullcone',
			_('全锥形NAT') + '（NAT1）— ' +
			_('最宽松，端点无关映射 + 端点无关过滤。游戏联机、PT 做种、PCDN 最优。'));
		o.value('restricted',
			_('受限型NAT') + '（NAT3）— ' +
			_('系统默认。端点无关映射 + 地址端口相关过滤，日常上网无影响。'));
		o.value('symmetric',
			_('全对称型NAT') + '（NAT4）— ' +
			_('端口完全随机，映射不可预测，打洞基本不可用。仅用于特殊合规场景。'));
		o.default = 'fullcone';

		// 保存后真正应用（改 firewall 配置 + 重载 fw4 + 注入随机端口规则）
		m.handleSaveApply = function(ev) {
			var self = this;
			return self.handleSave(ev).then(function() {
				return fs.exec('/usr/sbin/natmode-apply', ['apply']);
			}).then(function() {
				return ui.changes.apply();
			}).then(function() {
				ui.addNotification(null,
					E('p', _('NAT 模式已应用，防火墙已重载。')), 'success');
				window.setTimeout(function() { window.location.reload(); }, 1500);
			}).catch(function(e) {
				ui.addNotification(null,
					E('p', _('应用失败：') + (e && e.message ? e.message : e)), 'error');
			});
		};

		return E('div', {}, [ renderStatus(st), m.render() ]);
	}
});
