require "digest/md5"
require "docr"
require "docr/utils"
require "log"

module Werk::Jobs
  class Docker < Werk::Config::Job
    @[YAML::Field(key: "image")]
    getter image = "alpine:latest"

    @[YAML::Field(key: "volumes")]
    getter volumes = Array(String).new

    @[YAML::Field(key: "entrypoint")]
    getter entrypoint = ["/bin/sh"]

    @[YAML::Field(key: "network_mode")]
    getter network_mode = "bridge"

    Log = ::Log.for(self)

    def run(session_id : UUID, name : String, context : String) : {Int32, String}
      script = script_file
      Log.debug { "Created temporary script file #{script.path}" }

      buffer_io = IO::Memory.new
      writers = Array(IO).new
      writers << buffer_io
      writers << Werk::Utils::PrefixIO.new(STDOUT, name) unless @silent
      output_io = IO::MultiWriter.new(writers)

      client = Docr::Client.new
      api = Docr::API.new(client)

      begin
        # Checking if the image exists locally
        api.images.inspect(@image)
        Log.debug { "Image #{@image} was found locally" }
      rescue ex
        Log.debug { ex }
        Log.debug { "Fetching image #{@image}" }
        repository, tag = Docr::Utils.parse_repository_tag(@image)
        api.images.create(repository, tag)
      end

      # Create container
      container_name = "#{Digest::MD5.hexdigest(name)}-#{session_id}"
      Log.debug { "Creating container '#{container_name}'" }
      container = api.containers.create(
        container_name,
        Docr::Types::CreateContainerConfig.new(
          image: @image,
          entrypoint: @entrypoint,
          cmd: ["/opt/start.sh"],
          working_dir: "/opt/workspace",
          env: @variables.map { |k, v| "#{k}=#{v}" },
          host_config: Docr::Types::HostConfig.new(
            network_mode: @network_mode,
            binds: [
              "#{script.path}:/opt/start.sh",
              "#{Path[context].expand}:/opt/workspace",
            ].concat(@volumes)
          ),
          labels: {
            "com.stuffo.werk.name"       => name,
            "com.stuffo.werk.session_id" => session_id.to_s,
          }
        )
      )

      begin
        Log.debug { "Starting container '#{container_name}'" }
        api.containers.start(container.id)

        begin
          Log.debug { "Streaming logs for '#{container_name}'" }
          io = api.containers.logs(container.id, follow: true, stdout: true, stderr: true)

          # Reading the logs in the Docker format.
          # More information can be found here: https://docs.docker.com/engine/api/v1.41/#operation/ContainerAttach
          # Look for the "Stream format" section.
          loop do
            # Checking if there's any more incoming data
            has_next = io.peek
            break if has_next.nil? || has_next.empty?

            # Reading the header
            _ = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
            frame_size = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)

            # Read frame and send it to the output IO
            slice = Bytes.new(frame_size)
            total_bytes_read = 0
            retries = 0

            while total_bytes_read < frame_size && retries < 3
              bytes_read = io.read(slice[total_bytes_read, frame_size - total_bytes_read])
              next if bytes_read == 0

              total_bytes_read += bytes_read
              retries += 1 if total_bytes_read
            end

            if total_bytes_read != frame_size
              Log.warn { "Expected to read #{frame_size} bytes but only read #{total_bytes_read}" }
              io.skip(frame_size - total_bytes_read)
            else
              output_io.write(slice)
            end
          end
        rescue ex
          Log.error { ex }
        end

        # Wait for the container execution to end and retrieve the exit code.
        status = api.containers.wait(container.id)
      ensure
        Log.debug { "Removing container '#{container_name}'" }
        api.containers.delete(container.id, force: true)
      end

      return {status.status_code, buffer_io.to_s}
    end
  end
end
