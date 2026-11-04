#!/usr/bin/env ruby
# Run native tests in an already-resolved Flutter host, without retaining edits
# to its Xcode project. Usage: ruby <this file> <host/app> <simulator UDID>
require 'xcodeproj'
require 'pathname'

abort 'Usage: run_ios_packed_alpha_tests.rb <Flutter host directory> <simulator UDID>' unless ARGV.length == 2
host = Pathname.new(ARGV[0]).expand_path
runtime = Pathname.new(__dir__).parent
project_path = host.join('ios/Runner.xcodeproj')
pbxproj = project_path.join('project.pbxproj')
original = pbxproj.binread

begin
  project = Xcodeproj::Project.open(project_path.to_s)
  target = project.targets.find { |entry| entry.name == 'RunnerTests' }
  abort 'The Flutter host must have a RunnerTests target' unless target
  group = project.main_group.new_group('UGK packed alpha native tests')
  files = %w[PackedAlphaPlayer.swift PackedAlphaSource.swift].map do |name|
    runtime.join('ios/ugk_trainer_runtime/Sources/ugk_trainer_runtime', name)
  end
  files << runtime.join('ios/Tests/PackedAlphaTests.swift')
  files.each { |file| target.source_build_phase.add_file_reference(group.new_file(file.to_s)) }
  project.save
  success = system(
    'xcodebuild', '-workspace', host.join('ios/Runner.xcworkspace').to_s,
    '-scheme', 'Runner', '-configuration', 'Debug',
    "BUILD_DIR=#{host.join('build/ios')}",
    '-destination', "platform=iOS Simulator,id=#{ARGV[1]}",
    '-only-testing:RunnerTests/PackedAlphaTests', 'CODE_SIGNING_ALLOWED=NO', 'test'
  )
ensure
  pbxproj.binwrite(original)
end
exit(success ? 0 : 1)
