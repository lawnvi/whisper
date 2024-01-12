# whisper

耳鬓厮磨，缱绻旖旎够近了吧  
whisper with u

## 什么用
局域网内两个设备文本/文件收发，快速复制写入对方设备剪切板  
不会访问公网  
支持设备：Android、MacOS、Linux、Windows、ios（仅模拟器测试，没钱）

## 怎么做的
flutter开发，建立websocket，通过局域网指定对方地址与端口连接

## tips
1. 不会dart，不会flutter，就是不想用微信文件传输助手  
2. 水平有限不好看，有些代码只有上帝...也许他也不想看了
3. windows因为不会打包，下载压缩包后放到你想安装的位置再创建exe的快捷方式  
4. linux因为不会打包，下载压缩包后自己创建一下桌面图标  
   创建whisper.desktop，复制到桌面，右键运行，复制到~/.local/share/applications或者/usr/share/applications  
    ```shell
    [Desktop Entry]
    Name=ideaIC  
    Comment=ideaIc
    Exec=path/whisper %U
    Icon=path/icon.png/svg
    Terminal=false
    Type=Application
    Categories=Development;Tools;paper;Application;
    StartupNotify=false
    NoDisplay=false
    ```
5. 阿巴阿巴  

[download⬇](https://github.com/lawnvi/whisper/releases)


## screenshot
![](https://github.com/lawnvi/whisper/blob/dev/.github/image/img_1.png)  
  
![](https://github.com/lawnvi/whisper/blob/dev/.github/image/img.png)