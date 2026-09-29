/* ============================================================================
 * 01-加解密.js  —— Dr.COM 哆点门户「加解密」解读版
 * ----------------------------------------------------------------------------
 * 本文件不是可运行的生产代码，而是把 saved-page/ 里的加解密相关片段
 * 重新排版成多行、逐段加中文注释，供本项目对照。
 *
 * 覆盖来源：
 *   a41.js  第 13-17 行       三个全局开关变量
 *   a41.js  第 2338-2344 行   util.getkey    —— 由 IP 推导 XOR key
 *   a41.js  第 2345-2359 行   util.enc_pwd   —— 逐字符 XOR 转 hex
 *   a41.js  第 2433-2470 行   util._jsonp    —— "是否加密 / 用哪个 key"的分支
 *   a41.js  第 2598-2628 行   util.base64encode —— 非 UTF-8 版 base64（IP 用这个）
 *   a41.js  第 2676-2743 行   util.base64Encode —— UTF-8 版 base64（账号/密码用这个）
 *   a40.js  第 6725-6733 行   WebAuthn web_register —— 同一套加密分支的另一处出现
 *
 * 本项目对应实现：CampusNet.Common.ps1 的
 *   Get-DrappallKey / ConvertTo-DrappallValue / ConvertFrom-DrappallValue
 * ========================================================================== */


/* ============================================================================
 * 【片段 A】三个全局开关：决定"要不要加密、用哪个 key"
 * 来源：a41.js 第 13-17 行（原文各占一行，这里保留原注释含义并重写）
 * ----------------------------------------------------------------------------
 * 这三个变量由门户后端"方案配置"注入，会随门户配置变化。
 * 本次抓包（10.0.10.252）的实测取值：page_data_encrypt='1'、encryption_type='0'、secret_key='drcom'。
 * ========================================================================== */
var page_data_encrypt = '1'; // 页面传输数据是否加密：0=不加密，1=加密。本校园网=1（所以参数会变 hex）
var encryption_type   = '0'; // 数据加密类型：0=用终端 IP 当 key（默认），1=用 secret_key 当 key。本校园网=0
var secret_key        = 'drcom'; // 仅当 encryption_type='1' 时才用；本次抓包没用上（默认走 IP）

// 说明（apg 是另一套 AES 通道，与本解读的 XOR 无关，列出仅为区分）：
var apg_switch        = '0';  // apg 启用状态：0=关闭（本次关闭，所以看不到 apgTime/params 那套 AES）


/* ============================================================================
 * 【片段 B】util.getkey —— 由 IP 字符串推导出那一个字节的 XOR key
 * 来源：a41.js 第 2338-2344 行（原注释只有一句"//加密IP地址"）
 * ----------------------------------------------------------------------------
 * 做什么：把 IP 字符串（例如 "10.20.30.40"）的每个字符 ASCII 码，用「逐位异或」累加，
 *         得到一个整数，作为后续逐字符 XOR 的 key。
 * 为什么：key 不是写死的常量，而是跟"客户端 IP"绑定 —— 换 IP/换网段 key 就变，
 *         所以门户能拿它当一种"你到底是不是这条链路"的校验，写死 key 会被判非法。
 * 参数：ip —— 点分十进制 IPv4 字符串。
 * 结果：一个 0..255 的整数（异或结果再按 1 字节取），本项目里按 0xNN 处理。
 *
 * 注意：JS 的 ^ 是 32 位整数按位异或；IP 全是 ASCII（<128），异或结果天然落在 0..255，
 *       所以不需要额外 &0xFF。本项目 ConvertTo-DrappallValue 里用 (-band 0xFF) 显式截断，
 *       语义等价。
 * ========================================================================== */
function getkey(ip) {
  var ret = 0;
  var len = ip.length;
  for (var i = 0; i < len; i++) {
    ret ^= ip.charCodeAt(i); // 逐字符异或：ret = ret XOR 第 i 个字符的 ASCII 码
  }
  return ret; // 返回值就是本次会话的 XOR key（本项目叫 $xorKey）
}

/* 手工验算（合成示例，可自行复核）：
 *   IP 字符       1   0   .   2   0   .   3   0   .   4   0
 *   ASCII(hex)   31  30  2E  32  30  2E  33  30  2E  34  30
 *   逐步 XOR  →   31^30=01 ^2E=2F ^32=1D ^30=2D ^2E=03 ^33=30 ^30=00 ^2E=2E ^34=1A ^30=2A
 *   结果 = 0x2A   → 所以 10.20.30.40 的 key = 0x2A
 *   同理：10.20.30.41 → 0x2B ； 10.20.30.42 → 0x28
 *   （上面三组 IP 均为**合成值**：真实抓包已按隐私要求从仓库移除，
 *     但“key 由 IP 推导”这条算法本身未变，可用任意 IP 自行复核。）
 */


/* ============================================================================
 * 【片段 C】util.enc_pwd —— 逐字符 XOR key 后转 2 位十六进制
 * 来源：a41.js 第 2345-2359 行（原注释里被注释掉的 if(len>512) 是长度限制，已废弃）
 * ----------------------------------------------------------------------------
 * 做什么：把明文 passIn 的每个字符 ch 与 key 异或，得到 0..255 的字节，
 *         再写成"小写十六进制、不足两位前面补 0"，拼接起来。
 * 为什么：GET 请求的参数值要能安全放进 URL；异或后再转 hex，既隐藏明文又只含 [0-9a-f]。
 * 参数：passIn —— 待处理的参数值（字符串）；key —— 片段 B 得到的 XOR key。
 * 结果：纯十六进制字符串，长度 = 2 × 原字符数。空串原样返回空串（→ 线上表现为 key=）。
 *
 * ⚠️ 这不是"加密"，而是一个可逆的编码：任何拿到 key 的人都能还原，所以它是混淆不是安全。
 * ========================================================================== */
function enc_pwd(passIn, key) {
  var passOut = "";
  if (typeof (passIn) == 'undefined' || passIn == '') {
    return passOut; // 空值 → 返回空串（调用方不会给它套 key= 后面的内容）
  }
  var len = passIn.length;
  var ch = 0;
  var str = "";
  for (var i = 0; i < len; i++) {
    ch  = passIn.charCodeAt(i) ^ key; // ① 逐字符 XOR key，得到 1 字节
    str = ch.toString(16);            // ② 转成 16 进制（小写）
    if (str.length == 1) str = "0" + str; // ③ 不足 2 位前面补 0（保证每字符固定 2 位）
    passOut += str;                   // ④ 拼接
  }
  return passOut;
}

/* 手工验算（key = 0x20）：
 *   "dr1003"  → d(64)^20=44  r(72)^20=52  1(31)^20=11  0(30)^20=10  0^20=10  3(33)^20=13
 *              → "445211101013"   （默认 key 0x20 下的例子）
 *   "zh-cn"   → z(7A)^20=5A  h(68)^20=48  -(2D)^20=0D  c(63)^20=43  n(6E)^20=4E → "5a480d434e"
 *   "10.20.30.40" 用它自己的 key 0x2A → 1b1a04181a04191a041e1a
 *              （这一行专门用来说明：同一个明文，换 IP → 换 key → 密文全变）
 * 注意 char code 只有低 8 位参与（ASCII 情况下天然如此），与本项目
 * ConvertTo-DrappallValue 的 (([int][char]$ch) -band 0xFF) -bxor $mask 完全等价。
 */


/* ============================================================================
 * 【片段 D】util._jsonp —— 决定"要不要加密、用 ip 还是 secret_key"的分支
 * 来源：a41.js 第 2433-2470 行（同函数上文 2396-2431 行会先注入
 *        program_index/page_index/jsVersion/callback，见 02/03 解读）
 * ----------------------------------------------------------------------------
 * 这是整个混淆逻辑的"总闸"：只有满足下面 4 个条件，参数值才会走 enc_pwd；
 * 否则原样（仅做 URL 编码）发出。
 * ========================================================================== */

// —— 下面的 if 条件逐条注释，就是"哪些接口会被 XOR"的真值来源 ——
if (
    page_data_encrypt == 1                        // ① 门户开了页面加密（本校园网=1）
    && params.url.indexOf('eportal/portal') > -1  // ② 只作用于 eportal/portal/* 这一族接口
    && params.url.indexOf('wifidog/disconnect') == -1 // ③ wifidog 注销接口除外
    && params.url.indexOf('page/loadConfig') == -1    // ④ ★ loadConfig 除外（它用明文 base64）
) {
  // —— 选 key：encryption_type 决定用"密钥"还是"终端 IP" ——
  if (encryption_type == '1') {
    var keys = this.getkey(secret_key); // 类型 1：key = getkey("drcom")（本校园网没走这条）
  } else {
    // 类型 0（本校园网默认）：key = getkey(客户端 IP)
    // 原注释："//这里应该用终端实际IP,可从ss5登参数中获取" → 即 key 跟客户端 IP 绑定
    var keys = this.getkey(term.ip);
  }

  // —— 逐个参数值做 XOR，收集到 arr ——
  var arr = [];
  for (var key in params.data) {
    // 把数字型参数先 toString()，避免 enc_pwd 里 passIn.length 对数字异常
    if (parseFloat(params.data[key]).toString() != "NaN") {
      params.data[key] = params.data[key].toString();
    }
    arr[key] = this.enc_pwd(params.data[key], keys); // 每个值都 XOR（含 callback、operate！）
  }

  // 用来区分"是 portal 前端还是 vue 传的参数"；标记本次是加密形态
  arr['encrypt'] = 1; // ⚠️ 在加密循环之后才加 → encrypt=1 本身不被 XOR（线上就是明文 "1"）

  // 把数组对象整理成普通对象（ES5 兼容写法，等价于 Object.assign({}, arr)）
  var newObj = {};
  for (var k2 in arr) {
    if (arr.hasOwnProperty(k2)) newObj[k2] = arr[k2];
  }
  arr = newObj;

  // formatParams 会把每个值 encodeURIComponent（hex 串本来就只有 [0-9a-f]，编码后不变），
  // 并在最后追加 "v=<随机>" 和 "lang=<zh>"（这两个同样不被 XOR）
  var data = formatParams(arr);
} else {
  // 不加密的分支：原样（仅 URL 编码）。page/loadConfig、wifidog/disconnect、非 eportal/portal 的
  // 请求都走这里 —— 这就是"loadConfig 用 URL 编码 base64 而非 XOR"的根因。
  var data = formatParams(params.data);
}

/* formatParams 的收尾（来源 a41.js 2364-2389，此处只摘与加密相关的两行）：
 *   arr.push('v=' + random());   // 防缓存随机数，不编码
 *   arr.push('lang=' + lang);    // 语言标识，不编码
 * callback 会被 unshift 到最前面；但它的"值"在加密分支里已被 XOR 过
 * （所以线上是 callback=445211101013 而不是 callback=dr1003）。
 */


/* ============================================================================
 * 【片段 E】两种 base64 —— "用哪一个"取决于要编码的是 IP 还是账号/密码
 * 来源：a41.js 第 2598-2628 行（base64encode，小写 e）与第 2676-2743 行（base64Encode，大写 E）
 * ----------------------------------------------------------------------------
 * 结论先说：
 *   - util.base64encode(...)（小写 e，Latin-1/字节级）→ 用来编 IP（wlan_user_ip / wlan_ac_ip）。
 *     它取 str.charCodeAt(i) & 0xff，纯 ASCII 下与标准 base64 一致；抓包里 IP 的 base64 就是它算的。
 *   - util.base64Encode(...)（大写 E，UTF-8 版）→ 只在账号/密码"免过滤"(no_filter_accandpwd=1)
 *     时对账号/密码做 base64；能正确处理中文，但本次抓包没触发。
 * 使用条件（源码里逐处可见）：
 *   - a41.js 467/468/471（loadConfig）与 620/621/625（online_list）：IP/IPv6/ACIP 用 base64encode
 *   - a40.js 3833/3834（login_portal）：username/password 仅当 no_filter_accandpwd==1 时用 base64Encode
 * ========================================================================== */

// —— base64encode：字节级（每字符只取低 8 位）。IP 用它。 ——
// 来源：a41.js 2598-2628
util.base64encode = function (str) {
  var base64EncodeChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  var out = "", i = 0, len = str.length;
  var c1, c2, c3;
  while (i < len) {
    c1 = str.charCodeAt(i++) & 0xff; // ★ 关键：只取低 8 位（非 UTF-8 语义）
    if (i == len) { // 剩 1 字节 → 补 "=="
      out += base64EncodeChars.charAt(c1 >> 2);
      out += base64EncodeChars.charAt((c1 & 0x3) << 4);
      out += "==";
      break;
    }
    c2 = str.charCodeAt(i++); // 注意 c2 没再 &0xff（与标准实现略有出入，ASCII 下无影响）
    if (i == len) { // 剩 2 字节 → 补 "="
      out += base64EncodeChars.charAt(c1 >> 2);
      out += base64EncodeChars.charAt(((c1 & 0x3) << 4) | ((c2 & 0xF0) >> 4));
      out += base64EncodeChars.charAt((c2 & 0xF) << 2);
      out += "=";
      break;
    }
    c3 = str.charCodeAt(i++); // 满 3 字节 → 4 个 base64 字符
    out += base64EncodeChars.charAt(c1 >> 2);
    out += base64EncodeChars.charAt(((c1 & 0x3) << 4) | ((c2 & 0xF0) >> 4));
    out += base64EncodeChars.charAt(((c2 & 0xF) << 2) | ((c3 & 0xC0) >> 6));
    out += base64EncodeChars.charAt(c3 & 0x3F);
  }
  return out;
};
/* 例：base64encode("10.20.30.40") = "MTAuMjAuMzAuNDA="
 *     再经 formatParams 的 encodeURIComponent → "MTAuMjAuMzAuNDA%3D"（抓包 loadConfig 里正是这个）
 *     这与本项目 New-DrappallLoadConfigUrl 里 [uri]::EscapeDataString(base64) 的结果一致。 */

// —— base64Encode：UTF-8 版（先手工把字符串编成 UTF-8 字节，再按标准 base64 分组）。 ——
// 来源：a41.js 2676-2743（这里只保留主干，原实现用二进制字符串拼接、ES5 兼容）
util.base64Encode = function (input) {
  var me = this;
  var base64Chars = me.base64EncodeChars;
  var utf8Bytes = [];

  // ① 手工 UTF-8 编码（含 1/2/3/4 字节分支），保证中文也能正确编码
  for (var i = 0; i < input.length; i++) {
    var charCode = input.charCodeAt(i);
    if (charCode < 128) {                 // 单字节
      utf8Bytes.push(charCode);
    } else if (charCode < 2048) {         // 双字节
      utf8Bytes.push(192 + (charCode >> 6));
      utf8Bytes.push(128 + (charCode & 63));
    } else if (charCode < 65536) {        // 三字节
      utf8Bytes.push(224 + (charCode >> 12));
      utf8Bytes.push(128 + ((charCode >> 6) & 63));
      utf8Bytes.push(128 + (charCode & 63));
    } else {                              // 四字节（基本用不到）
      utf8Bytes.push(240 + (charCode >> 18));
      utf8Bytes.push(128 + ((charCode >> 12) & 63));
      utf8Bytes.push(128 + ((charCode >> 6) & 63));
      utf8Bytes.push(128 + (charCode & 63));
    }
  }

  // ② 把字节拼成二进制串（每字节固定 8 位）
  var binaryString = '';
  for (var j = 0; j < utf8Bytes.length; j++) {
    var byteStr = utf8Bytes[j].toString(2);
    while (byteStr.length < 8) byteStr = '0' + byteStr; // ES5 版 padStart
    binaryString += byteStr;
  }

  // ③ 每 6 位切一块，末尾不足补 0
  var chunks = [];
  for (var k = 0; k < binaryString.length; k += 6) {
    var chunk = binaryString.slice(k, k + 6);
    while (chunk.length < 6) chunk += '0'; // ES5 版 padEnd
    chunks.push(chunk);
  }

  // ④ 每块查表转成 base64 字符，最后补 "=" 凑 4 的倍数
  var base64Encoded = '';
  for (var l = 0; l < chunks.length; l++) {
    base64Encoded += base64Chars.charAt(parseInt(chunks[l], 2));
  }
  while (base64Encoded.length % 4 !== 0) base64Encoded += '=';
  return base64Encoded;
};
/* 对纯 ASCII 输入（IP 等），base64Encode 与 base64encode 结果相同；
 * 区别只在含中文时（前者按 UTF-8，后者按低 8 位）。 */


/* ============================================================================
 * 【片段 F】同一套加密分支的另一处出现：a40.js 的 WebAuthn「首次绑定」注册
 * 来源：a40.js 第 6725-6733 行（web_register 函数内）
 * ----------------------------------------------------------------------------
 * 说明：这不仅在 a41.js 的 _jsonp 里出现；a40.js 的 WebAuthn 流程也用了同一套
 *       "page_data_encrypt ? (encryption_type==1 ? getkey(secret_key) : getkey(term.ip))" 逻辑，
 *       把密码 enc_pwd 后拼进 URL 的 up= 参数。
 *       本次校园网未启用 WebAuthn，但它是"加密规则与登录同源"的旁证。
 * ========================================================================== */
function web_register() {
  var password = $("input[type=password][name=upass]").val();
  // ...（账号/浏览器能力校验略；不涉及加密）...
  if (page_data_encrypt == '1') {
    if (encryption_type == '1') {
      var keys = util.getkey(secret_key); // 用密钥当 key
    } else {
      var keys = util.getkey(term.ip);    // 用终端 IP 当 key（与登录完全一致）
    }
    var enc_pwd = util.enc_pwd(password, keys); // 逐字符 XOR → hex
  } else {
    var enc_pwd = password; // 不加密就用明文
  }
  // 后续：...handle?fn=processCreate... + '&up=' + enc_pwd  （见 a40.js 6755 行）
}


/* ============================================================================
 * 小结（一图流）
 * ----------------------------------------------------------------------------
 *   客户端 IP "10.20.30.40"
 *        │  util.getkey()
 *        ▼
 *      key = 0x20
 *        │  util.enc_pwd(每个参数值, 0x20)
 *        ▼
 *   "dr1003" → "445211101013"    "portal_login" → "504f5254414c7f4c4f47494e"
 *   空值 → ""                      encrypt=1 / v=随机 / lang=zh  不经此步
 * ========================================================================== */
