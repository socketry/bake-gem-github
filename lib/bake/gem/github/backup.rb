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
				# @parameter path [String] The destination archive path.
				# @parameter files [Array(String)] Original release files, stored under their basenames.
				# @returns [Nil] After writing and closing the archive.
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
				# @parameter path [String] The archive to inspect without extracting filesystem paths.
				# @parameter names [Array(String)] Exactly the permitted basenames for the gem, receipt, and two attestation files.
				# @returns [Hash(String, String)] Binary file contents keyed by basename.
				# @raises [RuntimeError] If entries are missing, duplicated, unexpected, or not regular files.
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
					
					return files
				end
			end
		end
	end
end
