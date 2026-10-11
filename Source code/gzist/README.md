# 校园网登录脚本

## 用途

1. 可以根据指定的mac和ip进行登录特定的设备，如：在机房使宿舍电脑登录校园网
2. 使用工具实现开机自动登录校园网

## 参数解释

`METHOD` ：登录方式：0：电脑客户端登录 1：手机客户端登录  
`ACCOUNT` ：用户账号  
`PASSWORD` ：用户密码  
`MAC` ：登录设备的MAC 地址（xx-xx-xx-xx-xx-xx）[为空则自动获取]  
`IP` ：登录设备的IP 地址（IPv4）[为空则自动获取]  
`ADAPTERNAME` ：以太网'获取MAC和IP的网卡名称[为空则使用自定义]  

## 使用

### Windows 用户

#### 基本使用方法

1. 克隆本仓库到本地
2. 在`xyw_login.ps1`文件内填入对应参数；  
   或者在`logint.bat`中使用传递参数的方式编辑`PowerShell .\xyw_login.ps1 >> login.log`，  
   如：`PowerShell .\xyw_login.ps1 -ACCOUNT 123 -PASSWORD 456 >> login.log`
   >其余参数可以在`xyw_login.ps1`-`Param`内找到
3. 运行`logint.bat`
4. 观察`logint.bat`所在目录生成的`logint.log`

#### 开机自动执行

1. [任务计划程序](https://www.bing.com/search?q=win%E4%BB%BB%E5%8A%A1%E8%AE%A1%E5%88%92%E7%A8%8B%E5%BA%8F+%E5%BC%80%E6%9C%BA%E6%89%A7%E8%A1%8Cbat)
2. [sc.exe create](https://learn.microsoft.com/zh-cn/windows-server/administration/windows-commands/sc-create)
3. ...

### 其他用户（待补充）
