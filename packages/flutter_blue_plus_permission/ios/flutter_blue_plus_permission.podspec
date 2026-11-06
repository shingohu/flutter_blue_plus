#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_blue_plus_permission.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_blue_plus_permission'
  s.version          = '0.0.1'
  s.summary          = 'BLE permission helper for flutter_blue_plus.'
  s.description      = <<-DESC
BLE permission and Bluetooth adapter helpers for flutter_blue_plus on iOS.
                       DESC
  s.homepage         = 'https://github.com/shingohu/flutter_blue_plus'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'shingo' => 'shingohu@163.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
