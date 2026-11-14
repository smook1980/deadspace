# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] = File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
require "minitest/autorun"
require_relative "../lib/dead_code"
