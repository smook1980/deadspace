# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "rubocop/rake_task"

Minitest::TestTask.create do |t| # rake test
  t.test_globs = ["test/*_test.rb"] # not the fixture app's own tests
end

RuboCop::RakeTask.new

task default: %i[test rubocop]
