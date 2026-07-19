require "rails_helper"

RSpec.describe ChaperoneReview, type: :model do
  describe "#reissue_token!" do
    it "rotates the capability so a fresh spawn authenticates while the old token no longer does" do
      run = create_run
      review, original_token = ChaperoneReview.issue!(
        run:, lineage_key: "diagnosis-lineage", step_attempt_ids: []
      )
      review.update!(expires_at: 5.minutes.from_now)

      new_token = review.reissue_token!

      expect(new_token).not_to eq(original_token)
      expect(ChaperoneReview.authenticate(new_token)).to eq(review)
      expect(ChaperoneReview.authenticate(original_token)).to be_nil
      expect(review.reload.expires_at).to be > 55.minutes.from_now
    end
  end

  def create_run
    root = Dir.mktmpdir("chaperone-review-model")
    workspace = Workspace.create!(name: "chaperone-review-model-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "chaperone-review-model-#{SecureRandom.hex(4)}", task: "Exercise chaperone token rotation",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end
end
