require "test_helper"

class Legacy::ImporterTest < Minitest::Test
  def test_run
    assert_equal 1, Legacy::Importer.new.run
  end
end
