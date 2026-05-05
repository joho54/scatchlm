require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ExpoLiquidGlass'
  s.version        = package['version']
  s.summary        = 'Liquid Glass refraction effect for React Native'
  s.description    = 'Native iOS module providing Apple-style liquid glass refraction using CIFilter displacement maps'
  s.author         = 'joho54'
  s.homepage       = 'https://github.com/joho54/scatchlm'
  s.platforms      = { :ios => '15.1' }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.source_files = '**/*.{h,m,mm,swift}'
end
