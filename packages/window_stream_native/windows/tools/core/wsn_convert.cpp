#include "wsn_convert.h"

#include <algorithm>
#include <cmath>

namespace wsn {

SIZE EncodedSize(int width, int height, int max_edge) {
  double w = std::max(width, 16);
  double h = std::max(height, 16);
  double longest = std::max(w, h);
  if (max_edge > 0 && longest > max_edge) {
    w = w * max_edge / longest;
    h = h * max_edge / longest;
  }
  LONG out_w = std::max<LONG>(16, static_cast<LONG>(std::lround(w)) & ~1L);
  LONG out_h = std::max<LONG>(16, static_cast<LONG>(std::lround(h)) & ~1L);
  return SIZE{out_w, out_h};
}

void Converter::Forget(ID3D11Texture2D* texture) {
  inputs_.erase(texture);
  outputs_.erase(texture);
}

void Converter::Reset() {
  inputs_.clear();
  outputs_.clear();
  processor_ = nullptr;
  enumerator_ = nullptr;
  in_width_ = in_height_ = out_width_ = out_height_ = 0;
}

bool Converter::Ensure(UINT in_width, UINT in_height, UINT out_width, UINT out_height) {
  if (processor_ && in_width == in_width_ && in_height == in_height_ && out_width == out_width_ &&
      out_height == out_height_) {
    return true;
  }
  inputs_.clear();
  outputs_.clear();
  processor_ = nullptr;
  enumerator_ = nullptr;
  auto* video = d3d_->video_device();
  if (video == nullptr) return false;
  D3D11_VIDEO_PROCESSOR_CONTENT_DESC desc{};
  desc.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
  desc.InputWidth = in_width;
  desc.InputHeight = in_height;
  desc.OutputWidth = out_width;
  desc.OutputHeight = out_height;
  desc.InputFrameRate = {60, 1};
  desc.OutputFrameRate = {60, 1};
  desc.Usage = D3D11_VIDEO_USAGE_OPTIMAL_SPEED;
  if (FAILED(video->CreateVideoProcessorEnumerator(&desc, enumerator_.put()))) return false;
  if (FAILED(video->CreateVideoProcessor(enumerator_.get(), 0, processor_.put()))) {
    enumerator_ = nullptr;
    return false;
  }
  auto* context = d3d_->video_context();
  context->VideoProcessorSetStreamFrameFormat(processor_.get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
  context->VideoProcessorSetStreamAutoProcessingMode(processor_.get(), 0, FALSE);
  context->VideoProcessorSetStreamOutputRate(processor_.get(), 0, D3D11_VIDEO_PROCESSOR_OUTPUT_RATE_NORMAL, FALSE,
                                             nullptr);
  winrt::com_ptr<ID3D11VideoContext1> context1;
  if (SUCCEEDED(context->QueryInterface(__uuidof(ID3D11VideoContext1), context1.put_void()))) {
    context1->VideoProcessorSetStreamColorSpace1(processor_.get(), 0, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709);
    context1->VideoProcessorSetOutputColorSpace1(processor_.get(), DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709);
  } else {
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE in{};
    in.RGB_Range = 0;  // full
    in.YCbCr_Matrix = 1;
    in.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255;
    context->VideoProcessorSetStreamColorSpace(processor_.get(), 0, &in);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE out{};
    out.RGB_Range = 1;
    out.YCbCr_Matrix = 1;  // BT.709
    out.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
    context->VideoProcessorSetOutputColorSpace(processor_.get(), &out);
  }
  D3D11_VIDEO_COLOR black{};
  black.YCbCr = {0.0625f, 0.5f, 0.5f, 1.0f};
  context->VideoProcessorSetOutputBackgroundColor(processor_.get(), TRUE, &black);
  in_width_ = in_width;
  in_height_ = in_height;
  out_width_ = out_width;
  out_height_ = out_height;
  return true;
}

bool Converter::Convert(ID3D11Texture2D* source, const RECT& source_rect, ID3D11Texture2D* target) {
  D3D11_TEXTURE2D_DESC in_desc{}, out_desc{};
  source->GetDesc(&in_desc);
  target->GetDesc(&out_desc);
  if (!Ensure(in_desc.Width, in_desc.Height, out_desc.Width, out_desc.Height)) return false;
  auto* video = d3d_->video_device();
  auto* context = d3d_->video_context();

  auto in = inputs_.find(source);
  if (in == inputs_.end()) {
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC view{};
    view.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    winrt::com_ptr<ID3D11VideoProcessorInputView> created;
    if (FAILED(video->CreateVideoProcessorInputView(source, enumerator_.get(), &view, created.put()))) return false;
    in = inputs_.emplace(source, created).first;
  }
  auto out = outputs_.find(target);
  if (out == outputs_.end()) {
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC view{};
    view.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
    winrt::com_ptr<ID3D11VideoProcessorOutputView> created;
    if (FAILED(video->CreateVideoProcessorOutputView(target, enumerator_.get(), &view, created.put()))) return false;
    out = outputs_.emplace(target, created).first;
  }
  RECT dest{0, 0, static_cast<LONG>(out_desc.Width), static_cast<LONG>(out_desc.Height)};
  context->VideoProcessorSetStreamSourceRect(processor_.get(), 0, TRUE, &source_rect);
  context->VideoProcessorSetStreamDestRect(processor_.get(), 0, TRUE, &dest);
  context->VideoProcessorSetOutputTargetRect(processor_.get(), TRUE, &dest);
  D3D11_VIDEO_PROCESSOR_STREAM stream{};
  stream.Enable = TRUE;
  stream.pInputSurface = in->second.get();
  return SUCCEEDED(context->VideoProcessorBlt(processor_.get(), out->second.get(), 0, 1, &stream));
}

}  // namespace wsn
