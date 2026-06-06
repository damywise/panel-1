#
# macOS plugin for package:panel_macos.
# Ships the native dock helper (Swift @_cdecl symbols resolved from Dart over
# FFI via DynamicLibrary.process()).
#
Pod::Spec.new do |s|
  s.name             = 'panel_macos'
  s.version          = '0.1.0'
  s.summary          = 'macOS backend for package:panel (detachable OS windows).'
  s.description      = <<-DESC
Native macOS dock helper: hides title bars on detached panel windows and reports
window drags for drag-back snapping, driven from Dart over FFI.
                       DESC
  s.homepage         = 'https://github.com/your-org/panel'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Panel' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  # Shares the same sources as the Swift Package (panel_macos/Sources).
  s.source_files     = 'panel_macos/Sources/panel_macos/**/*.swift'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.14'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
