class PostsController < ApplicationController
  def index
    @posts = Post.published.map(&:title_for_display)
    ExporterLookup.for(params[:format])
    Sorter.sort(Post.all, params[:sort])
    StatusHolder.kinds
    Post::STATUSES
    SponsoredPost
    @summary = Post.new(summary: "x")
  end

  def show = authorize(Post.find(params[:id]))
  def publish = nil
  def archive = nil
end
