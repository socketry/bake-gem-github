# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :test do
	gem "bake-test"
	gem "covered"
	gem "sus"
	gem "rubocop"
	gem "rubocop-md"
	gem "rubocop-socketry"
end

group :maintenance, optional: true do
	gem "agent-context"
	gem "decode"
	gem "utopia-project"
end
