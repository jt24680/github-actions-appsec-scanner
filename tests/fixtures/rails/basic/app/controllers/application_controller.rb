class ApplicationController
  def index
    render plain: params[:name]
  end
end
