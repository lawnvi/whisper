## Whisper

[English](./README_en.md)

whisper（土电话）在局域网内快速分享文本和文件，实现剪贴板内容的快速互传。

### 功能特点
- 支持在局域网内的Android、MacOS、Linux和Windows设备之间分享文本和文件。
- 可将来自Android设备的通知推送到其他连接的设备上。
- 单独建立FTP服务

### 工作原理
Whisper使用Flutter开发，通过建立WebSocket连接与局域网中指定的设备进行通信。

### 使用提示
1. 不会dart，不会flutter，就是不想用微信文件传输助手
2. 连接可能会断开，需要手动重新连接。在某些情况下，设备可能无法自动发现，需要手动输入设备地址进行连接。
3. 水平有限不好看，有些代码只有上帝...也许他也不想看了
4. 由于不熟悉打包技术，Windows上的安装方式有些过时。不一定支持ARM设备。
5. 虽然可能不是最美观或安全的选择，但对于个人使用来说足够了。
6. 由于使用的库需要先将大文件复制到缓存目录，因此大文件可能无法立即开始传输。桌面端的拖放功能应该不会遇到此问题。
7. 写入文件前请确保设备有足够的存储空间，没有做剩余空间的检查。
8. 没有加密！没有校验！
9. 仅支持文本和文件消息展示。
10. 阿巴阿巴～

### 安装
[home page](https://2.127014.xyz/whisper)  |  [Latest Release](https://github.com/lawnvi/whisper/releases)  

### Linux安装
如果您的Linux系统未安装Avahi（用于设备发现），请运行以下命令：
```shell
sudo apt install -y avahi-daemon avahi-discover avahi-utils libnss-mdns mdns-scan
```

### 截图展示
<div style="display: inline-block; text-align: center;">
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_4.jpg" width="74%" style="border-radius: 6px;"/>
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_2.png" width="24%" style="border-radius: 6px;"/>
</div>
<div style="display: inline-block; text-align: center;">
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_3.jpg" width="74%" style="border-radius: 6px;"/>
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_5.png" width="24%" style="border-radius: 6px;"/>
</div> 

如有任何问题或需要进一步帮助，请随时联系！