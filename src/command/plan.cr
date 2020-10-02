require "tallboy"
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

      table = Tallboy.table do
        plan.each_with_index do |stage, index|
          header "Stage #{index}".colorize(:yellow), align: :center
          header do
            cell "Name", align: :center
            cell "Description", align: :center
            cell "Can fail?", align: :center
          end

          stage.each do |name|
            job = config.jobs[name]
            description = job.description.empty? ? "[No description]" : job.description

            row border: :bottom do
              cell name
              cell description
              cell job.can_fail ? "Yes".colorize(:red) : "No".colorize(:green), align: :center
            end
          end
        end
      end

      puts table
    end
  end
end
