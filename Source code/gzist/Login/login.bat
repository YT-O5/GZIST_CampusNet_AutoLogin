@REM 登录方式：0：电脑客户端登录 1：手机客户端登录
set "METHOD=0"
@REM 用户账号
set "ACCOUNT="
@REM 用户密码
set "PASSWORD="
@REM 登录设备的MAC 地址（xx-xx-xx-xx-xx-xx）[为空则自动获取]
set "MAC="
@REM 登录设备的IP 地址（IPv4）[为空则自动获取]
set "IP="
@REM 获取MAC和IP的网卡名称[为空则使用自定义]
set "ADAPTERNAME=以太网"
@REM 初始化参数字符串
set "ARGS="

@REM 构建参数字符串
if not "%METHOD%"=="" set "ARGS=%ARGS% -METHOD %METHOD%"
if not "%ACCOUNT%"=="" set "ARGS=%ARGS% -ACCOUNT %ACCOUNT%"
if not "%PASSWORD%"=="" set "ARGS=%ARGS% -PASSWORD %PASSWORD%"
if not "%MAC%"=="" set "ARGS=%ARGS% -MAC %MAC%"
if not "%IP%"=="" set "ARGS=%ARGS% -IP %IP%"
if not "%ADAPTERNAME%"=="" set "ARGS=%ARGS% -ADAPTERNAME %ADAPTERNAME%"

PowerShell set-executionpolicy remotesigned
PowerShell .\xyw_login.ps1 %ARGS%