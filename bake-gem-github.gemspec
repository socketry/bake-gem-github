# frozen_string_literal: true

require_relative "lib/bake/gem/github/version"

Gem::Specification.new do |spec|
	spec.name = "bake-gem-github"
	spec.version = Bake::Gem::GitHub::VERSION
	spec.summary = "Reviewable GitHub releases for Ruby gems."
	spec.authors = ["Samuel Williams"]
	spec.license = "MIT"
	spec.homepage = "https://github.com/socketry/bake-gem-github"
	spec.files = Dir.glob(["{bake,context,lib,templates}/**/*", "*.md"], base: __dir__)
	spec.required_ruby_version = ">= 3.3"
	spec.add_dependency "bake-gem", ">= 0.15.0"
	spec.add_dependency "net-http"
	spec.add_dependency "bake", "~> 0.25"
end
