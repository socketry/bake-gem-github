# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "sus/fixtures/temporary_directory_context"
require "sus/fixtures/isolated_ruby_context"
require "bake/gem/github/setup"

module Bake
	module Gem
		module GitHub
			module RepositoryContext
				include Sus::Fixtures::TemporaryDirectoryContext
				include Sus::Fixtures::IsolatedRubyContext
				
				def repository
					File.join(root, "source")
				end
				
				def git(*arguments, chdir: repository)
					output = IO.popen(["git", *arguments], chdir: chdir, &:read)
					raise "git failed: #{arguments.inspect}" unless $?.success?
					output.strip
				end
				
				def before
					super
					FileUtils.mkdir_p(File.join(repository, "lib/example"))
					File.write(File.join(repository, "lib/example/version.rb"), "module Example; VERSION = \"1.0.0\"; end\n")
					File.write(File.join(repository, "example.gemspec"), <<~RUBY)
						require_relative "lib/example/version"
						Gem::Specification.new do |spec|
							spec.name = "example"
							spec.version = Example::VERSION
							spec.summary = "Example consumer"
							spec.authors = ["Test"]
							spec.license = "MIT"
							spec.homepage = "https://example.com"
							spec.required_ruby_version = ">= 3.3"
							spec.files = Dir.glob(["lib/**/*.rb", "releases.md"])
						end
					RUBY
					File.write(File.join(repository, "releases.md"), "## Unreleased\n\nA change.\n")
					File.write(File.join(repository, "bake.rb"), <<~'RUBY')
						def after_gem_release_version_increment(version)
							File.write("releases.md", File.read("releases.md").sub("Unreleased", version.to_s))
						end
					RUBY
					File.write(File.join(repository, ".gitignore"), "/pkg/\n")
					Setup.new(repository).generate(repository: "socketry/example", checks: ["Tests"], signing: false)
					git("init", "--quiet", "--initial-branch=main")
					git("config", "core.hooksPath", File::NULL)
					git("config", "commit.gpgsign", "false")
					git("config", "user.name", "Test")
					git("config", "user.email", "test@example.com")
					git("add", "--all")
					git("commit", "--quiet", "-m", "Initial source")
					git("init", "--quiet", "--bare", "--initial-branch=main", File.join(root, "remote"))
					git("remote", "add", "origin", File.join(root, "remote"))
					git("push", "--quiet", "--set-upstream", "origin", "main")
				end
				
				def isolated_project(source, env: {})
					isolated_ruby(source, chdir: repository, env: env, requires: ["bundler/setup", File.expand_path("project_client.rb", __dir__)])
				end
			end
		end
	end
end
