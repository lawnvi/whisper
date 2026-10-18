Pod::Spec.new do |s|
  s.name             = 'window_stream_native'
  s.version          = '0.1.0'
  s.summary          = 'Native windows, decoders and capture for Whisper window streaming.'
  s.description      = 'Streamed-window surfaces (VideoToolbox decode, AVFoundation playback, input capture) reached through dart:ffi.'
  s.homepage         = 'https://github.com/lawnvi/whisper'
  s.license          = { :type => 'MIT' }
  s.author           = { 'lawnvi' => 'lawnvi@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.15'
  s.frameworks       = 'AppKit', 'AVFoundation', 'AudioToolbox', 'CoreImage', 'CoreMedia', 'CoreVideo', 'ImageIO', 'QuartzCore', 'VideoToolbox'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
