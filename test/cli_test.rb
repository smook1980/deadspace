# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"

class CLITest < Minitest::Test
  ROOT = File.expand_path("fixtures/app", __dir__)

  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Deadspace::CLI.new(argv, out:, err:, env: {}).run
    [status, out.string, err.string]
  end

  def test_reports_the_app_and_writes_both_csvs
    Dir.mktmpdir do |dir|
      csv = File.join(dir, "out.csv")
      status, out, err = run_cli("--width", "80", "--csv", csv, ROOT)

      assert_equal 0, status
      assert_includes out, "● DeadService"
      refute_includes out, "\e[" # not a TTY
      assert_match(/Wrote \d+ findings to #{Regexp.escape(csv)}/, err)
      assert_includes File.read(File.join(dir, "out_tests.csv")), "spec/services/dead_service_spec.rb"
    end
  end

  def test_only_and_path_narrow_the_report
    _, out, = run_cli("--only", "unused", "--path", "app/services", ROOT)
    assert_includes out, "● DeadService"
    refute_includes out, "FeaturedPost"
    refute_includes out, "LIKELY UNUSED (1"
  end

  def test_rejects_a_directory_that_is_not_a_rails_app
    status, _, err = run_cli(__dir__)
    assert_equal 1, status
    assert_match(/does not look like a Rails app/, err)
  end

  def test_rejects_unknown_options
    status, _, err = run_cli("--bogus")
    assert_equal 1, status
    assert_match(/invalid option: --bogus/, err)
  end

  def test_warns_about_an_ignore_path_that_does_not_exist
    _, _, err = run_cli("--quiet", "--ignore", "app/nope", ROOT)
    assert_match(%r{--ignore app/nope: no such file}, err)
  end
end
