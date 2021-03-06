require 'json'
require 'kenji/controller'
require 'kenji/app'
require 'kenji/string_extensions'
require 'rack'

module Kenji
  class Kenji

    attr_reader :env, :root

    # Setting `kenji.status = 203` will affect the status code of the response.
    attr_accessor :status
    # Exceptions will be printed here, and controllers are expected to log to
    # this IO buffer:
    attr_accessor :stderr

    # Methods for rack!

    # Constructor...
    #
    # `env` should be the environment hash provided by Rack.
    #
    # *deprecated* `root` is the root directory (as output by File.expand_path)
    # of the Kenji directory structure. This is deprecated, please use the
    # :directory option below.
    #
    # `options` is an options hash that accepts the following keys:
    #
    #   :auto_cors => true | false
    #
    #     automatically deal with CORS / Access-Control
    #
    #   :directory => String (path)
    #     
    #     this is the preferred way of setting the root directory, when
    #     necessary. you should either set a root directory (which defaults to
    #     the current working directory), or set a root_controller. both are
    #     not necessary, as the directory is only used for auto-discovering
    #     controllers.
    #
    #   :root_controller => Object
    #
    #     when set, Kenji will not attempt to discover controllers based on
    #     convention, but rather will always use this controller. use `pass` to
    #     build a controller hierarchy
    #
    #   :catch_exceptions => true | false
    #
    #     when true, Kenji will catch exceptions, print them in stderr, and and
    #     return a standard 500 error
    #
    #   :stderr => IO
    #
    #     an IO stread, this is where Kenji logging goes by default. defaults
    #     to $stderr
    #
    def initialize(env, *rest)
      raise ArgumentError unless rest.count == 2 || rest.count == 1
      root, options = *rest
      options, root = root, options if root.is_a?(Hash)
      options ||= {}

      @headers = {
        'Content-Type' => 'application/json'
      }
      @status = 200
      @env = env

      # deal with legacy root argument behavior
      options[:directory] = File.expand_path(root) if root
      
      @options = {
        auto_cors: true,
        catch_exceptions: true,
        root_controller: nil,
        directory: File.expand_path(Dir.getwd),
        stderr: $stderr
      }.merge(options)

      @stderr = @options[:stderr]
      @root = @options[:directory] + '/'
    end

    # This method does all the work!
    #
    def call

      auto_cors if @options[:auto_cors]

      catch(:KenjiRespondControlFlowInterrupt) do
        path = @env['PATH_INFO']

        # deal with static files
        static = "#{@root}public#{path}"
        return Rack::File.new("#{@root}public").call(@env) if File.file?(static)


        # new routing code
        method = @env['REQUEST_METHOD'].downcase.to_sym

        segments = path.split('/')
        segments = segments.unshift('') unless segments.first == ''    # ensure existence of leading /'s empty segment

        if @options[:root_controller]
          controller = controller_instance(@options[:root_controller])
          subpath = segments.join('/')
          out = controller.call(method, subpath).to_json
          success = true
        else
          acc = ''; out = '', success = false
          while head = segments.shift
            acc = "#{acc}/#{head}"
            if controller = controller_for(acc)                   # if we have a valid controller 
              subpath = '/'+segments.join('/')
              out = controller.call(method, subpath).to_json
              success = true
              break
            end
          end
        end

        return response_404 unless success

        [@status, @headers, [out]]
      end
    rescue Exception => e
      raise e unless @options[:catch_exceptions]
      @stderr.puts e.inspect                                    # log exceptions
      e.backtrace.each {|b| @stderr.puts "  #{b}" }
      response_500
    end

    # 500 error
    def response_500
      [500, @headers, [{status: 500, message: 'Something went wrong...'}.to_json]]
    end

    # 404 error
    def response_404
      [404, @headers, [{status: 404, message: 'Not found!'}.to_json]]
    end



    # Methods for users!


    # Sets one or multiple headers, as named arametres. eg.
    # 
    #   kenji.header 'Content-Type' => 'hello/world'
    #
    def header(hash={})
      hash.each do |key, value|
        @headers[key] = value
      end
    end

    # Returns the response headers
    #
    def response_headers
      @headers
    end

    # Fetch (and cache) the json input to the request
    # Return a Hash
    #
    def input_as_json
      return @json_input if @json_input
      require 'json'
      raw = @env['rack.input'].read if @env['rack.input']
      begin
        return @json_input = JSON.parse(raw)
      rescue JSON::ParserError
      end if raw
      {} # default return value
    end
    
    # Respond to the request
    #
    def respond(code, message, hash={})
      @status = code
      response = {            # default structure. TODO: figure out if i really want to keep this 
        :status => code,
        :message => message
      }.merge(hash)
      throw(:KenjiRespondControlFlowInterrupt, [@status, @headers, [response.to_json]])
    end



    # Private methods
    private

    # Deals with silly HTTP CORS Access-Control restrictions by automatically
    # allowing all requests.
    #
    def auto_cors
      origin = env['HTTP_ORIGIN']
      header 'Access-Control-Allow-Origin' => origin if origin

      if env['REQUEST_METHOD'] == 'OPTIONS'
        header 'Access-Control-Allow-Methods' => 'OPTIONS, GET, POST, PUT, DELETE'

        if requested_headers = env['HTTP_ACCESS_CONTROL_REQUEST_HEADERS']
          header 'Access-Control-Allow-Headers' => requested_headers
        end
        respond(200, 'CORS is allowed.')
      end
    end

    # Will attempt to fetch the controller, and verify that it is a implements
    # call.
    #
    def controller_for(subpath)
      subpath = '/_' if subpath == '/'
      path = "#{@root}controllers#{subpath}.rb"
      return nil unless File.exists?(path)
      require path
      controller_name = subpath.split('/').last.sub(/^_/, 'Root')
      controller_class = Object.const_get(controller_name.to_s.to_camelcase+'Controller')
      controller_instance(controller_class)
    end

    # Attempts to instantiate the controller class, set up as a Kenji
    # controller.
    #
    def controller_instance(controller_class)
      # ensure protocol compliance
      return unless controller_class.method_defined?(:call) && controller_class.instance_method(:call).arity == 2
      controller = controller_class.new
      controller.kenji = self if controller.respond_to?(:kenji=)
      return controller if controller
      nil # default return value
    end
    
  end
  
end

