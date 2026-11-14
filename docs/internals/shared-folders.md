# 共享的目录

2026-11-14 用户定下，同一天改了两次，这是第二版：电脑（macOS、Windows、Linux）按**盘**共享给其他设备浏览，盘里系统相关的目录自动不共享，其他普通目录默认都共享，用户再把不想给的目录排除掉。系统盘默认共享，只共享上面的主目录（Windows 原来同时给主目录和 C 盘，同一批文件出现两次，用户觉得奇怪）；其他磁盘、分区和 U 盘默认不共享，打开就是整块盘。系统目录始终不共享，没有开关。设置对所有设备一样；按设备的「浏览我的文件」「修改我的文件」不变。第一版（常用目录加手动添加的目录、名单制）没有发布，它的设置键 `remote_files.shared_folders` 不再读。

Android 和插数据线时看到的一样：内部存储，加上插着的 SD 卡和 U 盘（`FsPlatform.androidVolumes`，原生是 `FileManagerPlugin` 的 `volumes`，Android 11 起用 `StorageVolume.getDirectory`，之前从 `getExternalFilesDirs` 往上推），种类是 `volume`，名字用系统的叫法（「SD 卡」）。手机没有这些设置。iOS 不变（App 的文稿）。界面规格见 [`docs/design/surfaces.md`「设置」](../design/surfaces.md#设置)。

## 代码在哪

| 文件 | 做什么 |
| --- | --- |
| `lib/remote_files/fs_shared_folders.dart` | `FsSharedFolders`：设置存在 SharedPreferences（`remote_files.share_system_disk`、`remote_files.shared_disks`、`remote_files.excluded_folders`）；算出 `FsSharePolicy`；`exclude` 处理包含关系；`offeredFsRoots` 生成要发给对方的根 |
| `lib/remote_files/fs_share_places.dart` | `fsSystemDisk`、`fsOtherDisks`（都返回 `FsRoot`；Windows 非系统盘符、macOS `mount` 里 `/Volumes` 下本地且不隐藏的卷、Linux `/proc/self/mounts` 里的块设备，去掉系统目录和装着主目录的那块）、`fsSystemFolders`（系统相关的目录）、`fsCommonFolders`（常用目录在哪，给对方的快捷方式用） |
| `lib/remote_files/fs_share_policy.dart` | `FsSharePolicy`（每种用途能不能做，含排除）和 `FsProtectedAreas`（无论怎么设都不给的底线） |
| `lib/remote_files/fs_paths.dart` | `FsPathResolver` 带上 policy：`resolveExisting(use:)`、`resolveEntry`、`resolveNewChild`、`checkChange` |
| `lib/remote_files/fs_host*.dart`、`fs_placement.dart` | 每个请求按用途解析路径；拷进来的文件落地前再查（`FsHostFiles.mayPlace`） |
| `lib/socket/folder_transfer_scan.dart` | `scanFolderInBackground`：文件夹发出去时留下 Whisper 自己的文件（`AppPrivatePaths`，现在是数据库） |
| `lib/new_ui/settings/settings_shared_folders.dart` | 设置里「共享与权限 → 共享的目录」：磁盘和分区的开关、不共享的目录 |

只有主机这一侧受限：`FileBrowseHost.shared` 的 `FsHostFiles(sharing: FileBrowseHost.sharedFolders)`。本机自己的文件页（`LocalFsBrowser`）和调试钩子用不带 policy 的 `FsHostFiles`，照旧看全部；Linux 上它列的盘也来自 `fsOtherDisks`，和设置里的一样。

## 共享什么

`FsSharePolicy.shared` 是打开的盘的根（真实路径）：系统盘是主目录（`FsSharedFolders._systemShare`），其他盘是盘符或挂载点。`excluded` 是两部分：

- **系统相关的**（`fsSystemFolders`，每次算 policy 时现查）：
  - 每块共享的盘最上层：以 `.` 开头的（`.Spotlight-V100`、`.Trashes`…）、Windows 上以 `$` 开头的（`$Recycle.Bin`）和带系统属性的（`System Volume Information`、`pagefile.sys`）、`lost+found`。
  - Windows 每块盘最上层：`Windows`、`Program Files`、`Program Files (x86)`、`ProgramData`、`PerfLogs`、`Recovery`、`Windows.old`、`Config.Msi`、`MSOCache`、`Boot`、`Documents and Settings`、`OneDriveTemp`、`inetpub`。装在 D 盘的 `Program Files` 也算。
  - 主目录旁边别的用户的目录（`C:\Users`、`/Users`、`/home` 里除了自己和 `Public`、`Shared` 的），主目录里 Windows 带系统属性的（`NTUSER.DAT`、旧的 `Application Data` 这类联接）、macOS 的 `~/Applications`、Linux 的 `~/snap`。
- **用户排除的**（`remote_files.excluded_folders`）。

排除只在离它最近的共享根里算（`FsSharePolicy._counts`）：一块盘挂在另一块共享的盘下面时，外面那块的排除管不到它。反过来，没打开的盘挂在共享的目录里（Linux 把分区挂在 `~/data`）也算排除，开关关着就真的不共享。

系统盘只共享主目录：盘的最上层除了系统目录还常有装上去的程序（`C:\Python311`、`C:\xampp`、这台 Mac 的 `/pkg`），认不出是不是用户的；放在那里的东西要共享，就得放进主目录或单独的分区。系统盘上主目录以外的目录不能加进「不共享的目录」（本来就不共享，回 `FsExcluded.already`），排除主目录本身等于关掉系统盘。所以 macOS 和 Linux 的 `/` 不需要系统目录名单，Windows 那份只对另外打开的盘有用（D 盘上的 `Program Files`）。

### 排除和包含关系（`FsSharedFolders.exclude`）

- 已经不共享的（在排除的目录里、系统相关的、底线里的）回 `FsExcluded.already`，不加。
- 包住已有排除项的上层目录：那几项删掉，只留这一条。
- 整块盘：关掉这块盘（`FsExcluded.disk`），不加。
- 别的盘上、那块盘没打开的也照加，以后打开时生效。

## 规则

所有判断都在真实路径上做：`resolveExisting` 先跟随符号链接再判断，列表里的符号链接按它指向的地方判断。所以 `~/Documents` 里指向 `~/.ssh` 的链接打不开，也不出现在列表里。

| 用途（`FsUse`） | 哪些请求 | 要求 |
| --- | --- | --- |
| `read` | `list`、`read`、`thumb`、`stat`、改动的父文件夹 | 在共享的盘里，不在排除的目录里，不在底线里 |
| `copy` | `fetch` | 能读，并且里面不含底线里的地方（主目录本身或它的上层、私有目录、挂载），也不含排除的目录；数据库这类 Whisper 自己的文件由扫描留下 |
| `fill` | `incoming`、新建和移动的目标文件夹 | 能读，不是 git 的控制项 |
| `change` | 写入、新建、重命名、移动（两头）、删除、改时间 | 能读，不是共享的盘根本身，不是 git 的控制项，里面不含排除的目录、底线里的地方、Whisper 自己的文件和挂载（这些都按路径认，上层一改名就脱离规则，一删就跟着没了）；指向不共享地方的符号链接（列表里本来就藏着）也不能动，否则对方能在检查和打开之间把它换到要读的文件的位置上。已经存在的条目再按它的真实路径查一次，换个大小写或 Windows 短名（`GIT~1`）绕不过去 |

**底线**（`FsProtectedAreas`），怎么设都不变：

- 不能读写：主目录里直接以 `.` 开头的条目和它们里面的一切；macOS 的 `~/Library`；Windows 的 `%USERPROFILE%\AppData` 和 `APPDATA`、`LOCALAPPDATA`；Linux 设了的 `XDG_CONFIG_HOME`、`XDG_DATA_HOME`、`XDG_STATE_HOME`、`XDG_CACHE_HOME`；path_provider 给的应用支持和缓存目录；数据库和它旁边的 `-wal`、`-shm`、`-journal`（Linux 和 Windows 上在文稿里，打开时登记到 `AppPrivatePaths`）；别的设备挂在这台上的文件夹（`FsHostFiles.excluded`）。
- 不能写（新建、覆盖、改名成、删除、移走）：`.git` 条目本身（文件夹，或指向别处的 gitfile），`.git` 下面任何一层的 `hooks` 和里面的东西，`.git` 下面的 `config`、`config.worktree`（子模块和工作树有自己的）和 `commondir`（工作树从它指的地方读 config）。git 会自己执行这些，编辑器打开文件夹就会跑 `git status`。把 `.git` 本身也挡住，是因为否则可以先建一个带 `config` 和 `hooks` 的普通文件夹，再改名成 `.git`。
- 比较时先去掉 HFS+ 会忽略的不可见字符，再忽略大小写（`fsFold`），宁可多挡。允许的判断用规范化后的精确路径，宁可少放。

拷进来的文件（`incoming`）先落在下载目录，完成后才搬进选的文件夹。搬之前 `mayPlace` 再按当时的 policy 查一遍目标和整棵树：树里有 `.git` 就不搬，留在下载目录（`TransferPlacements.unplaced`）。

## 发给对方的根

`offeredFsRoots` 发能读的那些地方：主目录（`home`），加上打开了的其他盘，就是设置里列的那些（`fsOtherDisks`：Windows 的盘符是 `drive`，macOS 和 Linux 的是 `volume`，名字用卷名或挂载目录名，同名的编号区分）。系统盘的盘符（C:）不发，它只共享主目录。主目录的常用文件夹是快捷方式，排除了的不发；常用目录被挪到别处的（`fsCommonFolders`：Windows 用 `SHGetKnownFolderPath`，OneDrive 里或 D 盘上的文档；Linux 用 `user-dirs.dirs`）按它的种类挂在最里层含它的根上。

协议没有变：根的种类都是旧版认识的，拒绝都回 `notAllowed`，没有新的错误码。测试：`test/remote_files_protocol_test.dart`「a computer shares whole disks…」和 `test/remote_files_host_test.dart` 的「shared folders」。

## 什么时候生效

- 改了设置：`FsSharedFolders` 立刻重算 policy，下一个请求就按新的来，不用重连。`FsHostFiles` 换 policy 时清掉列表缓存；正在写的文件在 `writeClose` 提交时再查一次。
- 新打开的盘要对方下次 `open` 才看到；挂载要重新挂。
- 每次 `open` 都重读设置、重算系统目录、重新解析路径，U 盘插拔都跟着变。

## 没做到的和没验证的

- 测试只在 macOS 上跑过，用真实文件和符号链接。磁盘识别只用临时用例核对过 `mount` 和 `/proc/self/mounts` 的解析。Windows 的系统属性、已知文件夹、盘符根，Linux 的 XDG 目录和卷，都要真机看；Windows 上靠 Dart 的 `resolveSymbolicLinks`（`GetFinalPathNameByHandle`）把路径规范成长名和真实大小写。
- 系统目录是按名字和系统属性认的。系统盘只给主目录，所以这只影响另外打开的盘：装在 D 盘根上的程序目录（`D:\Games`、`D:\Python`）会当普通目录共享，允许修改时对方能改那里的程序。主目录里的程序（`~/bin`、`AppData` 以外装的）也一样。底线只挡住登录时会自动运行的地方和 git。
- 常用目录被挪到系统盘上主目录以外（`C:\文档`）时不共享。
- 对方拷整个文件夹时，里面有排除的目录就整个拒绝，没有做成跳过那一部分（要把排除项一路传到发送端的扫描）。
- 删除整个含 `.git` 的文件夹（整个仓库）是允许的，这不会让别的东西跑起来。
- 不在 `.git` 名下的裸仓库（`foo.git/config`）不在底线里。
- Linux 上不分大小写的卷（vfat、exfat）：允许判断用精确路径，换大小写的请求会被拒绝而不是放过。
- 设置页没有自动测试（按 AGENTS.md 不写界面测试），预览图用 `test/manual/render_shared_folders.dart` 画。
