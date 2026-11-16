# Adds the ObdLiveActivity widget extension (the Live Activity shown on the
# Lock Screen and, from iOS 26, on the CarPlay Dashboard) to Runner.xcodeproj.
#
# Xcode normally does this through its UI. This project is developed on
# Windows, so the cloud build runs this script instead, on a fresh checkout,
# right before `flutter build ios`. It is safe to run more than once.
#
#   gem install xcodeproj
#   ruby ios/tool/add_live_activity_target.rb

require 'xcodeproj'

EXTENSION = 'ObdLiveActivity'
SOURCES = %w[ObdLiveActivityBundle.swift DashboardLiveActivity.swift].freeze

project_path = File.expand_path('../Runner.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

runner = project.targets.find { |target| target.name == 'Runner' }
abort 'Runner target not found' if runner.nil?

if project.targets.any? { |target| target.name == EXTENSION }
  puts "#{EXTENSION} target already present, nothing to do"
  exit 0
end

SOURCES.each do |file|
  path = File.expand_path("../#{EXTENSION}/#{file}", __dir__)
  abort "Missing #{path}" unless File.exist?(path)
end

bundle_id = runner.build_configurations.first.build_settings['PRODUCT_BUNDLE_IDENTIFIER']
abort 'Runner has no PRODUCT_BUNDLE_IDENTIFIER' if bundle_id.nil?

# The Live Activity uses the "small" activity family (iOS 18), so the
# extension targets iOS 18 while the app itself keeps its lower minimum.
extension = project.new_target(:app_extension, EXTENSION, :ios, '18.0')

group = project.main_group.new_group(EXTENSION, EXTENSION)
source_refs = SOURCES.map { |file| group.new_file(file) }
group.new_file('Info.plist')
extension.add_file_references(source_refs)

extension.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{bundle_id}.#{EXTENSION}"
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['INFOPLIST_FILE'] = "#{EXTENSION}/Info.plist"
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
  settings['SWIFT_VERSION'] = '5.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['MARKETING_VERSION'] = '1.0.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['SKIP_INSTALL'] = 'YES'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['ENABLE_BITCODE'] = 'NO'
  settings['LD_RUNPATH_SEARCH_PATHS'] = [
    '$(inherited)',
    '@executable_path/Frameworks',
    '@executable_path/../../Frameworks',
  ]
end

# Build the extension with the app and copy it into Runner.app/PlugIns.
runner.add_dependency(extension)
embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
embed.dst_subfolder_spec = '13' # PlugIns
embedded = embed.add_file_reference(extension.product_reference)
embedded.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# Xcode reports a dependency cycle unless the extension is embedded before
# Flutter's "Thin Binary" script phase runs.
thin_binary = runner.build_phases.index do |phase|
  phase.respond_to?(:name) && phase.name == 'Thin Binary'
end
unless thin_binary.nil?
  runner.build_phases.delete(embed)
  runner.build_phases.insert(thin_binary, embed)
end

project.save
puts "Added #{EXTENSION} (#{bundle_id}.#{EXTENSION}) to #{File.basename(project_path)}"
