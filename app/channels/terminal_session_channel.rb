# Bridges a workspace's TerminalSession pty to the browser's xterm.js
# instance. Output is a broadcast stream (see
# Orchestrator::TerminalSessionRunner#pump) so any subscribed tab receives
# live bytes; input can only be written from the Rails process that
# actually holds the pty master fd (see TerminalSessionRunner#write_input).
class TerminalSessionChannel < ApplicationCable::Channel
  def subscribed
    session = TerminalSession.find_by(id: params[:id])
    return reject unless session

    stream_from Orchestrator::TerminalSessionRunner.stream_name(session.id)
    transmit({ type: "replay", data: Orchestrator::TerminalSessionRunner.replay(session) })
    ensure_streaming(session)
  end

  def receive(data)
    session = TerminalSession.find_by(id: params[:id])
    return unless session

    case data["type"]
    when "input"
      Orchestrator::TerminalSessionRunner.write_input(session, data["data"].to_s)
    when "resize"
      Orchestrator::TerminalSessionRunner.resize(session, cols: data["cols"], rows: data["rows"])
    end
  end

  private

  def ensure_streaming(session)
    return if Orchestrator::TerminalSessionRunner.live?(session)

    Orchestrator::TerminalSessionRunner.resume(session)
  end
end
