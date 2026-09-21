# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/publisher"

module Bake
	module Gem
		module GitHub
			# A simulated registry and GitHub finalizer. Core content validation has its own
			# real-repository integration tests; this fixture exercises interruption/retry.
			class RecoveryPublisher < Publisher
				attr_accessor :remote_digest, :fail_release, :fail_attestation, :fail_receipt_verification
				attr_accessor :releases, :artifacts, :fail_preservation, :stale_release_list, :fail_preservation_after
				attr_reader :commands, :stored_files
				
				def initialize(root)
					super
					@commands = []
					@releases = []
					@artifacts = []
					@stored_files = {}
					@release = Object.new
					def @release.resolve(reference)
						"a" * 40
					end
					def @release.validate(**options)
						{name: "example", version: "1.0.1", commit: "a" * 40}
					end
				end
				
				def merged(number)
					{"merge_commit_sha" => "a" * 40, "number" => 42, "html_url" => "https://github.com/socketry/example/pull/42"}
				end
				
				def system(*arguments, **options)
					@commands << arguments
					raise "Attestation verification failed" if @fail_attestation && arguments[0, 3] == ["gem", "exec", "sigstore-cli:0.2.3"]
					if @fail_receipt_verification && arguments[0, 3] == ["gh", "attestation", "verify"] && arguments[3].end_with?("/release.json")
						raise "Receipt attestation verification failed"
					end
					if arguments[0, 2] == ["gem", "push"]
						@remote_digest = load_receipt.fetch(:sha256)
					end
					case arguments[0, 3]
					when ["gh", "release", "upload"]
						raise "Preservation failed" if @fail_preservation || (@fail_preservation_after && @stored_files.size >= @fail_preservation_after)
						file = arguments[4]
						@stored_files[File.basename(file)] = File.binread(file)
						@releases.first.fetch("assets") << {"name" => File.basename(file), "digest" => "sha256:#{Digest::SHA256.file(file).hexdigest}"}
					when ["gh", "release", "download"], ["gh", "run", "download"]
						if index = arguments.index("--output")
							File.binwrite(arguments[index + 1], @stored_files.fetch("release.tar"))
						else
							path = arguments[arguments.index("--dir") + 1]
							@stored_files.each{|name, content| File.binwrite(File.join(path, name), content)}
						end
					when ["gh", "release", "edit"]
						raise "GitHub unavailable after upload" if @fail_release
						@releases.first["draft"] = false
					end
					true
				end
				
				def readlines(*arguments, **options)
					@commands << arguments
					if arguments[0, 2] == ["gh", "api"]
						if arguments[2] == "graphql"
							tag = arguments.find{|argument| argument.start_with?("tag=")}.delete_prefix("tag=")
							index = @releases.index{|release| release.fetch("tag_name") == tag}
							return [JSON.generate(data: {repository: {release: index && {databaseId: index + 1}}})]
						end
						if arguments.include?("POST")
							release = JSON.parse(File.read(arguments[arguments.index("--input") + 1])).merge("assets" => [])
							@releases << release
							return [JSON.generate(release)]
						end
						releases = @releases.each_with_index.map{|release, index| release.merge("id" => index + 1)}
						return [JSON.generate([@stale_release_list ? [] : releases])]
					end
					[]
				end
				
				def api(path)
					return @releases.fetch(Integer(path.delete_prefix("releases/")) - 1) if path.start_with?("releases/")
					{"artifacts" => @artifacts}
				end
				
				private
				
				def gem_command(*arguments)
					system("gem", *arguments, chdir: @root)
				end
				
				def guard_environment
				end
				
				def registry_digest(name, version)
					@remote_digest
				end
				
				def registry_get(url)
					JSON.generate([{bundle: {mediaType: "test"}}])
				end
			end
		end
	end
end
