require 'commander'
require 'fastlane/new_action'

HighLine.track_eof = false

module Fastlane
  class CommandsGenerator
    include Commander::Methods

    def self.start
      # since at this point we haven't yet loaded commander
      # however we do want to log verbose information in the PluginManager
      $verbose = true if ARGV.include?("--verbose")

      FastlaneCore::UpdateChecker.start_looking_for_update('fastlane')
      Fastlane.load_actions
      Fastlane.plugin_manager.load_plugins
      # *after* loading the plugins
      Fastlane::PluginUpdateManager.start_looking_for_updates
      self.new.run
    ensure
      FastlaneCore::UpdateChecker.show_update_status('fastlane', Fastlane::VERSION)
      Fastlane::PluginUpdateManager.show_update_status
    end

    # rubocop:disable Metrics/AbcSize
    # rubocop:disable Metrics/MethodLength
    def run
      program :version, Fastlane::VERSION
      program :description, [
        "CLI for 'fastlane' - #{Fastlane::DESCRIPTION}\n",
        "\tRun using `fastlane [platform] [lane_name]`",
        "\tTo pass values to the lanes use `fastlane [platform] [lane_name] key:value key2:value2`"
      ].join("\n")
      program :help, 'Author', 'Felix Krause <fastlane@krausefx.com>'
      program :help, 'Website', 'https://fastlane.tools'
      program :help, 'GitHub', 'https://github.com/fastlane/fastlane'
      program :help_formatter, :compact

      global_option('--verbose') { $verbose = true }

      always_trace!

      command :trigger do |c|
        c.syntax = 'fastlane [lane]'
        c.description = 'Run a sepcific lane. Pass the lane name and optionally the platform first.'
        c.option '--env STRING', String, 'Add environment to use with `dotenv`'

        c.action do |args, options|
          if ensure_fastfile
            Fastlane::CommandLineHandler.handle(args, options)
          end
        end
      end

      command :init do |c|
        c.syntax = 'fastlane init'
        c.description = 'Helps you with your initial fastlane setup'

        if FastlaneCore::Feature.enabled?('FASTLANE_ENABLE_CRASHLYTICS_BETA_INITIALIZATION')
          CrashlyticsBetaCommandLineHandler.apply_options(c)
        end

        c.action do |args, options|
          if args[0] == 'beta' && FastlaneCore::Feature.enabled?('FASTLANE_ENABLE_CRASHLYTICS_BETA_INITIALIZATION')
            beta_info = CrashlyticsBetaCommandLineHandler.info_from_options(options)
            Fastlane::CrashlyticsBeta.new(beta_info, Fastlane::CrashlyticsBetaUi.new).run
          else
            Fastlane::Setup.new.run
          end
        end
      end

      command :new_action do |c|
        c.syntax = 'fastlane new_action'
        c.description = 'Create a new custom action for fastlane.'

        c.option '--name STRING', String, 'Name of your new action'

        c.action do |args, options|
          Fastlane::NewAction.run(new_action_name: options.name)
        end
      end

      command :lanes do |c|
        c.syntax = 'fastlane lanes'
        c.description = 'Lists all available lanes and shows their description'
        c.option "-j", "--json", "Output the lanes in JSON instead of text"

        c.action do |args, options|
          if options.json || ensure_fastfile
            require 'fastlane/lane_list'
            path = Fastlane::FastlaneFolder.fastfile_path

            if options.json
              Fastlane::LaneList.output_json(path)
            else
              Fastlane::LaneList.output(path)
            end
          end
        end
      end

      command :list do |c|
        c.syntax = 'fastlane list'
        c.description = 'Lists all available lanes without description'
        c.action do |args, options|
          if ensure_fastfile
            ff = Fastlane::FastFile.new(Fastlane::FastlaneFolder.fastfile_path)
            UI.message "Available lanes:"
            ff.runner.available_lanes.each do |lane|
              UI.message "- #{lane}"
            end
            UI.important "Execute using `fastlane [lane_name]`"
          end
        end
      end

      command :docs do |c|
        c.syntax = 'fastlane docs'
        c.description = 'Generate a markdown based documentation based on the Fastfile'
        c.option '-f', '--force', 'Overwrite the existing README.md in the ./fastlane folder'

        c.action do |args, options|
          if ensure_fastfile
            ff = Fastlane::FastFile.new(File.join(Fastlane::FastlaneFolder.path || '.', 'Fastfile'))
            UI.message "You don't need to run `fastlane docs` manually any more, this will be done automatically for you."
            Fastlane::DocsGenerator.run(ff)
          end
        end
      end

      command :run do |c|
        c.syntax = 'fastlane run [action] key1:value1 key2:value2'
        c.description = 'Run a fastlane one-off action without a full lane'

        c.action do |args, options|
          require 'fastlane/one_off'
          result = Fastlane::OneOff.execute(args: args)
          UI.success "Result: #{result}" if result
        end
      end

      command :actions do |c|
        c.syntax = 'fastlane actions'
        c.description = 'Lists all available fastlane actions'

        c.option '--platform STRING', String, 'Only show actions available on the given platform'

        c.action do |args, options|
          require 'fastlane/documentation/actions_list'
          Fastlane::ActionsList.run(filter: args.first, platform: options.platform)
        end
      end

      command :action do |c|
        c.syntax = 'fastlane action [tool_name]'
        c.description = 'Shows more information for a specific command'
        c.action do |args, options|
          require 'fastlane/documentation/actions_list'
          Fastlane::ActionsList.run(filter: args.first)
        end
      end

      command :enable_crash_reporting do |c|
        c.syntax = 'fastlane enable_crash_reporting'
        c.description = "Deprecated: fastlane doesn't use a crash reporter any more"
        c.action do |args, options|
          show_crashreporter_note
        end
      end

      command :disable_crash_reporting do |c|
        c.syntax = 'fastlane disable_crash_reporting'
        c.description = "Deprecated: fastlane doesn't use a crash reporter any more"
        c.action do |args, options|
          show_crashreporter_note
        end
      end

      command :enable_auto_complete do |c|
        c.syntax = 'fastlane enable_auto_complete'
        c.description = 'Enable tab auto completion'

        c.action do |args, options|
          require 'fastlane/auto_complete'
          Fastlane::AutoComplete.execute
        end
      end

      #####################################################
      # @!group Plugins
      #####################################################

      command :new_plugin do |c|
        c.syntax = 'fastlane new_plugin [plugin_name]'
        c.description = 'Create a new plugin that can be used with fastlane'

        c.action do |args, options|
          PluginGenerator.new.generate(args.shift)
        end
      end

      command :add_plugin do |c|
        c.syntax = 'fastlane add_plugin [plugin_name]'
        c.description = 'Add a new plugin to your fastlane setup'

        c.action do |args, options|
          args << UI.input("Enter the name of the plugin to install: ") if args.empty?
          args.each do |plugin_name|
            Fastlane.plugin_manager.add_dependency(plugin_name)
          end

          UI.important("Make sure to commit your Gemfile, Gemfile.lock and #{PluginManager::PLUGINFILE_NAME} to version control")
          Fastlane.plugin_manager.install_dependencies!
        end
      end

      command :install_plugins do |c|
        c.syntax = 'fastlane install_plugins'
        c.description = 'Install all plugins for this project'

        c.action do |args, options|
          Fastlane.plugin_manager.install_dependencies!
        end
      end

      command :update_plugins do |c|
        c.syntax = 'fastlane update_plugins'
        c.description = 'Update all plugin dependencies'

        c.action do |args, options|
          Fastlane.plugin_manager.update_dependencies!
        end
      end

      command :search_plugins do |c|
        c.syntax = 'fastlane search_plugins [search_query]'
        c.description = 'Search for plugins, search query is optional'

        c.action do |args, options|
          search_query = args.last
          PluginSearch.print_plugins(search_query: search_query)
        end
      end

      default_command :trigger
      run!
    end

    # Makes sure a Fastfile is available
    # Shows an appropriate message to the user
    # if that's not the case
    # return true if the Fastfile is available
    def ensure_fastfile
      return true if Fastlane::FastlaneFolder.setup?

      create = UI.confirm('Could not find fastlane in current directory. Would you like to set it up?')
      Fastlane::Setup.new.run if create
      return false
    end

    def show_crashreporter_note
      UI.important("fastlane doesn't use a crash reporter any more")
      UI.important("Instead please submit an issue on GitHub: https://github.com/fastlane/fastlane/issues")
      UI.important("This command will be removed in one of the next releases")
    end

    # rubocop:enable Metrics/AbcSize
    # rubocop:enable Metrics/MethodLength
  end
end
