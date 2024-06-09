## Whisper

[中文](./README.md)

Whisper allows you to share text and files between devices on the local network, quickly copying and pasting to each other's clipboards. It's intimate and discreet, just like a whisper.

### Features
- Share text and files between Android, MacOS, Linux, and Windows devices within the local network.
- Notifications from Android devices can be pushed to other connected devices.
- FTP

### How It Works
Whisper is developed using Flutter and establishes a WebSocket connection to communicate with specified devices on the local network.

### Usage Tips
1. Developed using Flutter and Dart, Whisper is a great alternative to using WeChat file transfer assistant.
2. Connections may disconnect and require manual reconnection. In some cases, devices might not be discovered automatically, necessitating manual input of the device's address for connection.
3. The code might not be aesthetically pleasing to everyone, but it gets the job done.
4. Installation on Windows is a bit old-fashioned due to lack of knowledge in packaging. ARM devices may be not supported.
5. While it may not be the most visually appealing or secure option, it serves its purpose for personal use.
6. Large files may not start transferring immediately due to library constraints requiring initial copying to the cache directory. Drag-and-drop functionality on desktop should not encounter this issue.
7. Ensure sufficient storage space on the device before writing files.
8. Supports only text and file messages.
9. Aba aba!

### Installation
[home page](https://2.127014.xyz/whisper)  |  [Latest Release](https://github.com/lawnvi/whisper/releases)  

### Linux Installation
If Avahi is not installed on your Linux system, run the following command:
```shell
sudo apt install -y avahi-daemon avahi-discover avahi-utils libnss-mdns mdns-scan
```

### Screenshots
<div style="display: inline-block; text-align: center;">
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_4.jpg" width="74%" style="border-radius: 6px;"/>
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_2.png" width="24%" style="border-radius: 6px;"/>
</div>
<div style="display: inline-block; text-align: center;">
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_3.jpg" width="74%" style="border-radius: 6px;"/>
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_5.png" width="24%" style="border-radius: 6px;"/>
</div> 

Feel free to reach out if you have any questions or need further assistance with Whisper!