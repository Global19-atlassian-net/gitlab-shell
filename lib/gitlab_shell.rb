require 'shellwords'
require 'pathname'

require_relative 'gitlab_net'
require_relative 'gitlab_metrics'

class GitlabShell # rubocop:disable Metrics/ClassLength
  class AccessDeniedError < StandardError; end
  class DisallowedCommandError < StandardError; end
  class InvalidRepositoryPathError < StandardError; end

  GIT_COMMANDS = %w(git-upload-pack git-receive-pack git-upload-archive git-lfs-authenticate).freeze
  GITALY_MIGRATED_COMMANDS = {
    'git-upload-pack' => File.join(ROOT_PATH, 'bin', 'gitaly-upload-pack'),
    'git-upload-archive' => File.join(ROOT_PATH, 'bin', 'gitaly-upload-archive'),
    'git-receive-pack' => File.join(ROOT_PATH, 'bin', 'gitaly-receive-pack')
  }.freeze
  API_COMMANDS = %w(2fa_recovery_codes).freeze
  GL_PROTOCOL = 'ssh'.freeze

  attr_accessor :gl_id, :gl_repository, :repo_name, :command, :git_access, :git_protocol
  attr_reader :repo_path

  def initialize(who)
    who_sym, = GitlabNet.parse_who(who)
    if who_sym == :username
      @who = who
    else
      @gl_id = who
    end
    @config = GitlabConfig.new
  end

  # The origin_cmd variable contains UNTRUSTED input. If the user ran
  # ssh git@gitlab.example.com 'evil command', then origin_cmd contains
  # 'evil command'.
  def exec(origin_cmd)
    unless origin_cmd
      puts "Welcome to GitLab, #{username}!"
      return true
    end

    args = Shellwords.shellwords(origin_cmd)
    args = parse_cmd(args)

    if GIT_COMMANDS.include?(args.first)
      GitlabMetrics.measure('verify-access') { verify_access }
    elsif !defined?(@gl_id)
      # We're processing an API command like 2fa_recovery_codes, but
      # don't have a @gl_id yet, that means we're in the "username"
      # mode and need to materialize it, calling the "user" method
      # will do that and call the /discover method.
      user
    end

    process_cmd(args)

    true
  rescue GitlabNet::ApiUnreachableError
    $stderr.puts "GitLab: Failed to authorize your Git request: internal API unreachable"
    false
  rescue AccessDeniedError => ex
    $logger.warn('Access denied', command: origin_cmd, user: log_username)

    $stderr.puts "GitLab: #{ex.message}"
    false
  rescue DisallowedCommandError
    $logger.warn('Denied disallowed command', command: origin_cmd, user: log_username)

    $stderr.puts "GitLab: Disallowed command"
    false
  rescue InvalidRepositoryPathError
    $stderr.puts "GitLab: Invalid repository path"
    false
  end

  protected

  def parse_cmd(args)
    # Handle Git for Windows 2.14 using "git upload-pack" instead of git-upload-pack
    if args.length == 3 && args.first == 'git'
      @command = "git-#{args[1]}"
      args = [@command, args.last]
    else
      @command = args.first
    end

    @git_access = @command

    return args if API_COMMANDS.include?(@command)

    raise DisallowedCommandError unless GIT_COMMANDS.include?(@command)

    case @command
    when 'git-lfs-authenticate'
      raise DisallowedCommandError unless args.count >= 2
      @repo_name = args[1]
      case args[2]
      when 'download'
        @git_access = 'git-upload-pack'
      when 'upload'
        @git_access = 'git-receive-pack'
      else
        raise DisallowedCommandError
      end
    else
      raise DisallowedCommandError unless args.count == 2
      @repo_name = args.last
    end

    args
  end

  def verify_access
    status = api.check_access(@git_access, nil, @repo_name, @who || @gl_id, '_any', GL_PROTOCOL)

    raise AccessDeniedError, status.message unless status.allowed?

    self.repo_path = status.repository_path
    @gl_repository = status.gl_repository
    @git_protocol = ENV['GIT_PROTOCOL']
    @gitaly = status.gitaly
    @username = status.gl_username
    if defined?(@who)
      @gl_id = status.gl_id
    end
  end

  def process_cmd(args)
    return send("api_#{@command}") if API_COMMANDS.include?(@command)

    if @command == 'git-lfs-authenticate'
      GitlabMetrics.measure('lfs-authenticate') do
        $logger.info('Processing LFS authentication', user: log_username)
        lfs_authenticate
      end
      return
    end

    executable = @command
    args = [repo_path]

    if GITALY_MIGRATED_COMMANDS.key?(executable) && @gitaly
      executable = GITALY_MIGRATED_COMMANDS[executable]

      gitaly_address = @gitaly['address']

      # The entire gitaly_request hash should be built in gitlab-ce and passed
      # on as-is. For now we build a fake one on the spot.
      gitaly_request = {
        'repository' => @gitaly['repository'],
        'gl_repository' => @gl_repository,
        'gl_id' => @gl_id,
        'gl_username' => @username,
        'git_protocol' => @git_protocol
      }

      args = [gitaly_address, JSON.dump(gitaly_request)]
    end

    args_string = [File.basename(executable), *args].join(' ')
    $logger.info('executing git command', command: args_string, user: log_username)
    exec_cmd(executable, *args)
  end

  # This method is not covered by Rspec because it ends the current Ruby process.
  def exec_cmd(*args)
    # If you want to call a command without arguments, use
    # exec_cmd(['my_command', 'my_command']) . Otherwise use
    # exec_cmd('my_command', 'my_argument', ...).
    if args.count == 1 && !args.first.is_a?(Array)
      raise DisallowedCommandError
    end

    env = {
      'HOME' => ENV['HOME'],
      'PATH' => ENV['PATH'],
      'LD_LIBRARY_PATH' => ENV['LD_LIBRARY_PATH'],
      'LANG' => ENV['LANG'],
      'GL_ID' => @gl_id,
      'GL_PROTOCOL' => GL_PROTOCOL,
      'GL_REPOSITORY' => @gl_repository,
      'GL_USERNAME' => @username
    }
    if @gitaly && @gitaly.include?('token')
      env['GITALY_TOKEN'] = @gitaly['token']
    end

    if git_trace_available?
      env.merge!(
        'GIT_TRACE' => @config.git_trace_log_file,
        'GIT_TRACE_PACKET' => @config.git_trace_log_file,
        'GIT_TRACE_PERFORMANCE' => @config.git_trace_log_file
      )
    end

    # We use 'chdir: ROOT_PATH' to let the next executable know where config.yml is.
    Kernel.exec(env, *args, unsetenv_others: true, chdir: ROOT_PATH)
  end

  def api
    GitlabNet.new
  end

  def user
    return @user if defined?(@user)

    begin
      if defined?(@who)
        @user = api.discover(@who)
        @gl_id = "user-#{@user['id']}" if @user && @user.key?('id')
      else
        @user = api.discover(@gl_id)
      end
    rescue GitlabNet::ApiUnreachableError
      @user = nil
    end
  end

  def username_from_discover
    return nil unless user && user['username']

    "@#{user['username']}"
  end

  def username
    @username ||= username_from_discover || 'Anonymous'
  end

  # User identifier to be used in log messages.
  def log_username
    @config.audit_usernames ? username : "user with id #{@gl_id}"
  end

  def lfs_authenticate
    lfs_access = api.lfs_authenticate(@gl_id, @repo_name)

    return unless lfs_access

    puts lfs_access.authentication_payload
  end

  private

  def continue?(question)
    puts "#{question} (yes/no)"
    STDOUT.flush # Make sure the question gets output before we wait for input
    continue = STDIN.gets.chomp
    puts '' # Add a buffer in the output
    continue == 'yes'
  end

  def api_2fa_recovery_codes
    continue = continue?(
      "Are you sure you want to generate new two-factor recovery codes?\n" \
      "Any existing recovery codes you saved will be invalidated."
    )

    unless continue
      puts 'New recovery codes have *not* been generated. Existing codes will remain valid.'
      return
    end

    resp = api.two_factor_recovery_codes(@gl_id)
    if resp['success']
      codes = resp['recovery_codes'].join("\n")
      puts "Your two-factor authentication recovery codes are:\n\n" \
           "#{codes}\n\n" \
           "During sign in, use one of the codes above when prompted for\n" \
           "your two-factor code. Then, visit your Profile Settings and add\n" \
           "a new device so you do not lose access to your account again."
    else
      puts "An error occurred while trying to generate new recovery codes.\n" \
           "#{resp['message']}"
    end
  end

  def git_trace_available?
    return false unless @config.git_trace_log_file

    if Pathname(@config.git_trace_log_file).relative?
      $logger.warn('git trace log path must be absolute, ignoring', git_trace_log_file: @config.git_trace_log_file)
      return false
    end

    begin
      File.open(@config.git_trace_log_file, 'a') { nil }
      return true
    rescue => ex
      $logger.warn('Failed to open git trace log file', git_trace_log_file: @config.git_trace_log_file, error: ex.to_s)
      return false
    end
  end

  def repo_path=(repo_path)
    raise ArgumentError, "Repository path not provided. Please make sure you're using GitLab v8.10 or later." unless repo_path
    raise InvalidRepositoryPathError if File.absolute_path(repo_path) != repo_path

    @repo_path = repo_path
  end
end
