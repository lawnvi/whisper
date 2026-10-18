Pod::Spec.new do |s|
  s.name             = 'window_stream_native'
  s.version          = '0.1.0'
  s.summary          = 'Streamed-window receiver for Whisper on iOS and iPadOS.'
  s.description      = 'VideoToolbox decoding of streamed windows into Flutter textures.'
  s.homepage         = 'https://github.com/lawnvi/whisper'
  s.license          = { :type => 'MIT' }
  s.author           = { 'lawnvi' => 'lawnvi@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.frameworks       = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'GameController', 'ImageIO', 'VideoToolbox'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
