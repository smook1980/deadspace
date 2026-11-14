# frozen_string_literal: true

# Standalone bundle for the dead code analyzer so it never touches the app's
# Gemfile.lock. Install with:
#   BUNDLE_GEMFILE=script/dead_code/Gemfile bundle install
source "https://rubygems.org"

gem "activesupport", ">= 7.0" # inflections (pluralize / classify / underscore)
gem "csv"
gem "prism", ">= 1.2" # Ruby's official parser; stdlib from Ruby 3.4

group :test do
  gem "minitest", ">= 5.20"
end
