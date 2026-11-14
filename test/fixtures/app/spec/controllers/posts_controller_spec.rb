RSpec.describe PostsController do
  it { get :index }

  it "archives" do
    post :archive
  end
end
