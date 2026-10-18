#include "poster_cache.h"

#include <list>
#include <mutex>
#include <utility>

namespace wsn {
namespace {

constexpr size_t kMaxPosters = 12;

// Leaked on purpose (see common/util.cpp).
std::mutex& g_posters_mutex = *new std::mutex();
std::list<std::pair<std::wstring, std::shared_ptr<const Poster>>>& g_posters =
    *new std::list<std::pair<std::wstring, std::shared_ptr<const Poster>>>();

}  // namespace

std::shared_ptr<const Poster> FindPoster(const std::wstring& title) {
  if (title.empty()) return nullptr;
  std::lock_guard<std::mutex> lock(g_posters_mutex);
  for (auto it = g_posters.begin(); it != g_posters.end(); ++it) {
    if (it->first == title) {
      g_posters.splice(g_posters.begin(), g_posters, it);
      return g_posters.front().second;
    }
  }
  return nullptr;
}

void StorePoster(const std::wstring& title, std::shared_ptr<const Poster> poster) {
  if (title.empty() || poster == nullptr || poster->width <= 0 || poster->height <= 0) return;
  std::lock_guard<std::mutex> lock(g_posters_mutex);
  for (auto it = g_posters.begin(); it != g_posters.end(); ++it) {
    if (it->first == title) {
      g_posters.erase(it);
      break;
    }
  }
  g_posters.emplace_front(title, std::move(poster));
  while (g_posters.size() > kMaxPosters) g_posters.pop_back();
}

}  // namespace wsn
