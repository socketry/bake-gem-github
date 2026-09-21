# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :test do
	gem "sus"
	gem "rubocop"
	gem "rubocop-md"
	gem "rubocop-socketry"
end

group :maintenance, optional: true do
	gem "agent-context"
	gem "utopia-project"
end
