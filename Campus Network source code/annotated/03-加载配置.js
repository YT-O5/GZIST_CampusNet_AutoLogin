/* ============================================================================
 * 03-加载配置.js —— page/loadConfig 请求构造 解读版
 * ----------------------------------------------------------------------------
 * 覆盖来源：
 *   a41.js  第 460-604 行   page.getPageInfo（整个函数）
 *   关联：a41.js 第 2396-2431 行（util._jsonp 会统一补 program_index/page_index/jsVersion/callback）
 *
 * 本项目对应实现：CampusNet.Common.ps1 的
 *   New-DrappallLoadConfigUrl（1195-1228 行） / Get-DrappallPageIndex（1233-1267 行）
 * ========================================================================== */


/* ============================================================================
 * 【片段 A】page.getPageInfo —— 向 :803 取"页面配置"
 * 来源：a41.js 第 461-604 行
 * ----------------------------------------------------------------------------
 * 干什么：页面加载时先调一次 loadConfig，拿到方案索引/页面索引等一堆配置，
 *         存进 page.* 和 term.*，后续登录等接口都会用到。
 * 怎么发：仍然走 util._jsonp（所以会带 callback/jsVersion，并统一注入 program_index/page_index）。
 * 结果怎么用：见片段 C 的字段逐条注释。
 * ========================================================================== */
page.getPageInfo = function (next) {
  var me = this;
  // ★ 接口地址（注意结尾斜杠）：portal_api = 'http://<host>:803/eportal/portal/'
  var url = page.portal_api + 'page/loadConfig';

  // —— 请求参数（构造顺序即线上顺序）——
  var data = {};
  data.program_index    = me.name;                    // 方案索引（首次为空串，之后回填）
  data.wlan_vlan_id     = term.vlan;                  // VLAN
  data.wlan_user_ip     = util.base64encode(term.ip);       // ★ 客户端 IP → base64
  data.wlan_user_ipv6   = util.base64encode(term.ipv6);     // ★ IPv6 → base64
  data.wlan_user_ssid   = term.ssid;                  // SSID（明文）
  data.wlan_user_areaid = term.areaID;                // 区域 ID（明文）
  data.wlan_ac_ip       = util.base64encode(term.wlanacip); // ★ AC IP → base64
  data.wlan_ap_mac      = term.wlanapmac;             // AP MAC（明文）
  data.gw_id            = term.gw_id;                 // 网关 ID（明文）

  util._jsonp({
    url: url,
    data: data,
    success: function (json) {
      if (json.code == 0) {                            // 后端 code=0 表示取配置失败
        alert(json.msg);
        return false;
      }
      /* ==========================================================
       * 【片段 C】loadConfig 返回字段的用途（json.data.*）
       * 说明：下面挑选与"认证/本项目"直接相关的字段逐条注释；
       *       其余大量 UI/广告/短信/密码策略字段从略（同样来自 json.data）。
       * ========================================================== */
      me.index        = json.data.page_index || '';    // ★ 页面索引（登录请求要回带 page_index）
      me.name         = json.data.program_index || ''; // ★ 方案索引（登录请求要回带 program_index）
      me.page_name    = json.data.page_name || '';     // 页面名称（展示用）
      me.page_style   = json.data.page_style || '';    // 页面风格
      me.page_url     = me.eportal + 'extern/' + me.name + '/' + me.index + '/'; // 页面资源目录
      me.login_method = parseInt(json.data.login_method) || 0; // ★ 认证方式（决定走哪条登录分支）

      me.redirectLink = json.data.redirect_url || '';  // 登录后重定向地址
      me.window_title = json.data.window_title || '';  // 页面标题前缀
      me.enable_r3    = parseInt(json.data.enable_r3) || 0; // 串接 pppoe 代拨
      me.en_md5       = parseInt(json.data.en_md5) || 0;    // 是否 MD5 挑战认证
      me.password_cut = parseInt(json.data.password_cut) || 0;

      // —— 与本项目"探针黑名单"直接相关（本项目 Get-DefaultProbeBlacklist 的真值来源）——
      me.visit_blacklist = json.data.visit_blacklist || []; // 重定向黑名单列表（门户不劫持的地址）

      // —— 成功页/注销页要展示的各类信息 ——
      me.user_info     = json.data.user_info || [];
      me.online_info   = json.data.online_info || [];
      me.logon_info    = json.data.logon_info || [];
      me.recharge_info = json.data.recharge_info || [];

      // —— 方案(term)级参数：从 json.data 拷进 term.*，供全局使用 ——
      term.ISRedirect     = parseInt(json.data.is_redirect) || 0;   // 是否重定向
      term.suffix         = json.data.account_suffix || '';         // 账号后缀
      term.cvlanid        = parseInt(json.data.cvlan_id) || 4095;   // 绑定 CVLAN
      term.onlineMonitor  = parseInt(json.data.online_monitor) || 1; // 在线监听
      term.checkOnlineMethod = parseInt(json.data.check_online_method) || 0; // ★ 0=本地 chkstatus，1=用 online_list
      term.rcn            = json.data.rcn || '';                    // apg 页面随机数
      term.enable_alias   = parseInt(json.data.enable_alias) || 0;  // 别名认证

      // —— 密码策略（门户下发；本项目 README 记录 length_require=8 / compose_require=3）——
      term.enable_verify    = parseInt(json.data.enable_verify) || 0;    // 0停/1前端校验/2后端校验
      term.length_require   = parseInt(json.data.length_require) || 8;   // 密码长度要求
      term.compose_require  = parseInt(json.data.compose_require) || 3;  // 组合个数要求
      term.enable_digital_char = parseInt(json.data.enable_digital_char) || 0;
      term.enable_upper_case   = parseInt(json.data.enable_upper_case) || 0;
      term.enable_lower_case   = parseInt(json.data.enable_lower_case) || 0;
      term.enable_special_char = parseInt(json.data.enable_special_char) || 0;

      // —— 其他与登录/识别相关的开关 ——
      term.no_filter_accandpwd   = parseInt(json.data.no_filter_accandpwd) || 0;   // 账号密码免过滤（决定是否 base64 编账号密码）
      term.auth_failed_prompt    = parseInt(json.data.auth_failed_prompt) || 0;    // 认证失败是否弹窗
      term.ipad_terminal_identity= parseInt(json.data.ipad_terminal_identity) || 0;

      next(); // 配置就绪后进入下一步（渲染/登录等）
    },
    error: function () {
      next(); // 即使取配置失败也继续（本项目 Get-DrappallPageIndex 同样"取不到就留空继续"）
    }
  });
};


/* ============================================================================
 * 【片段 B】util._jsonp 对 loadConfig 的"统一加工"
 * 来源：a41.js 第 2396-2431 / 2433-2470 行
 * ----------------------------------------------------------------------------
 * 所有 _jsonp 请求都会先被加上这些字段；对 loadConfig 有两处特别重要：
 *   ① 统一注入 program_index / page_index（值取 page.name / page.index）
 *   ② loadConfig 被排除在 XOR 加密之外 → 参数保持明文（base64 值再做 URL 编码）
 * ========================================================================== */
// ① 统一注入（来源 a41.js 2400-2402）
params.data['program_index'] = page.name;   // 方案索引
params.data['page_index']    = page.index;  // 页面索引

// （后续 2426 生成 callback、2429 写入 callback、2431 补 jsVersion）
params.data['callback']  = callbackName;    // 'dr' + increment()，loadConfig 是页面首个请求 → 'dr1001'
params.data['jsVersion'] = typeof (jsVersion) == 'undefined' ? '4.X' : jsVersion;
// ⚠️ jsVersion 在 a40.js 第 8622 行才被赋值为 '4.5.1'，而 loadConfig 跑在它之前，
//    所以抓包里 loadConfig 的 jsVersion=4.X，而 login 的 jsVersion=4.5.1。

// ② 加密闸门（来源 a41.js 2434-2439）：loadConfig 命中 "indexOf('page/loadConfig') == -1" 的反面，
//    于是**不进** XOR 分支，参数保持明文 → 这就是"loadConfig 用 URL 编码的 base64 而非 XOR"的原因。


/* ============================================================================
 * 【抓包实证】当时抓到的真实 loadConfig 请求（该抓包已按隐私要求移除）
 * ----------------------------------------------------------------------------
 * GET http://10.0.10.252:803/eportal/portal/page/loadConfig
 *   ?callback=dr1001                                  ← 明文（未 XOR）
 *   &program_index=                                  ← 空
 *   &wlan_vlan_id=0
 *   &wlan_user_ip=MTAuMjAuMzAuNDA%3D                 ← base64("10.20.30.40")，'=' 被编成 %3D
 *   &wlan_user_ipv6=
 *   &wlan_user_ssid=
 *   &wlan_user_areaid=
 *   &wlan_ac_ip=MTAuMTI4LjI1NS4xMjk%3D               ← base64("10.128.255.129")
 *   &wlan_ap_mac=000000000000
 *   &gw_id=000000000000
 *   &page_index=
 *   &jsVersion=4.X                                   ← 因为 jsVersion 此时还是 undefined
 *   &v=7952&lang=zh                                  ← formatParams 追加，不编码
 *
 * 与我们对照：
 *   本项目 New-DrappallLoadConfigUrl 生成的参数（callback/program_index/wlan_vlan_id/
 *   wlan_user_ip/wlan_user_ipv6/wlan_user_ssid/wlan_user_areaid/wlan_ac_ip/wlan_ap_mac/gw_id/
 *   page_index/jsVersion + v + lang）与上面**逐项一致**；
 *   wlan_user_ip / wlan_ac_ip 走 EscapeDataString(base64(...))，等价于这里的 %3D 编码。
 * ----------------------------------------------------------------------------
 * 返回体（登录时回带的两个值来自这里）：
 *   program_index ≈ "vDRn3i1789461695"、page_index ≈ "wfIsOK1789465653"（登录请求里可见其 XOR 形态）
 *   本项目 Get-DrappallPageIndex 用正则抠出 "program_index"/"page_index"/"page_name" 三个字段。
 * ========================================================================== */
