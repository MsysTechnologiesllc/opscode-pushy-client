module Pushy
  class Handler

    attr_reader :received
    attr_accessor :monitor

    def initialize(monitor, client)
      @monitor = monitor
      @client = client
    end

    def on_readable(socket, parts)


      if valid?(parts)
        monitor.checkin!
        parse_json(parts[1].copy_out_string)
      end

    end

    private

    def valid?(parts)
      auth = parts[0].copy_out_string.split(':')[2]
      body = parts[1].copy_out_string

      decrypted_checksum = @client.server_public_key.public_decrypt(Base64.decode64(auth))
      hashed_body = Mixlib::Authentication::Digester.hash_string(body)

      decrypted_checksum == hashed_body
    end

    def parse_json(json)
      body_hash = Yajl::Parser.new.parse(json)

      body_hash.keys.each do |key|
        puts "#{key}: #{body_hash[key]}"
      end
    end

  end
end
