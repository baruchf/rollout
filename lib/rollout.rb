require "rollout/version"
require "rollout/legacy"
require "zlib"

class Rollout
  class Feature
    attr_reader :name, :groups, :users, :percentage
    attr_writer :percentage, :groups, :users

    def initialize(name, string = nil)
      @name = name
      if string
        raw_percentage,raw_users,raw_groups = string.split("|")
        @percentage = raw_percentage.to_i
        @users = (raw_users || "").split(",").map(&:to_s)
        @groups = (raw_groups || "").split(",").map(&:to_sym)
      else
        clear
      end
      read_common_settings
      setup_logger
      setup_graylog
    end

    $service_name_str = "users-rollout"
    $common_settings = nil
    $log = nil

    def read_common_settings
      file_name = "#{File.expand_path('')}/../config/common_settings.yml"
      $common_settings = YAML.load(ERB.new(File.read(file_name)).result)[$env]
    end

    def setup_logger
      FileUtils.mkdir("log") unless File.exist?("log")
      settings_logger = $common_settings['logger']
      log_shift = defined?(settings_logger['log_shift']) ? settings_logger['log_shift'] : 1
      log_size  = defined?(settings_logger['log_size']) ? settings_logger['log_size'] : 10240000
      $log = Logger.new("log/#{$env}.log", log_shift, log_size)
      $log.level = Logger.const_get(settings_logger['log_level'].upcase)
    end

    def setup_graylog
      graylog_config = $common_settings['graylog']
      $graylog = GELF::Notifier.new(graylog_config['host'], graylog_config['port'], max_size = 'LAN',
                                    {level: 0, facility: $service_name_str})
    end

    def serialize
      "#{@percentage}|#{@users.join(",")}|#{@groups.join(",")}"
    end

    def add_user(user)
      $graylog.notify!("adding user #{user}")
      @users << user.id.to_s unless @users.include?(user.id.to_s)
    end

    def remove_user(user)
      $graylog.notify!("removing user #{user}")
      @users.delete(user.id.to_s)
    end

    def add_group(group)
      $graylog.notify!("adding group #{group}")
      @groups << group.to_sym unless @groups.include?(group.to_sym)
    end

    def remove_group(group)
      $graylog.notify!("removing group #{group}")
      @groups.delete(group.to_sym)
    end

    def clear
      @groups = []
      @users = []
      @percentage = 0
    end

    def active?(rollout, user)
      if user.nil?
        @percentage == 100
      else
        user_in_percentage?(user) ||
          user_in_active_users?(user) ||
            user_in_active_group?(user, rollout)
      end
    end

    def to_hash
      {:percentage => @percentage,
       :groups     => @groups,
       :users      => @users}
    end

    private
      def user_in_percentage?(user)
        Zlib.crc32(user.id.to_s) % 100 < @percentage
      end

      def user_in_active_users?(user)
        @users.include?(user.id.to_s)
      end

      def user_in_active_group?(user, rollout)
        @groups.any? do |g|
          rollout.active_in_group?(g, user)
        end
      end
  end

  def initialize(storage, opts = {})
    @storage  = storage
    @groups = {:all => lambda { |user| true }}
    @legacy = Legacy.new(opts[:legacy_storage] || @storage) if opts[:migrate]
  end

  def activate(feature)
    $graylog.notify!("activating feature #{feature}")
    with_feature(feature) do |f|
      f.percentage = 100
    end
  end

  def deactivate(feature)
    $graylog.notify!("deactivating feature #{feature}")
    with_feature(feature) do |f|
      f.clear
    end
  end

  def activate_group(feature, group)
    $graylog.notify!("activating group #{group} for feature #{feature}")
    with_feature(feature) do |f|
      f.add_group(group)
    end
  end

  def deactivate_group(feature, group)
    $graylog.notify!("deactivating group #{group} for feature #{feature}")
    with_feature(feature) do |f|
      f.remove_group(group)
    end
  end

  def activate_user(feature, user)
    $graylog.notify!("activating user #{user} for feature #{feature}")
    with_feature(feature) do |f|
      f.add_user(user)
    end
  end

  def deactivate_user(feature, user)
    $graylog.notify!("deactivating user #{user} for feature #{feature}")
    with_feature(feature) do |f|
      f.remove_user(user)
    end
  end

  def define_group(group, &block)
    $graylog.notify!()
    @groups[group.to_sym] = block
  end

  def active?(feature, user = nil)
    feature = get(feature)
    feature.active?(self, user)
  end

  def activate_percentage(feature, percentage)
    $graylog.notify!()
    with_feature(feature) do |f|
      f.percentage = percentage
    end
  end

  def deactivate_percentage(feature)
    $graylog.notify!()
    with_feature(feature) do |f|
      f.percentage = 0
    end
  end

  def active_in_group?(group, user)
    f = @groups[group.to_sym]
    f && f.call(user)
  end

  def get(feature)
    string = @storage.get(key(feature))
    if string || !migrate?
      Feature.new(feature, string)
    else
      $graylog.notify!()
      info = @legacy.info(feature)
      f = Feature.new(feature)
      f.percentage = info[:percentage]
      f.percentage = 100 if info[:global].include? feature
      f.groups = info[:groups].map { |g| g.to_sym }
      f.users = info[:users].map { |u| u.to_s }
      save(f)
      f
    end
  end

  def features
    (@storage.get(features_key) || "").split(",").map(&:to_sym)
  end

  private
    def key(name)
      "feature:#{name}"
    end

    def features_key
      "feature:__features__"
    end

    def with_feature(feature)
      f = get(feature)
      yield(f)
      save(f)
    end

    def save(feature)
      @storage.set(key(feature.name), feature.serialize)
      @storage.set(features_key, (features | [feature.name.to_sym]).join(","))
    end

    def migrate?
      @legacy
    end
end
