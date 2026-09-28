# A RemoteControl::Adapter that records what it would have sent, for specs of
# the platform-neutral core (RemoteControl::Processor, StreamPaneJob). It is
# also the smallest example of what an adapter has to implement.
class FakeRemoteControlAdapter < RemoteControl::Adapter
  attr_reader :sent
  attr_writer :markdown_error

  def initialize(allowed: [ "42" ], edits: true, max_message_length: 4096)
    @allowed = allowed
    @edits = edits
    @max_message_length = max_message_length
    @sent = []
    @next_id = 76
  end

  def name = "fake"
  def configured? = true
  def allowed_user_ids = @allowed
  def supports_edit? = @edits
  def command_link(command, ref) = "/#{command}_#{ref}"
  attr_reader :max_message_length

  def send_text(chat_id, text) = record(:text, chat_id, text)
  def send_pane(chat_id, title, body) = record(:pane, chat_id, [ title, body ])
  def edit_pane(chat_id, message_id, title, body) = record(:edit, chat_id, [ message_id, title, body ])

  def send_markdown(chat_id, markdown)
    raise @markdown_error if @markdown_error

    record(:markdown, chat_id, markdown)
  end

  def publish_commands(commands) = record(:commands, nil, commands)

  def texts = of(:text)
  def panes = of(:pane)
  def edits = of(:edit)
  def markdowns = of(:markdown)
  # Everything a person would read, in order, as plain strings.
  def transcript = sent.map { |_kind, _chat, payload| Array(payload).join("\n") }

  private

  def of(kind) = sent.select { |entry| entry.first == kind }.map(&:last)

  def record(kind, chat_id, payload)
    @sent << [ kind, chat_id, payload ]
    @next_id += 1
  end
end
