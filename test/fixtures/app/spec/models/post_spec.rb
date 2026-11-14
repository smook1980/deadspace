require "rails_helper"

RSpec.describe Post do
  it { expect(Post.new.only_tested).to eq(1) }
  it { DeadService.new.call }

  describe "#unused_method" do
    subject { Post.new.unused_method }

    it { is_expected.to eq(2) }
  end

  describe ".unused_method" do
    it { expect(true).to be(true) }
  end

  describe ".never_used_scope" do
    it { expect(Post.never_used_scope).to be_empty }
  end

  describe "#title_for_display" do
    it { expect(Post.new.title_for_display).to be_a(String) }
  end
end

RSpec.describe Post, "spec helpers" do
  def legacy_helper = :stub

  it { expect(legacy_helper).to eq(:stub) }
end
