# app/services/workspace_health_probe.rb
#
# Active reachability probe for a workspace pod. The CR `.status.phase` tells
# us what Kubernetes thinks ("does the pod exist / is it scheduled"), but not
# whether the app inside is actually answering. This probe reaches the pod's
# in-cluster Service and checks the two things that matter for "is this
# workspace usable":
#
#   * rails — HTTP GET <svc>:3000/up returns 2xx (Rails health check up)
#   * ws    — a WebSocket upgrade to <svc>:8080/ws returns 101 (worker alive
#             and speaking the protocol; an "invalid token" close frame after
#             the 101 is expected and fine — we only care that it upgraded)
#
# Reached over in-cluster Service DNS (ws-<id>.ws-<id>.svc.cluster.local), so
# this only returns meaningful results when the control plane runs inside the
# cluster. Out-of-cluster dev gets reachable:false, which the dashboard shows
# as "unreachable" rather than an error.
#
# Every check is wrapped so a timeout / refused connection becomes a plain
# false instead of raising — a probe must never blow up the request handling it.

require 'net/http'
require 'socket'
require 'securerandom'
require 'base64'

class WorkspaceHealthProbe
  TIMEOUT = Float(ENV.fetch('WORKSPACE_PROBE_TIMEOUT_S', '2'))
  RAILS_PORT  = Integer(ENV.fetch('WORKSPACE_RAILS_PORT', '3000'))
  WORKER_PORT = Integer(ENV.fetch('WORKSPACE_WORKER_PORT', '8080'))

  def initialize(workspace)
    @workspace = workspace
  end

  # Returns { rails: bool, ws: bool, ok: bool }. `ok` means the workspace is
  # usable end-to-end (both Rails and the worker answered).
  def call
    rails = probe_rails
    ws    = probe_ws
    { rails: rails, ws: ws, ok: rails && ws }
  end

  private

  def host
    # Service FQDN: <release>.<namespace>.svc.cluster.local. release_name and
    # namespace_name are both "ws-<id>".
    "#{@workspace.release_name}.#{@workspace.namespace_name}.svc.cluster.local"
  end

  def probe_rails
    uri = URI("http://#{host}:#{RAILS_PORT}/up")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT
    res = http.request(Net::HTTP::Get.new(uri.request_uri))
    res.code.to_i.between?(200, 299)
  rescue StandardError
    false
  end

  # Minimal RFC 6455 client handshake — we only read the status line and check
  # for "101 Switching Protocols". We never send/read data frames.
  def probe_ws
    Socket.tcp(host, WORKER_PORT, connect_timeout: TIMEOUT) do |sock|
      key = Base64.strict_encode64(SecureRandom.random_bytes(16))
      sock.write(
        "GET /ws HTTP/1.1\r\n" \
        "Host: #{host}:#{WORKER_PORT}\r\n" \
        "Upgrade: websocket\r\n" \
        "Connection: Upgrade\r\n" \
        "Sec-WebSocket-Version: 13\r\n" \
        "Sec-WebSocket-Key: #{key}\r\n" \
        "\r\n"
      )
      return false unless sock.wait_readable(TIMEOUT)

      status_line = sock.gets.to_s
      status_line.include?('101')
    end
  rescue StandardError
    false
  end
end
