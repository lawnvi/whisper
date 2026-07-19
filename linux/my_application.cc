#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "audio_share_plugin.h"
#include "desktop_clipboard_image_plugin.h"
#include "desktop_quick_send_plugin.h"
#include "flutter/generated_plugin_registrant.h"
#include "remote_input_plugin.h"

namespace {

enum class ApplicationLogReason {
  kRegistrationFailed,
};

const char* ApplicationLogReasonName(ApplicationLogReason reason) {
  switch (reason) {
    case ApplicationLogReason::kRegistrationFailed:
      return "registration_failed";
  }
  return "unknown";
}

void LogApplicationWarning(ApplicationLogReason reason) {
  g_warning("event=application_warning reason=%s",
            ApplicationLogReasonName(reason));
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->window));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "whisper");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "whisper");
  }

  gtk_window_set_default_size(window, 1280, 720);
//  gtk_widget_show(GTK_WIDGET(window));
  gtk_widget_realize(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  audio_share_plugin_register(FL_PLUGIN_REGISTRY(view));
  remote_input_plugin_register(FL_PLUGIN_REGISTRY(view));
  desktop_clipboard_image_plugin_register(FL_PLUGIN_REGISTRY(view));
  desktop_quick_send_plugin_register(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::command_line. Secondary launches are forwarded to
// the primary process by GApplication and delivered to the running Dart isolate.
static int my_application_command_line(
    GApplication* application, GApplicationCommandLine* command_line) {
  MyApplication* self = MY_APPLICATION(application);
  if (!g_application_get_is_registered(application)) {
    LogApplicationWarning(ApplicationLogReason::kRegistrationFailed);
    return 1;
  }
  int argument_count = 0;
  gchar** arguments =
      g_application_command_line_get_arguments(command_line, &argument_count);
  char** dart_arguments = argument_count > 1 ? arguments + 1
                                             : arguments + argument_count;
  const DesktopQuickSendEnqueueOutcome quick_send_outcome =
      desktop_quick_send_plugin_emit_arguments(dart_arguments);
  if (self->window == nullptr) {
    g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
    self->dart_entrypoint_arguments =
        quick_send_outcome == DESKTOP_QUICK_SEND_IGNORED
            ? g_strdupv(dart_arguments)
            : g_new0(gchar*, 1);
    g_application_activate(application);
  } else {
    gtk_window_present(self->window);
  }
  g_strfreev(arguments);
  return quick_send_outcome == DESKTOP_QUICK_SEND_REJECTED ? 1 : 0;
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  if (self->window != nullptr) {
    g_object_remove_weak_pointer(
        G_OBJECT(self->window), reinterpret_cast<gpointer*>(&self->window));
    self->window = nullptr;
  }
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_HANDLES_COMMAND_LINE,
                                     nullptr));
}
