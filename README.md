# whisper

耳鬓厮磨，缱绻旖旎够近了吧  
悄悄地，很贴心  
whisper with u

## 什么用
局域网内两个设备文本/文件互传，快速复制写入对方设备剪切板  
不访问公网  
支持设备：Android、MacOS、Linux、Windows、~~ios~~（仅模拟器测试，没钱，不会，真机试了应该是没权限）
推送安卓设备的通知到其他设备

## 怎么做的
flutter开发，建立websocket，通过局域网指定对方地址与端口连接

## tips
1. 不会dart，不会flutter，就是不想用微信文件传输助手
2. 连接会断，断开不会自动处理，断开重新连；部分情况发现不了其他设备，需要手动输入地址连接，不要在意
3. 水平有限不好看，有些代码只有上帝...也许他也不想看了
4. windows因为不会打包，安装方式比较古早，arm设备也不会打包
5. 不好看，不好用，不安全，自己用的问题不大
6. 选择文件时因为使用的库需要先复制到缓存目录所以大文件不会即时开始传输，桌面端拖拽应该没有这个问题
7. 写入文件时不会检查设备剩余空间是否足够，请注意剩余空间是否足够
8. 只有文本和文件两种消息展示
9. 阿巴阿巴

[web](https://2.127014.xyz/whisper)  [下载⬇](https://github.com/lawnvi/whisper/releases)


If you don't have Avahi installed on your linux system, just install it using :
```shell
  sudo apt install -y avahi-daemon avahi-discover avahi-utils libnss-mdns mdns-scan
```


## screenshot
<div style="display: inline-block; text-align: center;">
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_4.jpg" width="74%" style="border-radius: 6px;"/>
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_2.png" width="24%" style="border-radius: 6px;"/>
</div>
<div style="display: inline-block; text-align: center;">
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_3.jpg" width="74%" style="border-radius: 6px;"/>
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_5.png" width="25%" style="border-radius: 6px;"/>
</div>
