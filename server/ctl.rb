#!/usr/bin/env ruby
# frozen_string_literal: true

# ctl.rb — lightweight control API for the lenticel VPS.
#
# Endpoints:
#   POST /evict   — evict a specific subdomain's tunnel (surgical) or
#                   restart frps to drop all tunnels (nuclear fallback).
#
# Auth: Bearer token must match FRP_AUTH_TOKEN env var.
# Runs on port 9191 (Caddy reverse-proxies ctl.LENTICEL_DOMAIN → here).

require "webrick"
require "json"
require "net/http"
require "uri"

TOKEN = ENV.fetch("FRP_AUTH_TOKEN") {
  abort "FRP_AUTH_TOKEN must be set"
}

FRPS_ADMIN = "http://127.0.0.1:7500"
COMPOSE_FILE = "/opt/lenticel/docker-compose.yml"

# Bind to 0.0.0.0 so Caddy (in Docker, via host.docker.internal) can reach us.
# Token auth protects the endpoint; the VPS firewall blocks external access to 9191.
server = WEBrick::HTTPServer.new(Port: 9191, BindAddress: "0.0.0.0")

# ---------- helpers ----------

def authorized?(req)
  header = req["Authorization"] || ""
  header == "Bearer #{TOKEN}"
end

def json_response(res, status, body)
  res.status = status
  res["Content-Type"] = "application/json"
  res.body = JSON.generate(body)
end

# Query frps admin API (basic auth: admin / FRP_AUTH_TOKEN).
def frps_api_get(path)
  uri = URI("#{FRPS_ADMIN}#{path}")
  req = Net::HTTP::Get.new(uri)
  req.basic_auth("admin", TOKEN)
  resp = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 5) { |h| h.request(req) }
  return nil unless resp.is_a?(Net::HTTPSuccess)
  JSON.parse(resp.body)
rescue => e
  $stderr.puts "frps_api_get(#{path}) failed: #{e}"
  nil
end

# Find the clientID owning a given subdomain.
def find_client_id_for_subdomain(subdomain)
  data = frps_api_get("/api/proxy/http")
  return nil unless data && data["proxies"]
  proxy = data["proxies"].find { |p| p.dig("conf", "subdomain") == subdomain && p["status"] == "online" }
  proxy&.fetch("clientID", nil)
end

# Parse frps container logs to find the remote IP:port for a clientID.
# Log line format: [clientID] client login info: ip [1.2.3.4:56789]
def find_client_address(client_id)
  logs = `docker logs --tail 200 $(docker ps -q -f name=frps) 2>&1`
  # Find the most recent login line for this clientID
  pattern = /\[#{Regexp.escape(client_id)}\] client login info: ip \[([^\]]+)\]/
  matches = logs.scan(pattern)
  return nil if matches.empty?
  matches.last[0]  # e.g. "99.42.200.214:45108"
end

# Get the PID of the frps container (for nsenter).
def frps_container_pid
  pid = `docker inspect --format '{{.State.Pid}}' $(docker ps -q -f name=frps) 2>/dev/null`.strip
  pid.empty? ? nil : pid
end

# Surgically kill a single frpc connection using nsenter + ss --kill.
def kill_client_connection(client_addr)
  # rpartition splits on last ":" to handle IPv6-mapped addresses like [::ffff:1.2.3.4]
  *ip_parts, port = client_addr.rpartition(":")
  ip = ip_parts.first
  return { ok: false, message: "bad client address" } unless ip && port

  pid = frps_container_pid
  return { ok: false, message: "cannot find frps container PID" } unless pid

  # ss filter: match established connections on frps port 7000 from this specific client
  cmd = "nsenter -t #{pid} -n ss --kill state established " \
        "'( sport = :7000 and dst #{ip} and dport = #{port} )' 2>&1"
  output = `#{cmd}`
  success = $?.success?

  { ok: success, message: success ? "killed connection from #{client_addr}" : "ss --kill failed", detail: output.strip }
end

# Nuclear fallback: restart the entire frps container.
def nuclear_restart
  output = `docker compose -f #{COMPOSE_FILE} restart frps 2>&1`
  success = $?.success?
  { ok: success, message: success ? "frps restarted (nuclear)" : "restart failed", detail: output.strip }
end

# ---------- POST /evict ----------

server.mount_proc("/evict") do |req, res|
  unless req.request_method == "POST"
    json_response(res, 405, { error: "method not allowed" })
    next
  end

  unless authorized?(req)
    json_response(res, 401, { error: "unauthorized" })
    next
  end

  # Parse optional subdomain from JSON body
  subdomain = nil
  if req.body && !req.body.empty?
    begin
      body = JSON.parse(req.body)
      subdomain = body["subdomain"]
    rescue JSON::ParserError
      # ignore
    end
  end

  if subdomain.nil? || subdomain.empty?
    # No subdomain specified — nuclear fallback
    result = nuclear_restart
    json_response(res, result[:ok] ? 200 : 502, result)
    next
  end

  # Surgical eviction for a specific subdomain
  client_id = find_client_id_for_subdomain(subdomain)
  unless client_id
    json_response(res, 200, { ok: true, message: "subdomain '#{subdomain}' not currently registered — nothing to evict" })
    next
  end

  client_addr = find_client_address(client_id)
  unless client_addr
    $stderr.puts "Could not find client address for #{client_id} in logs — falling back to nuclear restart"
    result = nuclear_restart
    result[:message] = "#{result[:message]} (fallback: could not find client address for subdomain '#{subdomain}')"
    json_response(res, result[:ok] ? 200 : 502, result)
    next
  end

  result = kill_client_connection(client_addr)
  unless result[:ok]
    $stderr.puts "Surgical kill failed for #{client_addr} — falling back to nuclear restart"
    result = nuclear_restart
    result[:message] = "#{result[:message]} (fallback: surgical kill failed)"
  end

  json_response(res, result[:ok] ? 200 : 502, result)
end

# ---------- GET /health ----------

server.mount_proc("/health") do |_req, res|
  json_response(res, 200, { ok: true })
end

trap("INT")  { server.shutdown }
trap("TERM") { server.shutdown }

server.start
