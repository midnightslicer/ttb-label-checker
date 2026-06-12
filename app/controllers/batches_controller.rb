require "csv"

class BatchesController < ApplicationController
  CSV_COLUMNS = %w[
    filename brand_name class_type abv net_contents producer country_of_origin
  ].freeze

  MAX_BATCH_SIZE = ENV.fetch("MAX_BATCH_SIZE", 300).to_i

  def index
    @batches = BatchUpload.recent
  end

  def new
  end

  def create
    csv_file = params[:csv]
    images   = Array(params[:images]).reject(&:blank?)

    if csv_file.blank? || images.empty?
      flash.now[:alert] = "Please provide both a CSV file and the label images."
      return render :new, status: :unprocessable_entity
    end

    rows = parse_csv(csv_file)
    if rows.nil?
      flash.now[:alert] = "Could not parse the CSV. Check the header row and try again."
      return render :new, status: :unprocessable_entity
    end

    if rows.size > MAX_BATCH_SIZE
      flash.now[:alert] = "Batch too large (#{rows.size}). Maximum is #{MAX_BATCH_SIZE}."
      return render :new, status: :unprocessable_entity
    end

    images_by_name = images.index_by { |f| f.original_filename }
    missing = rows.filter_map { |r| r["filename"] unless images_by_name.key?(r["filename"]) }

    if missing.any?
      flash.now[:alert] = "Missing image files for: #{missing.join(', ')}"
      return render :new, status: :unprocessable_entity
    end

    batch = build_batch(rows, images_by_name)
    redirect_to batch_path(batch)
  end

  def show
    @batch = BatchUpload.find(params[:id])
    @reviews = @batch.label_reviews.order(:id)
  end

  private

  def parse_csv(file)
    table = CSV.parse(file.read, headers: true)
    return nil unless table.headers.include?("filename")

    table.map(&:to_h)
  rescue CSV::MalformedCSVError
    nil
  end

  def build_batch(rows, images_by_name)
    batch = nil
    BatchUpload.transaction do
      batch = BatchUpload.create!(total_count: rows.size, status: "pending")

      rows.each do |row|
        review = batch.label_reviews.build(
          status:                "pending",
          app_brand_name:        row["brand_name"],
          app_class_type:        row["class_type"],
          app_abv:               row["abv"],
          app_net_contents:      row["net_contents"],
          app_producer:          row["producer"],
          app_country_of_origin: row["country_of_origin"]
        )
        review.label_image.attach(images_by_name[row["filename"]])
        review.save!
      end
    end

    batch.label_reviews.find_each { |r| LabelAnalysisJob.perform_later(r.id) }
    batch
  end
end
