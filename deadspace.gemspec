# frozen_string_literal: true

require_relative "lib/deadspace/version"

Gem::Specification.new do |spec|
  spec.name = "deadspace"
  spec.version = Deadspace::VERSION
  spec.authors = ["Shane Mook"]
  spec.summary = "Static dead code finder for Rails apps"
  spec.description = "Reports modules, classes, methods and unrouted controller actions in a Rails 7+ app that " \
                     "nothing outside of tests reaches, plus the tests that can go with them. Parses with Prism; " \
                     "never boots the app."
  spec.homepage = "https://github.com/smook1980/deadspace"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/commits/main",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE"]
  spec.bindir = "exe"
  spec.executables = ["deadspace"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.0" # inflections only (pluralize / classify / underscore)
  spec.add_dependency "csv"                     # a bundled (not default) gem from Ruby 3.4
  spec.add_dependency "prism", ">= 1.2"         # Ruby's official parser
end
