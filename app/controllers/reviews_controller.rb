class ReviewsController < ApplicationController
  def index
    @reviews = LabelReview.recent
  end

  def new
    @review = LabelReview.new
  end

  def create
    @review = LabelReview.new(review_params)
    @review.status = "pending"

    if @review.save
      LabelAnalysisJob.perform_later(@review.id)
      redirect_to review_path(@review)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @review = LabelReview.find(params[:id])
  end

  private

  def review_params
    params.require(:label_review).permit(
      :label_image,
      :app_brand_name,
      :app_class_type,
      :app_abv,
      :app_net_contents,
      :app_producer,
      :app_country_of_origin
    )
  end
end
