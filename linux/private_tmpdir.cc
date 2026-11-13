#include "private_tmpdir.h"

#include <errno.h>
#include <glib.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <cstdlib>

// Whisper and its plugins keep pasted files, screenshots and an unpacked
// libopus (which is then loaded) in the temporary folder. In a shared /tmp,
// another local user could read those, or put a library there first and have
// it loaded as this user. So the folder is /tmp/whisper-<uid>, made 0700 and
// checked to be ours; if someone else holds that name, a random one is used.
void use_private_tmpdir() {
  const gchar* current = g_getenv("TMPDIR");
  if (current != nullptr && current[0] != '\0') {
    return;
  }
  const uid_t uid = getuid();
  g_autofree gchar* path = g_strdup_printf("/tmp/whisper-%u", (unsigned)uid);
  struct stat info;
  if ((mkdir(path, 0700) == 0 || errno == EEXIST) &&
      lstat(path, &info) == 0 && S_ISDIR(info.st_mode) &&
      info.st_uid == uid && (info.st_mode & 0077) == 0) {
    g_setenv("TMPDIR", path, TRUE);
    return;
  }
  g_autofree gchar* fresh =
      g_strdup_printf("/tmp/whisper-%u-XXXXXX", (unsigned)uid);
  if (mkdtemp(fresh) != nullptr) {
    g_setenv("TMPDIR", fresh, TRUE);
  }
}
