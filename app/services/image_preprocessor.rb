require "mini_magick"
require "tempfile"

# Cleans up label photos before vision extraction.
#
# Two problems make label photos hard for the vision model: the label is often
# a small, slightly-blurred region of a much larger bottle shot, and the model
# only sees a downscaled copy — so fine print (the government warning, the
# importer line) falls below the resolution it can read, and it latches onto
# the large decorative text instead.
#
# We fix that by locating the bright label on the dark bottle, cropping to it so
# its text fills the frame the model sees, then correcting orientation, dropping
# to grayscale, stretching contrast, and sharpening. Detection runs on a
# downscaled copy for speed and is best-effort: if we can't confidently find a
# label, we fall back to the whole frame.
class ImagePreprocessor
  class ProcessingError < StandardError; end

  # Cap the long edge so we own the downscale (high-quality filter) rather than
  # the model server's default resize. 2048 is needed for the government warning —
  # the smallest, densest text — to transcribe verbatim; it regresses by ~1568.
  MAX_EDGE = 2048

  # JPEG output: far smaller/faster to encode and upload than PNG. q95 keeps the
  # fine-print warning crisp enough to read verbatim.
  JPEG_QUALITY = "95".freeze

  # Unsharp mask tuned to recover edges lost to soft focus without over-haloing:
  # radius x sigma + amount + threshold.
  UNSHARP = "0x1.2+1.0+0.02".freeze

  # Label detection runs on a downscaled copy; the box is mapped back to full
  # resolution before cropping the original.
  DETECT_EDGE        = 1000
  DETECT_THRESHOLD   = "58%".freeze
  DETECT_MIN_AREA    = 2_000   # ignore specks and glare at detection scale
  CROP_AREA_MIN_FRAC = 0.05    # below this the detection is too small to trust
  CROP_AREA_MAX_FRAC = 0.92    # above this a crop buys us nothing
  CROP_PAD_FRAC      = 0.06    # breathing room around the detected box

  # "  15: 1975x1714+1122+392 1947.7,1257.8 2.13412e+06 gray(255)"
  BOX_RE = /\A\s*\d+:\s+(\d+)x(\d+)\+(\d+)\+(\d+)\s+\S+\s+\S+\s+gray\((\d+)\)/

  def self.call(source_path)
    new(source_path).call
  end

  def initialize(source_path)
    @source_path = source_path
  end

  # Returns a Tempfile holding the processed JPEG. The caller owns its lifetime
  # and should close! it once the image has been read.
  def call
    out = Tempfile.new(["label_pp", ".jpg"])
    out.binmode
    crop = label_crop_geometry

    MiniMagick.convert do |c|
      c << @source_path
      c.auto_orient
      if crop
        c.crop crop
        c.repage.+ # drop the virtual canvas so the resize sees only the crop
      end
      c.resize "#{MAX_EDGE}x#{MAX_EDGE}>"
      c.colorspace "Gray"
      c.normalize
      c.unsharp UNSHARP
      c.quality JPEG_QUALITY
      c << out.path
    end

    out.rewind
    out
  rescue MiniMagick::Error => e
    out&.close!
    raise ProcessingError, "Image preprocessing failed: #{e.message}"
  end

  private

  # Geometry string ("WxH+X+Y") of the label in full-resolution coordinates, or
  # nil when there is no confident detection.
  def label_crop_geometry
    boxes = parse_boxes(connected_components_report)
    frame = boxes.find { |b| b[:x].zero? && b[:y].zero? && b[:gray].zero? }
    return nil unless frame

    label = boxes
      .select { |b| b[:gray] >= 128 && b[:area] >= DETECT_MIN_AREA }
      .reject { |b| b[:w] >= frame[:w] * 0.98 && b[:h] >= frame[:h] * 0.98 }
      .max_by { |b| b[:area] }
    return nil unless label

    frac = label[:area].to_f / (frame[:w] * frame[:h])
    return nil unless frac.between?(CROP_AREA_MIN_FRAC, CROP_AREA_MAX_FRAC)

    scale_to_full(label, frame)
  rescue MiniMagick::Error
    nil # detection is best-effort; fall back to the whole frame
  end

  def connected_components_report
    MiniMagick.convert do |c|
      c << @source_path
      c.auto_orient
      c.resize "#{DETECT_EDGE}x#{DETECT_EDGE}"
      c.colorspace "Gray"
      c.blur "0x2"
      c.threshold DETECT_THRESHOLD
      c.define "connected-components:verbose=true"
      c.define "connected-components:area-threshold=#{DETECT_MIN_AREA}"
      c.define "connected-components:mean-color=true"
      c.connected_components "8"
      c << "null:"
    end
  end

  def parse_boxes(report)
    report.to_s.lines.filter_map do |line|
      next unless (m = line.match(BOX_RE))

      {
        w:    m[1].to_i, h: m[2].to_i,
        x:    m[3].to_i, y: m[4].to_i,
        area: m[1].to_i * m[2].to_i,
        gray: m[5].to_i
      }
    end
  end

  # Map a detection-scale box to full-resolution pixels, pad it, and clamp to
  # the frame.
  def scale_to_full(box, frame)
    full_w, full_h = full_dimensions
    sx = full_w.to_f / frame[:w]
    sy = full_h.to_f / frame[:h]

    pad_x = box[:w] * sx * CROP_PAD_FRAC
    pad_y = box[:h] * sy * CROP_PAD_FRAC
    x = (box[:x] * sx - pad_x).clamp(0, full_w)
    y = (box[:y] * sy - pad_y).clamp(0, full_h)
    w = (box[:w] * sx + pad_x * 2).clamp(1, full_w - x)
    h = (box[:h] * sy + pad_y * 2).clamp(1, full_h - y)

    format("%dx%d+%d+%d", w.round, h.round, x.round, y.round)
  end

  # Full-resolution dimensions after EXIF auto-orientation. Header-only, so cheap.
  def full_dimensions
    @full_dimensions ||= MiniMagick
      .convert { |c| c << @source_path; c.auto_orient; c.ping; c.format("%w %h"); c << "info:" }
      .split
      .map(&:to_i)
  end
end
