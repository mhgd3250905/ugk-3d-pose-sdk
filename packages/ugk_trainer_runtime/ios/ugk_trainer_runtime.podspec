Pod::Spec.new do |s|
  s.name             = 'ugk_trainer_runtime'
  s.version          = '0.1.0'
  s.summary          = 'Shared training runtime and packed alpha video textures.'
  s.description      = 'Muted AVPlayer video output for the shared Flutter training runtime.'
  s.homepage         = 'https://github.com/mhgd3250905/ugk-3d-pose-sdk'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'mhgd3250905' => 'mhgd3250905@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'ugk_trainer_runtime/Sources/ugk_trainer_runtime/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.frameworks       = 'AVFoundation', 'CoreVideo', 'QuartzCore'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
