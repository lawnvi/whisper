// BGRA → NV12 (BT.709, video range) with scaling, on the GPU
// (ID3D11VideoProcessor).
#pragma once

#include "wsn_d3d.h"

#include <map>

namespace wsn {

class Converter {
 public:
  explicit Converter(D3D* d3d) : d3d_(d3d) {}

  // Scales [source_rect] of [source] (BGRA) to fill [target] (NV12, render
  // target). Call with the D3D lock held.
  bool Convert(ID3D11Texture2D* source, const RECT& source_rect, ID3D11Texture2D* target);

  // Forgets cached views of textures that are about to be released.
  void Forget(ID3D11Texture2D* texture);
  void Reset();

 private:
  bool Ensure(UINT in_width, UINT in_height, UINT out_width, UINT out_height);

  D3D* d3d_;
  winrt::com_ptr<ID3D11VideoProcessorEnumerator> enumerator_;
  winrt::com_ptr<ID3D11VideoProcessor> processor_;
  UINT in_width_ = 0, in_height_ = 0, out_width_ = 0, out_height_ = 0;
  std::map<ID3D11Texture2D*, winrt::com_ptr<ID3D11VideoProcessorInputView>> inputs_;
  std::map<ID3D11Texture2D*, winrt::com_ptr<ID3D11VideoProcessorOutputView>> outputs_;
};

// Even dimensions no longer than [max_edge] (0: any) with the aspect of
// [width] x [height]; at least 16 px each.
SIZE EncodedSize(int width, int height, int max_edge);

}  // namespace wsn
