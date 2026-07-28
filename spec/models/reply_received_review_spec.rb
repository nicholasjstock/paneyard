require "rails_helper"

RSpec.describe ReplyReceivedReview, type: :model do
  describe ".issue!" do
    it "captures the comment and the question it answers, and does not authenticate its own returned token by digest alone" do
      run = create_run
      question = create_question(run)

      review, token = ReplyReceivedReview.issue!(
        run:, user_question: question, comment: { "id" => 42, "user" => { "login" => "nicholasjstock" }, "body" => "approved" }
      )

      expect(review.user_question_id).to eq(question.question_id)
      expect(review.github_comment_id).to eq("42")
      expect(review.github_comment_author).to eq("nicholasjstock")
      expect(review.github_comment_body).to eq("approved")
      expect(review.status).to eq("queued")
      expect(ReplyReceivedReview.authenticate(token)).to eq(review)
    end
  end

  describe "#reissue_token!" do
    it "rotates the capability so a fresh spawn authenticates while the old token no longer does" do
      run = create_run
      question = create_question(run)
      review, original_token = ReplyReceivedReview.issue!(
        run:, user_question: question, comment: { "id" => 1, "user" => { "login" => "op" }, "body" => "approved" }
      )
      review.update!(expires_at: 5.minutes.from_now)

      new_token = review.reissue_token!

      expect(new_token).not_to eq(original_token)
      expect(ReplyReceivedReview.authenticate(new_token)).to eq(review)
      expect(ReplyReceivedReview.authenticate(original_token)).to be_nil
      expect(review.reload.expires_at).to be > 55.minutes.from_now
    end
  end

  describe "#user_question" do
    it "resolves back to the UserQuestion by question_id" do
      run = create_run
      question = create_question(run)
      review, = ReplyReceivedReview.issue!(
        run:, user_question: question, comment: { "id" => 1, "user" => { "login" => "op" }, "body" => "approved" }
      )

      expect(review.user_question).to eq(question)
    end
  end

  def create_run
    root = Dir.mktmpdir("reply-received-review-model")
    workspace = Workspace.create!(name: "reply-received-review-model-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "reply-received-review-model-#{SecureRandom.hex(4)}", task: "Exercise reply_received token rotation",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end

  def create_question(run)
    run.user_questions.create!(
      asked_by: "planner", scope: "run", priority: "blocking", status: "open",
      text: "Approve?", context: "The plan.", tags: [ "plan-approval" ]
    )
  end
end
