require "colorize"

require "../model/*"
require "../scheduler"

module Werk::Command
  class Plan < Admiral::Command
    define_help description: "List jobs information"

    define_argument target : String,
      description: ""

    define_flag config : String,
      description: "",
      default: Path.new(Dir.current, "werk.yml").to_s,
      short: c

    def run
      config = Werk::Model::Config.load_file(flags.config)

      target = arguments.target || "main"
      plan = Werk::Scheduler.new(config)
        .get_plan(target)

      output = String::Builder.new
      index = 0
      plan.each do |stage|
        output.puts("Stage #{index} (#{stage.size})".colorize(:blue))

        stage.each do |name|
          job = config.jobs[name]

          description = job.description.empty? ? "[No description]" : job.description

          output.puts name.colorize(:yellow)
          output.puts "#{description}"
          output.puts
        end

        index = +1
      end

      puts output.to_s
    end
  end
end
