#include "my_application.h"
#include "private_tmpdir.h"

int main(int argc, char** argv) {
  use_private_tmpdir();
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
