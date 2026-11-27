# 往用户的目录里放文件：不覆盖

Whisper 往用户看得见的目录里放东西的地方有好几处：收到的文件和文件夹、网页传输、放进共享目录、在文件管理器里拖进来、粘贴到某个文件夹、挂载写入时另存一份。它们都要做到一件事：**已经在那里的东西不会被换掉**，名字被占了就换一个。本文说明这件事由谁做、怎么做。

## 两层

**收到的文件**（`/chat` 上的传输、网页传输）走 `lib/socket/verified_file_publisher.dart` 的 `publishVerifiedDownload`：先核对内容的 SHA-256，再把临时文件挪到一个空着的名字上。名字被占了就试下一个，没法原子移动时先独占创建一个占位文件。这一层还管回滚和 Windows 上带着打开的句柄发布（硬链接），所以单独保留。

**其余的**都走 `lib/helper/place_without_overwrite.dart`：

- `moveToFreeName(source, directory, names)`：把一个文件或文件夹挪进 `directory`，用 `names` 里第一个空着的名字；不在同一个卷上时返回 null。
- `placeWithoutOverwrite(source, directory, names, {copy})`：挪不过去（另一个卷；Windows 上有程序开着它）或者要复制时，先复制成目录里的隐藏文件 `.whisper-<随机>.part`，再用同样的办法挪到空着的名字上，最后删掉原件（`copy` 时保留）。复制到一半的文件不会以正式名字出现。原件删不掉就留着，通过 `kept` 告诉调用方。

两层用同一套名字（`spacedNames`、`dashedNames`）和同一个移动（`lib/helper/atomic_file_move.dart` 的 `movePathWithoutOverwrite`）。

## 名字

| 用在哪 | 规则 | 例子 |
|---|---|---|
| 收到的文件、文件夹（`dashedNames`） | 加 `-1`、`-2`；文件夹整个名字后面加 | `report-1.pdf`、`v1.2-1` |
| 放进某个文件夹、拖进来、粘贴（`spacedNames`） | 加空格和从 2 开始的数字 | `report 2.pdf` |
| 挂载写入时对方改过或文件被占用 | 先加设备名，再按上一行 | `report (MacBook).docx`、`report (MacBook) 2.docx` |

名字里带路径分隔符、会跑出目录的直接拒绝。

## 一步完成的移动

以前是先查名字空着，再 `rename`。这中间别的程序放进同名的东西，`rename` 会把它换掉；在 macOS 和 Linux 上，`rename` 一个文件夹到同名的空文件夹上也会直接顶替它。现在由系统一步检查并移动：

- macOS：`renamex_np(RENAME_EXCL)`
- Linux、Android：`renameat2(RENAME_NOREPLACE)`
- Windows：`MoveFileExW` 不带 `MOVEFILE_REPLACE_EXISTING`

文件系统不支持时（部分网络盘和 FUSE，`renameat2` 之前的 Android），退回先查再改名，仍有那一瞬间的空当。

挂载写入在没人改过时**有意**覆盖原文件：那就是"保存"。只有对方改过或者文件被占用时，才另存一份放在旁边。

## 测试

- `test/verified_file_publisher_test.dart` 的"placing never replaces what is already there"：同名文件、同名空文件夹不被换掉，复制保留原件、不留隐藏文件，越出目录的名字被拒绝。
- 挂载写入另存到旁边：`test/remote_files_mount_write_test.dart`。
- 收到的文件夹加后缀：`test/folder_transfer_storage_test.dart`。

没有测试的：真正的竞争（两个程序同时抢一个名字）只能靠系统调用本身的语义；Windows 上的 `MoveFileExW` 路径只做了编译检查，没在 Windows 上跑过；跨卷复制的路径没有自动测试。
