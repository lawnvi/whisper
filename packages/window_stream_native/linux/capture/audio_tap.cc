#include "capture/audio_tap.h"

#include "common/log.h"

#ifdef WSN_HAVE_PIPEWIRE_HEADERS

#include <dirent.h>
#include <glib.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/dict.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "capture/pipewire_core.h"
#include "common/callbacks.h"
#include "window_stream_native.h"

namespace wsn::capture {

namespace {

using pwcore::Pw;

constexpr int kRate = 48000;
constexpr int kChannels = 2;
constexpr uint32_t kMaxChunkFrames = 1920;  // 40 ms
constexpr size_t kMaxListeners = 8;          // captures of one app at once
constexpr const char* kTargetKey = "target.object";

const char* Prop(const spa_dict* props, const char* key) {
  return props != nullptr ? spa_dict_lookup(props, key) : nullptr;
}

uint32_t PropU32(const spa_dict* props, const char* key, uint32_t fallback = 0) {
  const char* value = Prop(props, key);
  return value != nullptr ? static_cast<uint32_t>(std::strtoul(value, nullptr, 10)) : fallback;
}

std::string JournalPath() {
  const char* state = g_get_user_state_dir();
  return std::string(state) + "/whisper/linux-audio-routes";
}

// The processes of `root`'s app scope (GNOME starts each app in a systemd
// scope of its own, app-gnome-<app>-<pid>.scope, and everything the app
// starts stays in it, double-forked helpers included), when that scope is
// the app's alone.
std::vector<int> AppScopeMembers(int root) {
  std::vector<int> members;
  char path[64];
  std::snprintf(path, sizeof(path), "/proc/%d/cgroup", root);
  std::ifstream in(path);
  std::string line;
  std::string group;
  while (std::getline(in, line)) {
    if (line.rfind("0::", 0) == 0) group = line.substr(3);
  }
  size_t slash = group.rfind('/');
  if (slash == std::string::npos) return members;
  std::string leaf = group.substr(slash + 1);
  bool scope = group.find("/app.slice/") != std::string::npos &&
               leaf.size() > 6 && leaf.compare(leaf.size() - 6, 6, ".scope") == 0;
  bool app_service = leaf.rfind("app-", 0) == 0 && leaf.size() > 8 &&
                     leaf.compare(leaf.size() - 8, 8, ".service") == 0;
  if (!scope && !app_service) return members;  // shared (D-Bus activated, a session)
  std::ifstream procs("/sys/fs/cgroup" + group + "/cgroup.procs");
  int pid = 0;
  while (procs >> pid) members.push_back(pid);
  return members;
}

// Every process whose parent chain reaches `root` (the window's app and what
// it spawned), from /proc, plus the rest of its app scope.
std::set<int> ProcessTree(int root) {
  std::map<int, std::vector<int>> children;
  DIR* proc = opendir("/proc");
  if (proc != nullptr) {
    while (dirent* entry = readdir(proc)) {
      int pid = std::atoi(entry->d_name);
      if (pid <= 0) continue;
      char path[64];
      std::snprintf(path, sizeof(path), "/proc/%d/stat", pid);
      FILE* file = std::fopen(path, "r");
      if (file == nullptr) continue;
      char buffer[512];
      size_t read = std::fread(buffer, 1, sizeof(buffer) - 1, file);
      std::fclose(file);
      buffer[read] = '\0';
      // pid (comm) state ppid ...; comm may hold spaces and parentheses.
      const char* close = std::strrchr(buffer, ')');
      if (close == nullptr) continue;
      int ppid = 0;
      char state = 0;
      if (std::sscanf(close + 1, " %c %d", &state, &ppid) == 2) children[ppid].push_back(pid);
    }
    closedir(proc);
  }
  std::set<int> tree;
  std::vector<int> pending = {root};
  for (int member : AppScopeMembers(root)) pending.push_back(member);
  while (!pending.empty()) {
    int pid = pending.back();
    pending.pop_back();
    if (!tree.insert(pid).second) continue;
    for (int child : children[pid]) pending.push_back(child);
  }
  return tree;
}

struct Node {
  uint32_t serial = 0;
  uint32_t client = 0;
  int pid = -1;  // from the node's own properties, else from its client
  std::string media_class;
  std::string name;
};

struct Port {
  uint32_t node = 0;
  bool output = false;
  std::string channel;
};

struct Link {
  uint32_t output_node = 0;
  uint32_t input_node = 0;
};

class Tap;
std::map<int, std::unique_ptr<Tap>>& Taps();
void ApplyAll();

// What the PipeWire graph holds (nodes, ports, clients, default metadata),
// mirrored from the registry on the PipeWire thread. One per connection.
class Graph {
 public:
  static Graph* Get();

  std::map<uint32_t, Node> nodes;
  std::map<uint32_t, Port> ports;
  std::map<uint32_t, Link> links;
  std::map<uint32_t, int> client_pids;

  bool Linked(uint32_t from, uint32_t to) const {
    for (const auto& [id, link] : links) {
      if (link.output_node == from && link.input_node == to) return true;
    }
    return false;
  }

  // Linked somewhere other than `except` (WirePlumber has placed it).
  bool LinkedElsewhere(uint32_t from, uint32_t except) const {
    for (const auto& [id, link] : links) {
      if (link.output_node == from && link.input_node != except) return true;
    }
    return false;
  }
  std::map<uint32_t, std::string> targets;  // metadata subject → target.object
  bool synced = false;

  int PidOf(const Node& node) const {
    if (node.pid > 0) return node.pid;
    auto client = client_pids.find(node.client);
    return client != client_pids.end() ? client->second : -1;
  }

  bool CanRoute() const { return metadata_ != nullptr; }

  void SetTarget(uint32_t subject, const std::string* value) {
    if (metadata_ == nullptr) return;
    pw_metadata_set_property(metadata_, subject, kTargetKey, nullptr, value != nullptr ? value->c_str() : nullptr);
  }

  pw_core* core() const { return core_; }
  uint64_t generation() const { return generation_; }

 private:
  friend Graph* EnsureGraph(pw_core* core);

  explicit Graph(pw_core* core) : core_(core), generation_(pwcore::Generation()) {
    registry_ = pw_core_get_registry(core_, PW_VERSION_REGISTRY, 0);
    static const pw_registry_events registry_events = [] {
      pw_registry_events e = {};
      e.version = PW_VERSION_REGISTRY_EVENTS;
      e.global = [](void* data, uint32_t id, uint32_t, const char* type, uint32_t, const spa_dict* props) {
        static_cast<Graph*>(data)->OnGlobal(id, type, props);
      };
      e.global_remove = [](void* data, uint32_t id) { static_cast<Graph*>(data)->OnGlobalRemove(id); };
      return e;
    }();
    pw_registry_add_listener(registry_, &registry_listener_, &registry_events, this);
    static const pw_core_events core_events = [] {
      pw_core_events e = {};
      e.version = PW_VERSION_CORE_EVENTS;
      e.done = [](void* data, uint32_t id, int seq) { static_cast<Graph*>(data)->OnDone(id, seq); };
      return e;
    }();
    pw_core_add_listener(core_, &core_listener_, &core_events, this);
    sync_seq_ = pw_core_sync(core_, PW_ID_CORE, 0);
  }

  void OnGlobal(uint32_t id, const char* type, const spa_dict* props) {
    if (std::strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
      Node node;
      node.serial = PropU32(props, PW_KEY_OBJECT_SERIAL);
      node.client = PropU32(props, PW_KEY_CLIENT_ID);
      const char* pid = Prop(props, PW_KEY_APP_PROCESS_ID);
      node.pid = pid != nullptr ? std::atoi(pid) : -1;
      const char* media_class = Prop(props, PW_KEY_MEDIA_CLASS);
      node.media_class = media_class != nullptr ? media_class : "";
      const char* name = Prop(props, PW_KEY_NODE_NAME);
      node.name = name != nullptr ? name : "";
      nodes[id] = node;
      // The registry shows only some of a node's properties; the process of
      // a PulseAudio client's stream is in the full set.
      if (node.media_class == "Stream/Output/Audio" && node.pid <= 0) Watch(id);
      ApplyAll();
    } else if (std::strcmp(type, PW_TYPE_INTERFACE_Port) == 0) {
      Port port;
      port.node = PropU32(props, PW_KEY_NODE_ID);
      const char* direction = Prop(props, PW_KEY_PORT_DIRECTION);
      port.output = direction != nullptr && std::strcmp(direction, "out") == 0;
      const char* channel = Prop(props, PW_KEY_AUDIO_CHANNEL);
      port.channel = channel != nullptr ? channel : "";
      ports[id] = port;
      ApplyAll();
    } else if (std::strcmp(type, PW_TYPE_INTERFACE_Link) == 0) {
      Link link;
      link.output_node = PropU32(props, PW_KEY_LINK_OUTPUT_NODE);
      link.input_node = PropU32(props, PW_KEY_LINK_INPUT_NODE);
      links[id] = link;
      ApplyAll();
    } else if (std::strcmp(type, PW_TYPE_INTERFACE_Client) == 0) {
      // The process the client claims, else the one PipeWire saw connect.
      const char* pid = Prop(props, PW_KEY_APP_PROCESS_ID);
      if (pid == nullptr) pid = Prop(props, PW_KEY_SEC_PID);
      client_pids[id] = pid != nullptr ? std::atoi(pid) : -1;
    } else if (std::strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0 && metadata_ == nullptr) {
      const char* name = Prop(props, PW_KEY_METADATA_NAME);
      if (name == nullptr || std::strcmp(name, "default") != 0) return;
      metadata_ = static_cast<pw_metadata*>(pw_registry_bind(registry_, id, type, PW_VERSION_METADATA, 0));
      static const pw_metadata_events metadata_events = [] {
        pw_metadata_events e = {};
        e.version = PW_VERSION_METADATA_EVENTS;
        e.property = [](void* data, uint32_t subject, const char* key, const char*, const char* value) -> int {
          auto* graph = static_cast<Graph*>(data);
          if (key == nullptr) {
            graph->targets.erase(subject);  // all keys of the subject cleared
          } else if (std::strcmp(key, kTargetKey) == 0) {
            if (value == nullptr) {
              graph->targets.erase(subject);
            } else {
              graph->targets[subject] = value;
            }
          }
          return 0;
        };
        return e;
      }();
      pw_metadata_add_listener(metadata_, &metadata_listener_, &metadata_events, this);
    }
  }

  void OnGlobalRemove(uint32_t id) {
    auto watched = watched_.find(id);
    if (watched != watched_.end()) {
      spa_hook_remove(&watched->second->listener);
      Pw().proxy_destroy(reinterpret_cast<pw_proxy*>(watched->second->node));
      watched_.erase(watched);
    }
    nodes.erase(id);
    ports.erase(id);
    links.erase(id);
    client_pids.erase(id);
    ApplyAll();
  }

  void OnDone(uint32_t id, int seq) {
    if (id != PW_ID_CORE || seq != sync_seq_) return;
    if (!bound_round_done_) {
      // The metadata was bound during the first round trip; one more for its
      // current properties.
      bound_round_done_ = true;
      sync_seq_ = pw_core_sync(core_, PW_ID_CORE, 0);
      return;
    }
    synced = true;
    Recover();
    ApplyAll();
  }

  void Recover();

  struct Watched {
    Graph* graph = nullptr;
    uint32_t id = 0;
    pw_node* node = nullptr;
    spa_hook listener = {};
  };

  void Watch(uint32_t id) {
    if (watched_.count(id) != 0) return;
    auto watched = std::make_unique<Watched>();
    watched->graph = this;
    watched->id = id;
    watched->node = static_cast<pw_node*>(pw_registry_bind(registry_, id, PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0));
    if (watched->node == nullptr) return;
    static const pw_node_events events = [] {
      pw_node_events e = {};
      e.version = PW_VERSION_NODE_EVENTS;
      e.info = [](void* data, const pw_node_info* info) {
        auto* w = static_cast<Watched*>(data);
        const char* pid = info != nullptr ? Prop(info->props, PW_KEY_APP_PROCESS_ID) : nullptr;
        auto node = w->graph->nodes.find(w->id);
        if (pid != nullptr && node != w->graph->nodes.end() && node->second.pid <= 0) {
          node->second.pid = std::atoi(pid);
          ApplyAll();
        }
      };
      return e;
    }();
    pw_node_add_listener(watched->node, &watched->listener, &events, watched.get());
    watched_[id] = std::move(watched);
  }

  std::map<uint32_t, std::unique_ptr<Watched>> watched_;
  pw_core* core_;
  uint64_t generation_;
  pw_registry* registry_ = nullptr;
  pw_metadata* metadata_ = nullptr;
  spa_hook registry_listener_ = {};
  spa_hook core_listener_ = {};
  spa_hook metadata_listener_ = {};
  int sync_seq_ = 0;
  bool bound_round_done_ = false;
};

Graph* g_graph = nullptr;
Graph* EnsureGraph(pw_core* core);

// The current graph, or null while it belongs to a connection that is gone.
// Never makes one: PipeWire callbacks call this.
Graph* CurrentGraph() {
  return g_graph != nullptr && g_graph->generation() == pwcore::Generation() ? g_graph : nullptr;
}

// Capture thread, with the loop locked by LockCore (`core` its result).
Graph* Graph::Get() { return CurrentGraph(); }

Graph* EnsureGraph(pw_core* core) {
  // A new connection (PipeWire restarted): everything made on the old one
  // is gone with it (the old mirror is left behind, its proxies died).
  if (CurrentGraph() == nullptr) g_graph = new Graph(core);
  return g_graph;
}

// One app's sound, for every capture of its windows.
class Tap {
 public:
  explicit Tap(int root) : root_(root) {
    char name[64];
    std::snprintf(name, sizeof(name), "whisper-window-audio-%d-%d", static_cast<int>(getpid()), root);
    sink_name_ = name;
  }

  ~Tap() { Release(); }

  // Captures that want this app's sound, and how (1 also here, 2 only
  // there). Changed with the loop lock held; the PipeWire data thread reads
  // the copy in emit_to_.
  std::map<int64_t, int> listeners;

  void SetListener(int64_t capture, int mode) {
    if (mode <= 0) {
      listeners.erase(capture);
    } else {
      listeners[capture] = mode;
    }
    std::lock_guard<std::mutex> lock(emit_mutex_);
    emit_count_ = 0;
    for (const auto& [id, wanted] : listeners) {
      if (wanted > 0 && emit_count_ < kMaxListeners) emit_to_[emit_count_++] = id;
    }
  }

  int Wanted() const {
    int wanted = 0;
    for (const auto& [capture, mode] : listeners) wanted = std::max(wanted, mode);
    return wanted;
  }

  // Brings the graph in line with what the listeners want.
  void Apply() {
    Graph* graph = Graph::Get();
    if (graph == nullptr || !graph->synced) return;
    if (generation_ != graph->generation()) {
      // Made on a connection that is gone: start over on this one.
      Forget();
      generation_ = graph->generation();
    }
    int wanted = Wanted();
    if (wanted == 0) {
      Release();
      return;
    }
    if (sink_proxy_ == nullptr) CreateSink(graph);
    // Our sink, as the registry shows it.
    if (sink_id_ == 0) {
      for (const auto& [id, node] : graph->nodes) {
        if (node.name == sink_name_) {
          sink_id_ = id;
          sink_serial_ = node.serial;
        }
      }
      if (sink_id_ == 0) return;  // not there yet; the registry will call again
    }
    if (stream_ == nullptr) Connect(graph);

    int64_t now = g_get_monotonic_time();
    std::set<uint32_t> app_nodes;
    bool tree_fresh = now - tree_at_ < 2 * G_USEC_PER_SEC;
    for (const auto& [id, node] : graph->nodes) {
      if (node.media_class != "Stream/Output/Audio") continue;
      int pid = graph->PidOf(node);
      if (pid <= 0 || pid == static_cast<int>(getpid())) continue;
      if (tree_.count(pid) == 0 && !tree_fresh) {
        tree_ = ProcessTree(root_);
        tree_at_ = now;
        tree_fresh = true;
      }
      if (tree_.count(pid) != 0) app_nodes.insert(id);
    }

    bool silent = wanted >= 2 && graph->CanRoute();
    std::string sink_value = std::to_string(sink_serial_);
    for (uint32_t id : app_nodes) {
      const Node& node = graph->nodes.at(id);
      if (silent) {
        DropLinks(id);
        if (moved_.count(id) == 0) {
          Moved moved;
          moved.serial = node.serial;
          auto previous = graph->targets.find(id);
          moved.had_previous = previous != graph->targets.end();
          if (moved.had_previous) moved.previous = previous->second;
          moved_[id] = moved;
          graph->SetTarget(id, &sink_value);
          SaveJournal();
        }
      } else {
        Restore(graph, id);
        LinkToSink(graph, id);
      }
    }
    // Moved streams that went away need nothing back; forget them.
    for (auto it = moved_.begin(); it != moved_.end();) {
      if (graph->nodes.count(it->first) == 0) {
        it = moved_.erase(it);
        SaveJournal();
      } else {
        ++it;
      }
    }
    for (auto it = links_.begin(); it != links_.end();) {
      if (graph->nodes.count(it->first) == 0) {
        for (pw_proxy* link : it->second) Pw().proxy_destroy(link);
        it = links_.erase(it);
      } else {
        ++it;
      }
    }

    std::string state = std::to_string(app_nodes.size()) + (silent ? "s" : "l");
    if (state != noted_state_) {
      noted_state_ = state;
      std::string text;
      if (app_nodes.empty()) {
        text = "audio: on; the app plays no sound yet";
      } else if (silent) {
        text = "audio: " + std::to_string(app_nodes.size()) +
               " stream(s) of the app captured and silenced here (moved to Whisper's sink)";
      } else {
        text = "audio: " + std::to_string(app_nodes.size()) + " stream(s) of the app captured";
        if (wanted >= 2) text += "; could not silence here (no PipeWire default metadata)";
      }
      for (const auto& [capture, mode] : listeners) EmitCaptureNote(capture, text);
    }
  }

  // Lets go of everything: routes back, links and the sink gone.
  void Release() {
    Graph* graph = g_graph;
    if (graph != nullptr && graph->generation() == generation_) {
      for (auto it = moved_.begin(); it != moved_.end();) {
        uint32_t id = it->first;
        ++it;
        Restore(graph, id);
      }
      for (auto& [node, links] : links_) {
        for (pw_proxy* link : links) Pw().proxy_destroy(link);
      }
      if (stream_ != nullptr) {
        spa_hook_remove(&stream_listener_);
        Pw().stream_disconnect(stream_);
        Pw().stream_destroy(stream_);
      }
      // The routes are back first: removed under them, the streams would
      // fall back to the default sink instead of their own target.
      if (sink_proxy_ != nullptr) Pw().proxy_destroy(sink_proxy_);
    }
    links_.clear();
    moved_.clear();
    stream_ = nullptr;
    sink_proxy_ = nullptr;
    sink_id_ = 0;
    sink_serial_ = 0;
    noted_state_.clear();
    SaveJournal();
  }

  const std::map<uint32_t, uint32_t> MovedSerials() const {
    std::map<uint32_t, uint32_t> serials;
    for (const auto& [id, moved] : moved_) serials[id] = moved.serial;
    return serials;
  }

  void AppendJournal(std::ostringstream* out) const {
    for (const auto& [id, moved] : moved_) {
      *out << id << ' ' << moved.serial << ' ' << sink_serial_ << ' ' << (moved.had_previous ? 1 : 0) << ' '
           << (moved.had_previous ? moved.previous : "-") << '\n';
    }
  }

 private:
  struct Moved {
    uint32_t serial = 0;
    bool had_previous = false;
    std::string previous;
  };

  // Objects of a dead connection: dropped without touching them.
  void Forget() {
    links_.clear();
    moved_.clear();
    stream_ = nullptr;
    sink_proxy_ = nullptr;
    sink_id_ = 0;
    sink_serial_ = 0;
  }

  void CreateSink(Graph* graph) {
    std::string description = "Whisper window stream";
    spa_dict_item items[] = {
        SPA_DICT_ITEM_INIT("factory.name", "support.null-audio-sink"),
        SPA_DICT_ITEM_INIT(PW_KEY_NODE_NAME, sink_name_.c_str()),
        SPA_DICT_ITEM_INIT(PW_KEY_NODE_DESCRIPTION, description.c_str()),
        SPA_DICT_ITEM_INIT(PW_KEY_MEDIA_CLASS, "Audio/Sink"),
        SPA_DICT_ITEM_INIT("audio.position", "FL,FR"),
        SPA_DICT_ITEM_INIT("audio.rate", "48000"),
        // Gone with this process (or its connection); never a default choice.
        SPA_DICT_ITEM_INIT(PW_KEY_OBJECT_LINGER, "false"),
        SPA_DICT_ITEM_INIT(PW_KEY_NODE_VIRTUAL, "true"),
        SPA_DICT_ITEM_INIT("priority.session", "0"),
        SPA_DICT_ITEM_INIT("priority.driver", "0"),
    };
    spa_dict dict = SPA_DICT_INIT_ARRAY(items);
    sink_proxy_ = static_cast<pw_proxy*>(
        pw_core_create_object(graph->core(), "adapter", PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, &dict, 0));
    if (sink_proxy_ == nullptr) WSN_LOG("capture: audio sink could not be created");
  }

  void Connect(Graph* graph) {
    const pwcore::Api& pw = Pw();
    stream_ = pw.stream_new(
        graph->core(), "Whisper window audio",
        pw.properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture", PW_KEY_MEDIA_ROLE, "Music",
                          PW_KEY_NODE_NAME, "whisper-window-audio-capture", PW_KEY_TARGET_OBJECT, sink_name_.c_str(),
                          PW_KEY_STREAM_CAPTURE_SINK, "true", PW_KEY_NODE_LATENCY, "960/48000",
                          // Never the microphone, should the sink go away.
                          PW_KEY_NODE_DONT_RECONNECT, "true", "node.dont-fallback", "true", nullptr));
    if (stream_ == nullptr) return;
    static const pw_stream_events events = [] {
      pw_stream_events e = {};
      e.version = PW_VERSION_STREAM_EVENTS;
      e.process = [](void* data) { static_cast<Tap*>(data)->OnProcess(); };
      return e;
    }();
    pw.stream_add_listener(stream_, &stream_listener_, &events, this);
    uint8_t buffer[512];
    spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    spa_audio_info_raw info = {};
    info.format = SPA_AUDIO_FORMAT_S16_LE;
    info.rate = kRate;
    info.channels = kChannels;
    info.position[0] = SPA_AUDIO_CHANNEL_FL;
    info.position[1] = SPA_AUDIO_CHANNEL_FR;
    const spa_pod* params[1] = {spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info)};
    // Processed on PipeWire's data thread, not the shared loop thread: the
    // loop thread also takes every video frame and the registry, and at a
    // small graph quantum (5 ms when the app asks for low latency) any wait
    // there lost whole buffers of sound.
    int result = pw.stream_connect(stream_, SPA_DIRECTION_INPUT, PW_ID_ANY,
                                   static_cast<pw_stream_flags>(PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS |
                                                                PW_STREAM_FLAG_RT_PROCESS),
                                   params, 1);
    if (result < 0) WSN_LOG("capture: audio capture stream failed to connect (%d)", result);
  }

  // PipeWire data thread. Takes every buffer that is ready, oldest first.
  void OnProcess() {
    const pwcore::Api& pw = Pw();
    int64_t targets[kMaxListeners];
    size_t count = 0;
    {
      std::lock_guard<std::mutex> lock(emit_mutex_);
      count = emit_count_;
      std::copy(emit_to_, emit_to_ + count, targets);
    }
    while (pw_buffer* buffer = pw.stream_dequeue_buffer(stream_)) {
      if (count > 0) Emit(buffer->buffer, targets, count);
      pw.stream_queue_buffer(stream_, buffer);
    }
  }

  void Emit(spa_buffer* spa, const int64_t* targets, size_t target_count) {
    if (spa->n_datas > 0 && spa->datas[0].data != nullptr && spa->datas[0].chunk != nullptr) {
      spa_data& data = spa->datas[0];
      uint32_t offset = std::min(data.chunk->offset, data.maxsize);
      uint32_t size = std::min(data.chunk->size, data.maxsize - offset);
      const auto* samples = reinterpret_cast<const int16_t*>(static_cast<const uint8_t*>(data.data) + offset);
      uint32_t frames = size / (kChannels * sizeof(int16_t));
      bool sound = std::any_of(samples, samples + frames * kChannels, [](int16_t s) { return s != 0; });
      // Digital silence (paused, nothing playing) is left out: a gap.
      if (frames > 0 && sound) {
        // On the video's clock (monotonic), and contiguous: each chunk starts
        // where the last ended, unless the clocks drifted apart or sound
        // stopped for a while (then a fresh start, leaving a gap).
        int64_t now_pts = g_get_monotonic_time() - static_cast<int64_t>(frames) * G_USEC_PER_SEC / kRate;
        int64_t pts = next_pts_ != 0 && std::llabs(now_pts - next_pts_) < 40000 ? next_pts_ : now_pts;
        next_pts_ = pts + static_cast<int64_t>(frames) * G_USEC_PER_SEC / kRate;
        for (uint32_t done = 0; done < frames;) {
          uint32_t count = std::min(kMaxChunkFrames, frames - done);
          size_t bytes = static_cast<size_t>(count) * kChannels * sizeof(int16_t);
          int64_t chunk_pts = pts + static_cast<int64_t>(done) * G_USEC_PER_SEC / kRate;
          for (size_t i = 0; i < target_count; i++) {
            auto* copy = static_cast<uint8_t*>(std::malloc(bytes));
            if (copy == nullptr) continue;
            std::memcpy(copy, samples + static_cast<size_t>(done) * kChannels, bytes);
            EmitCaptureOwned(targets[i], WSN_CAPTURE_AUDIO, copy, static_cast<int32_t>(bytes), chunk_pts, 0, kRate,
                             kChannels);
          }
          done += count;
        }
      }
    }
  }

  void Restore(Graph* graph, uint32_t id) {
    auto it = moved_.find(id);
    if (it == moved_.end()) return;
    // Back exactly: its own earlier choice, or none (WirePlumber's default).
    if (it->second.had_previous) {
      graph->SetTarget(id, &it->second.previous);
    } else {
      graph->SetTarget(id, nullptr);
    }
    moved_.erase(it);
    SaveJournal();
  }

  void DropLinks(uint32_t id) {
    auto it = links_.find(id);
    if (it == links_.end()) return;
    for (pw_proxy* link : it->second) Pw().proxy_destroy(link);
    links_.erase(it);
  }

  // Mode 1: the app's own routing stays; its outputs also feed our sink.
  // WirePlumber drops other links when it moves a stream (back from mode 2,
  // say): links that are not in the graph a moment after they were made are
  // made again.
  void LinkToSink(Graph* graph, uint32_t id) {
    if (graph->Linked(id, sink_id_)) return;
    // Wait until WirePlumber has (re)placed the stream: links made before
    // that are dropped by its move.
    if (!graph->LinkedElsewhere(id, sink_id_)) return;
    auto made = links_made_.find(id);
    if (links_.count(id) != 0 && made != links_made_.end() &&
        g_get_monotonic_time() - made->second < 500 * 1000) {
      return;  // on their way
    }
    DropLinks(id);
    std::map<std::string, uint32_t> sink_inputs;
    std::vector<std::pair<uint32_t, std::string>> outputs;
    for (const auto& [port_id, port] : graph->ports) {
      if (port.node == sink_id_ && !port.output) sink_inputs[port.channel] = port_id;
      if (port.node == id && port.output) outputs.emplace_back(port_id, port.channel);
    }
    if (sink_inputs.count("FL") == 0 || sink_inputs.count("FR") == 0 || outputs.empty()) return;  // ports to come
    std::vector<pw_proxy*> links;
    auto link = [&](uint32_t out_port, uint32_t in_port) {
      std::string out_node = std::to_string(id);
      std::string out = std::to_string(out_port);
      std::string in_node = std::to_string(sink_id_);
      std::string in = std::to_string(in_port);
      spa_dict_item items[] = {
          SPA_DICT_ITEM_INIT(PW_KEY_LINK_OUTPUT_NODE, out_node.c_str()),
          SPA_DICT_ITEM_INIT(PW_KEY_LINK_OUTPUT_PORT, out.c_str()),
          SPA_DICT_ITEM_INIT(PW_KEY_LINK_INPUT_NODE, in_node.c_str()),
          SPA_DICT_ITEM_INIT(PW_KEY_LINK_INPUT_PORT, in.c_str()),
          SPA_DICT_ITEM_INIT(PW_KEY_OBJECT_LINGER, "false"),
      };
      spa_dict dict = SPA_DICT_INIT_ARRAY(items);
      auto* proxy = static_cast<pw_proxy*>(
          pw_core_create_object(graph->core(), "link-factory", PW_TYPE_INTERFACE_Link, PW_VERSION_LINK, &dict, 0));
      if (proxy != nullptr) links.push_back(proxy);
    };
    for (const auto& [port, channel] : outputs) {
      // Left and right as they are; mono and centre to both; the rest to
      // their side.
      bool left = channel == "FL" || channel == "RL" || channel == "SL";
      bool right = channel == "FR" || channel == "RR" || channel == "SR";
      bool both = channel == "MONO" || channel == "FC" || channel.empty();
      if (left || both) link(port, sink_inputs["FL"]);
      if (right || both) link(port, sink_inputs["FR"]);
    }
    links_[id] = std::move(links);
    links_made_[id] = g_get_monotonic_time();
  }

  static void SaveJournal();

  int root_;
  uint64_t generation_ = 0;
  std::string sink_name_;
  pw_proxy* sink_proxy_ = nullptr;
  uint32_t sink_id_ = 0;
  uint32_t sink_serial_ = 0;
  pw_stream* stream_ = nullptr;
  spa_hook stream_listener_ = {};
  std::map<uint32_t, Moved> moved_;
  std::map<uint32_t, std::vector<pw_proxy*>> links_;
  std::map<uint32_t, int64_t> links_made_;
  std::set<int> tree_;
  int64_t tree_at_ = 0;
  std::string noted_state_;
  int64_t next_pts_ = 0;  // where the next chunk continues (PipeWire data thread)
  std::mutex emit_mutex_;
  int64_t emit_to_[kMaxListeners] = {};
  size_t emit_count_ = 0;
};

std::map<int, std::unique_ptr<Tap>>& Taps() {
  static auto* taps = new std::map<int, std::unique_ptr<Tap>>();
  return *taps;
}

void ApplyAll() {
  for (auto& [pid, tap] : Taps()) tap->Apply();
}

// The streams moved right now, written down so that a run that dies leaves
// a way back for the next one.
void Tap::SaveJournal() {
  std::ostringstream out;
  for (const auto& [pid, tap] : Taps()) tap->AppendJournal(&out);
  std::string path = JournalPath();
  std::string text = out.str();
  if (text.empty()) {
    unlink(path.c_str());
    return;
  }
  gchar* dir = g_path_get_dirname(path.c_str());
  g_mkdir_with_parents(dir, 0700);
  g_free(dir);
  g_file_set_contents(path.c_str(), text.c_str(), static_cast<gssize>(text.size()), nullptr);
}

void Graph::Recover() {
  std::ifstream in(JournalPath());
  if (!in) return;
  std::string line;
  int restored = 0;
  while (std::getline(in, line)) {
    std::istringstream fields(line);
    uint32_t id = 0, serial = 0, sink = 0;
    int had_previous = 0;
    std::string previous;
    if (!(fields >> id >> serial >> sink >> had_previous >> previous)) continue;
    auto node = nodes.find(id);
    auto target = targets.find(id);
    // Still the same stream, still pointing at a sink of that run: back.
    if (node == nodes.end() || node->second.serial != serial || target == targets.end() ||
        target->second != std::to_string(sink)) {
      continue;
    }
    SetTarget(id, had_previous != 0 ? &previous : nullptr);
    restored++;
  }
  in.close();
  unlink(JournalPath().c_str());
  if (restored > 0) WSN_LOG("capture: put back %d audio route(s) an earlier run left moved", restored);
}

}  // namespace

void SetAudio(int64_t capture, int pid, int mode) {
  if (!Pw().ok) return;
  pw_core* core = pwcore::LockCore();
  if (core == nullptr) return;
  Graph* graph = EnsureGraph(core);
  auto& taps = Taps();
  // Off everywhere else first (a capture follows one app).
  for (auto it = taps.begin(); it != taps.end();) {
    bool mine = it->first == pid;
    if (!mine || mode <= 0) it->second->SetListener(capture, 0);
    if (it->second->listeners.empty()) {
      it = taps.erase(it);  // ~Tap puts everything back
    } else {
      ++it;
    }
  }
  if (mode > 0 && pid > 0 && pid != static_cast<int>(getpid()) && graph != nullptr) {
    auto& tap = taps[pid];
    if (tap == nullptr) tap = std::make_unique<Tap>(pid);
    tap->SetListener(capture, std::min(mode, 2));
    tap->Apply();
  }
  pwcore::Unlock();
}

void RecoverAudioRoutes() {
  if (!Pw().ok) return;
  pw_core* core = pwcore::LockCore();
  if (core == nullptr) return;
  EnsureGraph(core);  // recovery runs once its first sync completes
  pwcore::Unlock();
}

}  // namespace wsn::capture

#else  // !WSN_HAVE_PIPEWIRE_HEADERS

namespace wsn::capture {

void SetAudio(int64_t, int, int) {}
void RecoverAudioRoutes() {}

}  // namespace wsn::capture

#endif
