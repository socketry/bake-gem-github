# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "rubygems/package"

module Bake
	module Gem
		module GitHub
			# Stores the original release files together so a single completed upload can recover them.
			module Backup
				# Write the release files to a tar archive.
				def self.write(path, files)
					File.open(path, "wb") do |output|
						::Gem::Package::TarWriter.new(output) do |archive|
							files.each do |file|
								archive.add_file(File.basename(file), 0644){|entry| entry.write(File.binread(file))}
							end
						end
					end
				end
				
				# Read only the expected regular files; reject missing, duplicate, or unexpected entries before extraction.
				def self.read(path, names)
					files = {}
					File.open(path, "rb") do |input|
						::Gem::Package::TarReader.new(input) do |archive|
							archive.each do |entry|
								name = entry.full_name
								raise "Unexpected release backup entry: #{name}" unless entry.file? && names.include?(name) && !files.key?(name)
								files[name] = entry.read
							end
						end
					end
					raise "Release backup is incomplete." unless files.keys.sort == names.sort
					files
				end
			end
		end
	end
end
