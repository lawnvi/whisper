// The last picture of recently closed streamed windows, by window title, so
// opening the same window again starts from it instead of a blank window.
// Kept in memory only (a few, small).

#pragma once

#include "frame.h"

#include <memory>
#include <string>

namespace wsn {

std::shared_ptr<const Poster> FindPoster(const std::wstring& title);
void StorePoster(const std::wstring& title, std::shared_ptr<const Poster> poster);

}  // namespace wsn
