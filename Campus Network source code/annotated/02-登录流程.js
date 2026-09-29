/* ============================================================================
 * 02-登录流程.js —— 登录请求构造 与 响应处理 解读版
 * ----------------------------------------------------------------------------
 * 覆盖来源：
 *   a40.js  第 2151-2189 行  login.default_login   —— 旧式表单登录（构 data 后交给 portal_login）
 *   a40.js  第 2190-2316 行  login.portal_login    —— 统一的登录发送与成功/失败处理
 *   a40.js  第 3771-3824 行  login.login           —— 按 login_method 分发到不同认证方式
 *   a40.js  第 3825-3846 行  login.login_portal    —— ★本项目走这条（真值参数字面量）
 *   a40.js  第 3866-3879 行  login.login_ruckus_nbi（case 12）
 *   a40.js  第 3941-3972 行  login.login_meru（case 13）/ login.login_wifidog（case 14）
 *   a41.js  第 606-627 行    term.checkStatus 的 online_list
 *   a41.js  第 1063 / 2360-2471 / 2478-2549 行  util.increment / util._jsonp(callback 生成、回显、错误处理)
 *
 * 本项目对应实现：CampusNet.Common.ps1 的 New-DrappallLoginUrl / Send-CampusLoginRequest /
 *                 ConvertFrom-PortalResponse
 * ========================================================================== */


/* ============================================================================
 * 【片段 A】callback 计数器 —— dr1001 / dr1002 / dr1003 是怎么来的
 * 来源：a41.js 第 1059-1065 行（util.num 与 util.increment）+ 第 2426 / 2478-2484 行
 * ----------------------------------------------------------------------------
 * 机制：util 对象上有个 num 计数器，初始 1000；每次发 JSONP 请求就 ++num，
 *       用 'dr' + 该数字 当 callback 名，并作为一个参数发给后端；
 *       后端把响应包成 `dr1003({...})` 形式，浏览器执行后就会调用同名回调 → "回显"。
 * 所以 dr1003 不是常量，而是"本次页面加载里第 3 次 JSONP 调用"的意思。
 * ========================================================================== */
var util = {
  num: 1000,                         // 计数器初值（来源 a41.js 1060 行）

  // 自增，用于 JSONP 请求回调函数（来源 a41.js 1063-1065 行）
  increment: function () {
    return ++this.num;               // 先自增再返回：第一次返回 1001 → 'dr1001'
  }
};

// —— 在 util._jsonp 里用 increment() 生成 callbackName（来源 a41.js 2426 行）——
var callbackName = 'dr' + me.increment(); // 例如 'dr1003'

// —— 回显：把整个响应体当参数传给 window[callbackName]（来源 a41.js 2478-2484 行）——
// 后端会把 JSON 包成 `dr1003({...})`；script 加载执行时命中这个函数，json 就是响应对象。
window[callbackName] = function (json) {
  requestCompleted = true;
  head.removeChild(script);              // 移除 <script> 标签
  clearTimeout(script.timer);            // 清掉超时定时器
  window[callbackName] = null;           // 释放回调，避免内存泄漏
  params.success && params.success(json, '', (params.complete && params.complete()));
};

/* 本次抓包的真实 callback 序列（来自 当时的抓包（已按隐私要求移除））：
 *   第 1 次：loadConfig  → callback=dr1001   （loadConfig 不加密，callback 是明文）
 *   第 2 次：online_list → callback=445211101012  ← 解 XOR 0x20 = "dr1002"
 *   第 3 次：login       → callback=445211101013  ← 解 XOR 0x20 = "dr1003"
 * 注意：只有 loadConfig 是明文 callback；后两个因为走了加密分支，callback 值也被 XOR 了。
 * 这就是本项目 New-DrappallLoginUrl 里 -Callback 默认 'dr1003'、
 *        New-DrappallLoadConfigUrl 里 -Callback 默认 'dr1001' 的由来。
 */


/* ============================================================================
 * 【片段 B】login.default_login —— 旧式（login_method=0）登录
 * 来源：a40.js 第 2151-2189 行
 * ----------------------------------------------------------------------------
 * 场景：门户配置成"本地/旧接口"（page.login_method=0）时走这条。它同时准备了两套参数：
 *   - 旧的表单字段：DDDDD（账号）、upass（密码）、0MKKey、R1/R2/R3/R6/R7、para、v6ip
 *   - 新的 portal 协议字段：user_account / user_password / wlan_user_ip / ... （跟抓包同源）
 * 然后统一丢给 this.portal_login(data, success, fail) 去发。
 * 本项目**不走**这条（本校园网是 login_method=1 的哆点 v4），列出仅为看清字段来源。
 * ========================================================================== */
login.default_login = function (success, fail) {
  page.login_method = 0;
  var f0 = document.f0;                 // 旧式页面里的 <form name="f0">
  var upass = this.form.upass.value;    // 密码输入框的值

  if (page.en_md5) {                    // 若门户要求 MD5 挑战认证：
    upass = calcMD5(PID + upass + CALG) + CALG + PID; // 用 PID/CALG 拼挑战串再 MD5
  }
  // 账号/密码里的空白字符全部剔除（前后端对齐，避免空格被当成密码一部分）
  if (this.account.includes(" ")) this.account = this.account.replace(/\s+/g, '');
  if (upass.includes(" ")) upass = upass.replace(/\s+/g, '');

  var data = {
    'DDDDD' : this.account,             // 旧接口账号字段
    'upass' : upass,                    // 旧接口密码字段（可能已被 MD5 处理）
    '0MKKey': 123456,                   // 旧接口固定串（"已提交"标记）
    R1 : f0.R1 ? f0.R1.value : '',
    R2 : page.en_md5 ? 1 : '',          // 是否 MD5
    R3 : f0.R3 ? f0.R3.value : '',
    R6 : (term.type == 2 || (term.ipad_terminal_identity == 1 && (term.type == 3 || term.type == 4))) ? 1 : 0,
    para: f0.para ? f0.para.value : '',
    v6ip: f0.v6ip ? f0.v6ip.value : ''
  };
  var ioModeEle = $('[name="checkIOMode"]')[0];
  if (ioModeEle) data.R10 = ioModeEle.checked ? 1 : 0; // 内外网方式
  data.R7 = term.customPerceive;

  // —— 下面是"新 portal 协议"字段，与抓包 login 请求对应的部分 ——
  data.user_account   = this.prefixAccount;         // 带前缀/后缀的账号
  data.user_password  = this.form.upass.value;      // ★ 登录密码就在这行取（未做 MD5 的原始值）
  data.wlan_user_ip   = term.ip;                    // 客户端 IP
  data.wlan_user_ipv6 = f0.v6ip ? f0.v6ip.value : '';
  data.authex_enable  = f0.R3 ? f0.R3.value : '';
  data.wlan_user_mac  = term.mac;                   // 客户端 MAC
  data.wlan_ac_name   = term.wlanacname;
  data.jsVersion      = jsVersion;

  this.portal_login(data, success, fail);           // 交给统一入口发送
};


/* ============================================================================
 * 【片段 C】login.portal_login —— 统一发送 + 成功/失败处理（核心）
 * 来源：a40.js 第 2190-2316 行
 * ----------------------------------------------------------------------------
 * 干什么：
 *   1) 补齐一批"运行时才确定"的字段（terminal_type / lang / user_agent / enable_r3 /
 *      mac_type / rcn / operate / business_type）；
 *   2) 决定真实 url：login_method==0 走旧路径 page.path+'login'，
 *      否则走 page.portal_api+'login'（就是 :803/eportal/portal/login）；
 *   3) 用 util._jsonp 发出去（_jsonp 内部会做 XOR 混淆，见 01 解读）；
 *   4) 看响应 json.result：==1 或 'ok' 视为协议成功，否则按各种失败形态处理。
 * ========================================================================== */
login.portal_login = function (data, success, fail) {
  if (typeof (jsVersion) == 'undefined') {           // 页面 js 还没加载完（jsVersion 在 a40.js 末尾才赋值）
    _alert(lang('请等待页面完全加载完成，或刷新页面后重新登录！'));
    if ($('input[name=0MKKey]')[0]) $('input[name=0MKKey]').attr('disabled', false);
    return false;
  }
  layer.msg(lang('正在登录...'));                    // UI：正在登录提示

  // —— 补齐运行时字段（抓包实测这些值：terminal_type=1 lang=zh-cn enable_r3=0 mac_type=0 ...）——
  data.terminal_type = term.type;                    // 终端类型（1=PC）
  data.lang          = language.lang.toLowerCase();  // 语言，如 'zh-cn'
  data.user_agent    = navigator.userAgent;          // 浏览器 UA（会被 XOR 后整串发出去）
  data.enable_r3     = page.enable_r3;               // 串接 pppoe 代拨
  data.authex_enable = term.authex_enable;
  data.mac_type      = (term.type == 2 || (term.ipad_terminal_identity == 1 && (term.type == 3 || term.type == 4))) ? 1 : 0;
  data.rcn           = term.rcn;                     // apg 页面随机数

  if (page.login_method != 0 && apg_switch == '1') { // 仅 apg 开启时才有下面这几个参数
    data.login_t   = (term.type == 2 || (term.ipad_terminal_identity == 1 && (term.type == 3 || term.type == 4))) ? '4' : apg.login_t;
    data.js_status = apg.js_status;
    data.is_page   = '1';
    data.is_page_new = Math.floor(Math.random() * 10000 + 500);
  }

  data.operate       = "portal_login";               // ★ 关键标志位：告诉后端"这是登录"（线上会被 XOR 成 504f...）
  data.business_type = term.business_type;           // 业务类型（抓包=1）
  apg.sendUa();                                       // 上报 UA（apg 用；本校园网 apg 关闭时基本无感）

  this.data = data;                                   // 存一份，供别处复用
  // ★ 决定真实 URL：login_method==0 → 旧 drcom 路径；否则 → eportal/portal/login
  var url = (page.login_method == 0 ? page.path : page.portal_api) + 'login';

  util._jsonp({
    url: url,
    data: data,
    success: function (json) {
      if (json.result == 1 || json.result == 'ok') {   // ← 协议层成功判据（对抓包的 {"result":1,...}）
        if (success) {
          if ($('input[name=0MKKey]')[0]) $('input[name=0MKKey]').attr('disabled', false);
          success(json);
        } else if (term.redirectLogout == 1) {         // 配了"强制跳转注销页"
          page.kind = term.type == 1 ? 'pc_1' : util.switchPageKind(term.type) + '_31';
          page.render();
        } else {
          if (typeof (json.UL) != 'undefined') window.UL = json.UL; // 后端可能回一个跳转地址
          if (page.login_method == 14 && typeof (json.auth_url) != 'undefined') {
            window.location.href = json.auth_url;      // wifidog 特有
            return false;
          }
          var m = window.m || 0, UL = window.UL || '';
          if (!login.redirect(m, UL)) {                // 不该跳转 → 1 秒后渲染成功页
            setTimeout(function () {
              page.kind = term.type == 1 ? 'pc_3' : util.switchPageKind(term.type) + '_33';
              page.render();
            }, 1000);
          }
        }
      } else {
        // —— 失败分支：按后端返回的不同字段走不同提示/页面 ——
        if (fail) {
          if ($('input[name=0MKKey]')[0]) $('input[name=0MKKey]').attr('disabled', false);
          fail(json);
        } else if (typeof (json.self_auth_url) != 'undefined' && json.self_auth_url != '') {
          // 提示去自助服务改密/跳转
          layer.alert(json.msg, { btn: [lang('确定')], yes: function (index) {
            if (term.changePassMode == 0) { page.kind = term.type == 1 ? 'pc_29' : util.switchPageKind(term.type) + '_29'; page.render(); }
            else { window.location.href = json.self_auth_url; }
            layer.close(index);
          }});
          return false;
        } else if (typeof (json.self_auth_url2) != 'undefined' && json.self_auth_url2 != '') {
          layer.alert(json.msg, { btn: [lang('确定')], yes: function (index) {
            window.location.href = json.self_auth_url2; layer.close(index);
          }});
          return false;
        } else if (typeof (json.apg_data) != 'undefined') {
          apg.loginPolicyIntercept(json.apg_data);     // apg 策略拦截
          return false;
        } else if (typeof (json.over_mac_list) != 'undefined' && json.over_mac_list.length > 0) {
          loginverify.show_unbind_box(json.over_mac_list); // 超 MAC 上限，弹解绑框
          return false;
        } else if (page.login_method == 1 && typeof (term.auth_failed_prompt) != 'undefined') {
          layer.alert(json.msg, { btn: [lang('确定')], yes: function (index) { layer.close(index); } });
          return false;                                // 弹窗展示具体错误（如 "密码错误"）
        } else {
          // 兜底：渲染失败页 + 展示错误文案
          page.kind = term.type == 1 ? 'pc_2' : util.switchPageKind(term.type) + '_32';
          page.render(function () {
            if (page.login_method == 0) error.localErr = json;   // 旧接口 → 本地错误结构
            else error.portalErr = json;                          // 新接口 → portal 错误结构
            error.showMsg();
          });
        }
      }
    },
    error: function (error) {                          // 网络/JSONP 层失败
      _alert(lang('认证方法调用出现异常，请刷新页面重试！'));
      if ($('input[name=0MKKey]')[0]) $('input[name=0MKKey]').attr('disabled', false);
    }
  });
};

/* 失败码 → 文案 的映射在本项目之外也有对应（a40.js 1560-1604 行 error.portal_login_err）：
 *   ret_code 1/4 → 账号密码类（msg 非空则用 msg）
 *   ret_code 2   → 终端IP已经在线
 *   ret_code 8   → Radius认证超时（本项目 README 记为 IP/MAC 不匹配，以抓包为准）
 * 本项目对应实现：ConvertFrom-PortalResponse 以 result 为主、ret_code 为辅，
 *   并【只信真实联网】，不把 result:1 当"能上网"。
 */


/* ============================================================================
 * 【片段 D】login.login —— 按 login_method 分发到不同认证方式
 * 来源：a40.js 第 3771-3824 行
 * ----------------------------------------------------------------------------
 * 门户用 page.login_method 区分对接的 AC 厂商/协议。每种方式构造 data 后，
 * 大多最终收敛到同一个 login.portal_login（=同一个 :803/eportal/portal/login 接口）。
 * ========================================================================== */
login.login = function (success, fail) {
  this.account = term.account = this.form.DDDDD.value + this.tempAccountSuffix;
  this.prefixAccount = this.accountPrefix + this.form.DDDDD.value + this.tempAccountSuffix; // 带前缀的账号
  cookie.set('DDDDD', II(escape(this.account)));   // 记住账号（简单混淆后写 cookie）
  cookie.set('upass', II(escape(this.form.upass.value))); // ★ 记住密码（写到 cookie，故有泄露风险）
  cookie.set('mac', term.mac);
  qrCode.stop = true;
  var me = this;

  switch (parseInt(page.login_method)) {
    case 9:
    case 1:  me.login_portal(success, fail);            break; // ★ 标准 portal 协议（本校园网=1）
    case 2:  me.login_ruckus1(success, fail);           break; // Ruckus，表单提交
    case 3:  me.login_cisco(success, fail);             break; // Cisco，表单提交
    case 4:  me.login_moto(success, fail);              break; // Motorola，表单提交
    case 5:  _alert(lang('此种认证方式尚未提供支持'));    break;
    case 6:  me.login_aruba(success, fail);             break; // Aruba，表单提交
    case 7:  me.login_aruba_low(success, fail);         break; // Aruba 低版本，表单提交
    case 8:  me.login_aruba_xml(success, fail);         break; // ArubaXML → 内部就是 login_portal
    case 10: me.login_huawei_cloud_campus(success, fail); break; // 华为云，表单提交
    case 11: me.login_ruckus2(success, fail);           break; // Ruckus，表单提交
    case 12: me.login_ruckus_nbi(success, fail);        break; // Ruckus NBI → login_portal（片段 E）
    case 13: me.login_meru(success, fail);              break; // Meru → login_portal（片段 F，带 url 字段）
    case 14: me.login_wifidog(success, fail);           break; // wifidog → login_portal（片段 G）
    default: me.default_login(success, fail);                 // 其他 → 旧式 default_login（片段 B）
  }
};


/* ============================================================================
 * 【片段 E】★ 真正被本项目复刻的参数字面量：login.login_portal
 * 来源：a40.js 第 3825-3846 行（这是 login_method=1/9 走的函数）
 * ----------------------------------------------------------------------------
 * 这就是抓包 login 请求参数的"源头"。注意：
 *   - user_account / user_password 只有在 no_filter_accandpwd==1（账号密码免过滤）时才用
 *     util.base64Encode；否则直接用原始字符串（随后由 _jsonp 做 XOR）。
 *   - 其余字段（wlan_user_ip/mac/ac_ip/ac_name、vlan、jsVersion、uuid）也会被 _jsonp 统一 XOR。
 *   - is_base64encode 显式告诉后端"账号密码是否 base64"，抓包值=0。
 * ========================================================================== */
login.login_portal = function (success, fail) {
  if (!term.ip && !term.ipv6) {                 // 连 IP 都拿不到就没法登录
    _alert(lang('获取终端用户IP失败，请重试！'));
    return false;
  }
  var data = {
    'login_method'   : page.login_method,       // 抓包=1（XOR 后线上是 11）
    'is_base64encode': typeof (term.no_filter_accandpwd) != 'undefined' ? term.no_filter_accandpwd : 0,
    'user_account'   : (term.no_filter_accandpwd == 1) ? util.base64Encode(this.prefixAccount) : this.prefixAccount,
    'user_password'  : (term.no_filter_accandpwd == 1) ? util.base64Encode(this.form.upass.value) : this.form.upass.value, // ★ 密码
    'wlan_user_ip'   : term.ip,                 // 客户端 IP
    'wlan_user_ipv6' : term.ipv6,
    'wlan_user_mac'  : term.mac,                // 客户端 MAC（去横线大写）
    'wlan_vlan_id'   : term.vlan,
    'wlan_ac_ip'     : term.wlanacip,           // AC 的 IP（抓包=10.128.255.129）
    'wlan_ac_name'   : term.wlanacname,
    'authex_enable'  : term.authex_enable,
    'jsVersion'      : jsVersion,               // 抓包=4.5.1
    'uuid'           : term.uuid
  };
  login.portal_login(data, success, fail);      // 交给片段 C 补齐字段并发送
};
/* 对照本项目 New-DrappallLoginUrl（CampusNet.Common.ps1 1147-1172 行）里的 $fields：
 *   callback/login_method/is_base64encode/user_account/user_password/wlan_user_ip/wlan_user_ipv6/
 *   wlan_user_mac/wlan_vlan_id/wlan_ac_ip/wlan_ac_name/authex_enable/jsVersion/uuid/terminal_type/
 *   lang/user_agent/enable_r3/mac_type/rcn/operate/business_type/program_index/page_index —— 一一对应。
 * 差异：本项目把 terminal_type/business_type 固定为 '1'（PC 有线场景），且 program_index/page_index
 *       由 loadConfig 取回后回带（见 03 解读）。
 */


/* ============================================================================
 * 【片段 F】另外三处"含 user_password 的参数字面量"分别属于哪种场景
 * 来源：a40.js 3866-3879 / 3941-3972 行
 * ----------------------------------------------------------------------------
 * 它们都不是本校园网走的路径，但都是"登录"这一族，参数结构相似，列出来避免误读。
 * ========================================================================== */

/* (E-1) login_ruckus_nbi —— login_method=12（Ruckus NBI 对接） */
// 来源：a40.js 3866-3879 行
login.login_ruckus_nbi = function (success, fail) {
  var data = {
    'login_method'  : page.login_method,
    'user_account'  : this.prefixAccount,
    'user_password' : this.form.upass.value,   // 原始密码
    'wlan_user_ip'  : term.ip,
    'wlan_user_ipv6': term.ipv6,
    'wlan_user_mac' : term.mac,
    'wlan_ac_ip'    : term.wlanacip,
    'wlan_ac_name'  : term.wlanacname,
    'jsVersion'     : jsVersion
  };
  login.portal_login(data, success, fail);     // 同样收敛到 portal_login
};

/* (E-2) login_meru —— login_method=13（Meru 对接） */
// 来源：a40.js 3941-3949 行
// 注意它多传了一个 'url' 字段（由 query 参数拼出的跳转地址），参数更精简。
login.login_meru = function (success, fail) {
  login.portal_login({
    user_account : login.prefixAccount,
    user_password: login.form.upass.value,     // 原始密码
    wlan_user_mac: term.mac,
    wlan_user_ip : term.ip,
    login_method : page.login_method,
    url: "https://" + util.getQueryString('Server_IP') + "/" + util.getQueryString('Login_url')
  }, success, fail);
};

/* (E-3) login_wifidog —— login_method=14（wifidog 对接） */
// 来源：a40.js 3952-3972 行
// 多带 gw_port / gw_address / gw_id（网关信息），成功判定里还有 auth_url 跳转（见片段 C）。
login.login_wifidog = function (success, fail) {
  if (!term.ip && !term.ipv6) { _alert(lang('获取终端用户IP失败，请重试！')); return false; }
  var data = {
    'login_method'  : page.login_method,
    'user_account'  : this.prefixAccount,
    'user_password' : this.form.upass.value,   // 原始密码
    'wlan_user_ip'  : term.ip,
    'wlan_user_ipv6': term.ipv6,
    'wlan_user_mac' : term.mac,
    'wlan_ac_ip'    : term.wlanacip,
    'wlan_ac_name'  : term.wlanacname,
    'gw_port'       : term.gw_port,
    'gw_address'    : term.gw_address,
    'gw_id'         : term.gw_id,
    'jsVersion'     : jsVersion
  };
  login.portal_login(data, success, fail);
};

/* 小结：a40.js 里所有含 'user_password' 的参数字面量
 *   3834 行 → login_portal      （login_method=1/9，★本校园网走的）
 *   3870 行 → login_ruckus_nbi  （login_method=12）
 *   3944 行 → login_meru        （login_method=13）
 *   3960 行 → login_wifidog     （login_method=14）
 *   2629 行 → _self.swtich      （进"自助服务 self"接口，非登录）
 *   4020/4054 行 → logout_portal/logout_ruckus（注销，用占位 'drcom'/'123'）
 * 它们最终都或直接或间接收敛到 login.portal_login(data)。
 */


/* ============================================================================
 * 【片段 G】a41.js 的 online_list —— 登录前的"在线状态"查询
 * 来源：a41.js 第 605-627 行（term.checkStatus）
 * ----------------------------------------------------------------------------
 * 场景：当门户用半径/全业务方式查在线状态（term.checkOnlineMethod==1）或单端口模式时，
 *       不再用本地 chkstatus，而是请求 :803/eportal/portal/online_list。
 * 参数编码：⚠️ 与"已确认事实"不同 —— 源码 2434-2439 行的加密条件会让 online_list
 *       也走 XOR（它含 'eportal/portal' 且不是 loadConfig），抓包实测亦然。
 *       IP/ACIP 先 base64encode，再整体被 _jsonp XOR。
 * ========================================================================== */
term.checkStatus = function () {
  var me = this;
  var url = me.path + 'chkstatus';   // 默认用本地内核 chkstatus
  var data = {};

  if (term.checkOnlineMethod == 1 || port_mode == '1') {   // 改走 eportal 在线列表接口
    url = page.portal_api + 'online_list';                 // → .../eportal/portal/online_list
    data = {
      'user_account'  : '',                                // 登录前查询：账号密码留空
      'user_password' : '',
      'wlan_user_mac' : util.trim(term.mac).toUpperCase(), // MAC 大写
      // 兼容纯IPv4/纯IPv6/IPv4联动IPv6（被注释掉的是旧的 ipToParseInt 方案）
      'wlan_user_ip'  : util.base64encode(util.trim(term.ip)),   // ★ IP 先 base64
      'wlan_user_ipv6': util.base64encode(util.trim(term.ipv6)),
      'jsVersion'     : typeof (jsVersion) == 'undefined' ? '4.X' : jsVersion,
      'uuid'          : term.uuid,
      'login_method'  : page.login_method,
      'wlan_ac_ip'    : util.base64encode(term.wlanacip)    // ★ ACIP 先 base64
    };
  }

  util._jsonp({
    url: url,
    data: data,
    time: term.checkOnlineMethod == 1 ? 5000 : 20000,      // 超时
    success: function (json) {
      // json.result: 0=不在线，1=在线
      if ('undefined' != typeof (json.ss4) && json.ss4 != '000000000000' && json.ss4 != '') {
        // 后端回传的 MAC（ss4）在本地 MAC 是占位值时用来纠正
        term.mac = (term.mac == '000000000000' || term.mac == '111111111111' || term.mac == '123456789012') ? json.ss4 : term.mac;
      }
      if (json.result == 0 && term.enPerceive !== 0) { me.checkMac(); return false; } // 不在线且启用无感知
      if (json.result == 1) {                                                          // 在线
        json.uid && (term.account = json.uid);
        term.online = json;
        me.kind = term.type == 1 ? 'pc_1' : util.switchPageKind(term.type) + '_31';
        me.render(me.load_js_css);
        return false;
      }
      me.firstRender(); // 其余情况继续渲染
    },
    error: function () { /* 内核/接口不可用处理略 */ }
  });
};
/* 抓包实测 online_list 请求（当时的抓包（已按隐私要求移除））：
 *   callback=4e581b1a1a18(=dr1002) & wlan_user_ip=677e6b5f67406b5f67506b5f646e6b17
 *   = XOR0x2A("MTAuMjAuMzAuNDA=")   & wlan_ac_ip=...   & login_method=1b(=1) & encrypt=1&v=5053&lang=zh
 * 即"base64 + XOR"两层都叠上了。
 */


/* ============================================================================
 * 【片段 H】operate == "portal_login" 的 JSONP 错误处理
 * 来源：a41.js 第 2486-2549 行
 * ----------------------------------------------------------------------------
 * 场景：登录用的是 JSONP（<script> 标签）。若后端返回的不是合法 JSONP
 *       （例如返回一整段 HTML / 语法错误），<script> 会触发 onerror 或
 *       window.onerror 里的 SyntaxError，代码据此判定"登录请求失败"并给出兜底提示。
 *       只有当 operate 是 "portal_login" 时才做这套处理 —— 因为登录失败最需要给用户反馈。
 * ========================================================================== */
// 现代浏览器：<script> onerror
script.onerror = function () {
  if (!requestCompleted && params.data && params.data['operate'] === "portal_login") {
    handleJsonpError();
  }
};

// 全局错误捕获：把"返回 HTML 导致 JSONP 解析语法错误"也当成登录失败
window.onerror = function (message, source, lineno, colno, error) {
  if (params.data && params.data['operate'] === "portal_login" &&
      source === script.src && message.indexOf('SyntaxError') !== -1) {
    head.removeChild(script);
    clearTimeout(script.timer);
    window[callbackName] = null;
    window.onerror = originalOnError; // 恢复默认错误处理
    handleJsonpError();
    return true;                       // 阻止错误继续抛出
  }
  return false;
};

// 通用处理：渲染错误页并提示"服务器内部错误，请返回认证页重新登录"
function handleJsonpError() {
  if (params.data && params.data['operate'] === "portal_login") {
    try {
      debugLog("检测到 portal_login 操作失败，执行错误处理");
      page.kind = term.type == 1 ? 'pc_2' : util.switchPageKind(term.type) + '_32';
      page.render(function () {
        $('#message').html('服务器内部错误，请返回认证页重新登录');
      });
      params.error && params.error({ message: '请求失败' }, '', (params.complete && params.complete()));
    } catch (jsonpHandleError) {
      debugLog("handleJsonpError 处理出错:" + jsonpHandleError, "error");
    }
  } else {
    debugLog("非 portal_login 操作，跳过错误处理");
  }
}
/* 注：这里判定失败只看"JSONP 是否成功执行"，不看业务结果；业务结果由片段 C 的
 *   json.result 判定。两者叠加才能区分"接口坏了"和"密码错了"。
 * 与本项目 ConvertFrom-PortalResponse 的关系：本项目在服务端(PowerShell)直接读
 *   响应体文本再正则解析，遇到"一大段 <!DOCTYPE html>"就判为"响应不可识别"，
 *   与之对应。
 */
