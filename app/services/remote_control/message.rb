module RemoteControl
  # One message from the operator, as every adapter hands it to Processor:
  # the platform's own event shape stays inside the adapter.
  #
  #   chat_id        where to answer (the adapter's own id, passed back as is)
  #   user_id        who sent it, as a string, checked against the adapter's
  #                  allow-list
  #   text           what they wrote; commands start with "/"
  #   reply_to_text  the text of the bot message this one replies to, if any --
  #                  a reply to "run 33bd · ..." goes to that run
  Message = Data.define(:chat_id, :user_id, :text, :reply_to_text) do
    def initialize(chat_id:, user_id:, text:, reply_to_text: nil)
      super(chat_id:, user_id: user_id.to_s, text: text.to_s.strip, reply_to_text:)
    end
  end
end
